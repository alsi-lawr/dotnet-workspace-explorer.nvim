vim.opt.runtimepath:prepend(vim.fn.getcwd())

local function assert_equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(
			("%s\nexpected: %s\nactual: %s"):format(message, vim.inspect(expected), vim.inspect(actual))
		)
	end
end

local config = require("dotnet-workspace-explorer.config")
local Workspace = require("dotnet-workspace-explorer.workspace").Workspace
local view = require("dotnet-workspace-explorer.view")

local nodes = {
	workspace = { id = "workspace", kind = "workspace", name = "Example.slnx" },
	solution_folder = { id = "solution-folder", kind = "solutionFolder", name = "Source" },
	solution_item = { id = "solution-item", kind = "solutionItem", name = "README.md" },
	project = { id = "project", kind = "project", name = "Example.fsproj" },
	project_folder = { id = "project-folder", kind = "projectFolder", name = "Features" },
	project_file = {
		id = "project-file",
		kind = "projectFile",
		name = "Multi\r\n\tName.fs",
	},
	dependencies = {
		id = "dependencies",
		kind = "dependencyContainer",
		name = "Dependencies",
	},
	dependency = { id = "dependency", kind = "dependency", name = "FSharp.Core (10.0.0)" },
	dependency_property = {
		id = "dependency-property",
		kind = "dependencyProperty",
		name = "Version: 10.0.0",
	},
}
local by_id = {}
for _, value in pairs(nodes) do
	by_id[value.id] = value
end

local tree = setmetatable({
	nodes = by_id,
	children = {
		workspace = { "solution-folder" },
		["solution-folder"] = { "solution-item", "project" },
		project = { "project-folder", "dependencies" },
		["project-folder"] = { "project-file" },
		dependencies = { "dependency" },
		dependency = { "dependency-property" },
	},
	roots = { "workspace" },
	expanded = {
		workspace = true,
		["solution-folder"] = true,
		project = true,
		["project-folder"] = true,
		dependencies = true,
		dependency = true,
	},
	selected_id = "project-file",
	phase = "ready",
	git_enabled = false,
}, { __index = Workspace })

assert(tree:is_expandable("workspace"), "workspace should be expandable")
assert(not tree:is_expandable("project-file"), "project file should be a leaf")

assert(not pcall(config.setup, { presentation = { devicons = "yes" } }))
assert(not pcall(config.setup, { presentation = { colour = true } }))
config.setup()
assert_equal(false, config.get().presentation.devicons, "Devicons default")

local devicons_loaded, devicon_names = false, {}
package.loaded["nvim-web-devicons"] = nil
package.preload["nvim-web-devicons"] = function()
	devicons_loaded = true
	return {
		get_icon = function(name)
			devicon_names[name] = true
			return "I", "DevIconTest"
		end,
	}
end

local function buffer_lines()
	return vim.api.nvim_buf_get_lines(view.buf, 0, -1, false)
end

local function line_containing(lines, text)
	for _, line in ipairs(lines) do
		if line:find(text, 1, true) then
			return line
		end
	end
end

view.open()
view.render(tree)
local lines = buffer_lines()
for _, name in ipairs({
	"Example.slnx",
	"Source",
	"README.md",
	"Example.fsproj",
	"Features",
	"Multi\tName.fs",
	"Dependencies",
	"FSharp.Core (10.0.0)",
	"Version: 10.0.0",
}) do
	assert(line_containing(lines, name), "semantic node was not rendered: " .. name)
end
assert_equal(
	"Multi\r\n\tName.fs",
	tree:get_node("project-file").name,
	"rendering changed the authoritative node name"
)
assert_equal("project-file", view.selected(tree), "stable row selection")
assert(not devicons_loaded, "disabled Devicons should stay unloaded")

config.setup({ presentation = { devicons = true } })
view.render(tree)
assert(devicons_loaded, "enabled Devicons should load on render")
assert(devicon_names["Multi\r\n\tName.fs"], "project file was not offered to Devicons")

package.loaded["nvim-web-devicons"] = {
	get_icon = function()
		error("lookup failed")
	end,
}
view.render(tree)
lines = buffer_lines()
assert(line_containing(lines, "Multi\tName.fs"), "failed Devicon lookup hid the project file")

package.loaded["nvim-web-devicons"] = nil
package.preload["nvim-web-devicons"] = function()
	error("module missing")
end
view.render(tree)
lines = buffer_lines()
assert(line_containing(lines, "Multi\tName.fs"), "missing Devicons module hid the project file")

view.close()
for id, parent in pairs({
	["solution-folder"] = "workspace",
	["solution-item"] = "solution-folder",
	project = "solution-folder",
	["project-folder"] = "project",
	["project-file"] = "project-folder",
	dependencies = "project",
	dependency = "dependencies",
	["dependency-property"] = "dependency",
}) do
	tree.nodes[id].parent_id = parent
end
local project_files = { "project-file" }
for index = 1, 30 do
	local id = "project-file-" .. index
	tree.nodes[id] = {
		id = id,
		parent_id = "project-folder",
		kind = "projectFile",
		name = ("Feature%02d.fs"):format(index),
	}
	project_files[#project_files + 1] = id
end

local factory_options
local opened_path = vim.fn.tempname() .. ".fs"
vim.fn.writefile({ "module OpenedFromExplorer" }, opened_path)
local resolved_id
tree.children["project-folder"] = project_files
tree.selected_id, tree.revision = "project-file-20", 7
function tree:start(callback)
	factory_options.on_change(self)
	callback(nil, self)
end
function tree.stop() end
function tree.is_terminal()
	return false
end
function tree.has_capability()
	return true
end
function tree.resolve_file(_, id, callback)
	resolved_id = id
	callback(nil, opened_path)
end
function tree:refresh(callback)
	if self.on_refresh then
		self:on_refresh()
	else
		factory_options.on_change(self)
	end
	callback()
end
package.loaded["dotnet-workspace-explorer"] = nil
package.loaded["dotnet-workspace-explorer.workspace"] = {
	Workspace = {
		new = function(options)
			factory_options = options
			return tree
		end,
	},
}
local explorer = require("dotnet-workspace-explorer")
explorer.setup({ presentation = { devicons = false }, git = { enable = false } })
local original_window = vim.api.nvim_get_current_win()
explorer.open("Example.slnx")

local function select(id)
	local name = tree:get_node(id).name:gsub("[\r\n]+", "")
	local row
	for index, line in ipairs(buffer_lines()) do
		if line:find(name, 1, true) then
			row = index
			break
		end
	end
	assert(row, "missing rendered node " .. id)
	vim.api.nvim_win_set_cursor(view.win, { row, 0 })
	tree:select(id)
end

select("project-file-20")
vim.api.nvim_win_set_width(view.win, 41)
vim.api.nvim_win_call(view.win, function()
	vim.cmd("normal! zt")
end)
explorer.focus()
explorer.activate()
assert_equal("project-file-20", resolved_id, "file activation delegates path resolution")
assert_equal(original_window, vim.api.nvim_get_current_win(), "file opens in the editor window")
assert_equal(
	vim.fs.normalize(opened_path),
	vim.fs.normalize(vim.api.nvim_buf_get_name(0)),
	"file activation opens the resolved path"
)
assert(view.is_open(), "file activation keeps the explorer open")

select("project-file-20")
vim.api.nvim_win_call(view.win, function()
	vim.cmd("normal! zt")
end)
local saved_view = vim.api.nvim_win_call(view.win, vim.fn.winsaveview)
local saved_anchor = buffer_lines()[saved_view.topline]
explorer.refresh()
assert_equal("project-file-20", tree.selected_id, "Refresh preserves deep selection")
local refreshed_view = vim.api.nvim_win_call(view.win, vim.fn.winsaveview)
assert_equal(
	saved_anchor,
	buffer_lines()[refreshed_view.topline],
	"Refresh preserves viewport anchor"
)
assert_equal(original_window, vim.api.nvim_get_current_win(), "Refresh preserves editor focus")

select("project-file")
tree.on_refresh = function(self)
	self.children["project-folder"] = {}
	factory_options.on_change(self)
end
explorer.refresh()
assert_equal("project-folder", tree.selected_id, "missing descendant selects nearest ancestor")

explorer.close()
vim.fn.delete(opened_path)
print("DWE presentation probe passed")
