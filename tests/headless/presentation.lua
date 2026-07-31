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
}
local by_id = {}
for _, node in pairs(nodes) do
	by_id[node.id] = node
end

local tree = setmetatable({
	nodes = by_id,
	children = {
		workspace = { "solution-folder" },
		["solution-folder"] = { "solution-item", "project" },
		project = { "project-folder", "dependencies" },
		["project-folder"] = { "project-file" },
		dependencies = { "dependency" },
	},
	roots = { "workspace" },
	expanded = {
		workspace = true,
		["solution-folder"] = true,
		project = true,
		["project-folder"] = true,
		dependencies = true,
	},
	selected_id = "project-file",
	phase = "ready",
}, { __index = Workspace })

for _, node in pairs(nodes) do
	local container = node.kind == "workspace"
		or node.kind == "solutionFolder"
		or node.kind == "project"
		or node.kind == "projectFolder"
		or node.kind == "dependencyContainer"
	assert_equal(container, tree:is_expandable(node.id) == true, node.kind .. " expandability")
end

assert(not pcall(config.setup, { presentation = { devicons = "yes" } }))
assert(not pcall(config.setup, { presentation = { colour = true } }))
config.setup()
assert_equal(false, config.get().presentation.devicons, "Devicons default")

local loads, lookups, notifications = 0, {}, 0
package.loaded["nvim-web-devicons"] = nil
package.preload["nvim-web-devicons"] = function()
	loads = loads + 1
	return {
		get_icon = function(name, extension, options)
			lookups[#lookups + 1] = { name, extension, options }
			local icons = {
				["workspace.slnx"] = { "", "DevIconSlnx" },
				["project.csproj"] = { "󰪮", "DevIconCSharpProject" },
				["README.md"] = { "", "DevIconMd" },
				["Multi\r\n\tName.fs"] = { "", "DevIconFsharp" },
				["dependency.dll"] = { "", "DevIconDll" },
			}
			return unpack(icons[name] or {})
		end,
	}
end
local original_notify = vim.notify
vim.notify = function()
	notifications = notifications + 1
end

vim.api.nvim_set_hl(0, "DotnetWorkspaceExplorerFile", { link = "Error" })
view.open()
assert_equal(false, vim.wo[view.win].wrap, "explorer rows do not wrap")
assert_equal(
	"Error",
	vim.api.nvim_get_hl(0, {
		name = "DotnetWorkspaceExplorerFile",
		link = true,
	}).link,
	"default highlight preserves user override"
)
assert_equal(
	"Directory",
	vim.api.nvim_get_hl(0, {
		name = "DotnetWorkspaceExplorerFolder",
		link = true,
	}).link,
	"folder highlight link"
)

view.render(tree)
assert_equal(0, loads, "disabled Devicons stays unloaded")
local lines = vim.api.nvim_buf_get_lines(view.buf, 0, -1, false)
assert_equal(8, #lines, "one row per semantic node")
assert(lines[6]:find("Multi\tName.fs", 1, true), "multiline name collapses to one tab")
assert_equal(
	"Multi\r\n\tName.fs",
	tree:get_node("project-file").name,
	"stored name remains authoritative"
)
assert_equal("project-file", view.selected(tree), "stable row selection")

config.setup({ presentation = { devicons = true } })
local highlights, add_highlight = {}, vim.api.nvim_buf_add_highlight
vim.api.nvim_buf_add_highlight = function(buffer, namespace, group, line, start, finish)
	highlights[#highlights + 1] = { group, line, start, finish }
	return add_highlight(buffer, namespace, group, line, start, finish)
end
view.render(tree)
lines = vim.api.nvim_buf_get_lines(view.buf, 0, -1, false)
assert_equal(1, loads, "enabled Devicons loads lazily")
assert_equal({ "workspace.slnx", nil, { default = false } }, lookups[1], "solution lookup")
assert_equal({ "README.md", nil, { default = false } }, lookups[2], "solution item lookup")
assert_equal({ "project.csproj", nil, { default = false } }, lookups[3], "project lookup")
assert_equal({ "Multi\r\n\tName.fs", nil, { default = false } }, lookups[4], "project file lookup")
assert(lines[1]:find(" Example.slnx", 1, true), "solution Devicon")
assert(lines[2]:find(" Source", 1, true), "open directory icon")
assert(lines[3]:find(" README.md", 1, true), "solution item Devicon")
assert(lines[4]:find("󰪮 Example.fsproj", 1, true), "project Devicon")
assert(lines[5]:find(" Features", 1, true), "open project directory icon")
assert(lines[7]:find(" Dependencies", 1, true), "dependency container icon")
assert(lines[8]:find(" FSharp.Core (10.0.0)", 1, true), "NuGet Devicon")
assert(not lines[6]:find("- ", 1, true), "file row omits the leaf prefix")

local icon_range
for _, item in ipairs(highlights) do
	if item[1] == "DevIconFsharp" and item[2] == 5 then
		icon_range = item
	end
end
assert(icon_range, "project file Devicon highlight")
assert_equal(#"", icon_range[4] - icon_range[3], "Devicon byte range length")
assert_equal("", lines[6]:sub(icon_range[3] + 1, icon_range[4]), "Devicon byte range contents")

for _, fallback in ipairs({
	function()
		error("lookup failed")
	end,
	function()
		return nil, nil
	end,
}) do
	package.loaded["nvim-web-devicons"] = { get_icon = fallback }
	view.render(tree)
	lines = vim.api.nvim_buf_get_lines(view.buf, 0, -1, false)
	assert(lines[6]:find(" F Multi\tName.fs", 1, true), "lookup failure uses file glyph")
end

package.loaded["nvim-web-devicons"] = nil
package.preload["nvim-web-devicons"] = function()
	error("module missing")
end
view.render(tree)
lines = vim.api.nvim_buf_get_lines(view.buf, 0, -1, false)
assert(lines[6]:find(" F Multi\tName.fs", 1, true), "missing module uses file glyph")
assert(lines[1]:find(" S Example.slnx", 1, true), "missing module uses solution glyph")
assert(lines[2]:find(" D Source", 1, true), "missing module uses folder glyph")
assert(lines[4]:find(" P Example.fsproj", 1, true), "missing module uses project glyph")
assert(lines[8]:find(" F FSharp.Core (10.0.0)", 1, true), "missing module uses dependency glyph")
assert_equal(0, notifications, "fallbacks stay silent")

vim.api.nvim_buf_add_highlight = add_highlight
vim.notify = original_notify

view.close()
for id, parent in pairs({
	["solution-folder"] = "workspace",
	["solution-item"] = "solution-folder",
	project = "solution-folder",
	["project-folder"] = "project",
	["project-file"] = "project-folder",
	dependencies = "project",
	dependency = "dependencies",
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
explorer.setup({ presentation = { devicons = false } })
local original_window = vim.api.nvim_get_current_win()
explorer.open("Example.slnx")

local function row_for(id)
	for index, row in ipairs(view.rows) do
		if row.id == id then
			return index
		end
	end
	error("missing row " .. id)
end

local function select(id)
	vim.api.nvim_win_set_cursor(view.win, { row_for(id), 0 })
	tree:select(id)
end

select("project-file-20")
vim.api.nvim_win_set_width(view.win, 41)
vim.api.nvim_win_call(view.win, function()
	vim.cmd("normal! zt")
end)
local saved_view = vim.api.nvim_win_call(view.win, vim.fn.winsaveview)
assert(saved_view.topline > 1, "semantic-depth probe must exercise a scrolled viewport")
explorer.focus()
assert_equal(view.win, vim.api.nvim_get_current_win(), "public focus reaches explorer")
vim.api.nvim_set_current_win(original_window)
explorer.refresh()
assert_equal("project-file-20", tree.selected_id, "Refresh preserves deep selection")
assert_equal(41, vim.api.nvim_win_get_width(view.win), "Refresh preserves explorer width")
assert_equal(
	saved_view.topline,
	vim.api.nvim_win_call(view.win, vim.fn.winsaveview).topline,
	"Refresh preserves viewport anchor"
)
assert_equal(original_window, vim.api.nvim_get_current_win(), "Refresh preserves external focus")

select("project-file")
tree.on_refresh = function(self)
	self.children["project-folder"] = {}
	factory_options.on_change(self)
end
explorer.refresh()
assert_equal("project-folder", tree.selected_id, "missing descendant selects nearest ancestor")

tree.on_refresh = nil
tree.children["project-folder"] = project_files
factory_options.on_change(tree)

print("DWE presentation probe passed")
