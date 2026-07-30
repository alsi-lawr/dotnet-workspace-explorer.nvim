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
			return "", "DevIconFsharp"
		end,
	}
end
local original_notify = vim.notify
vim.notify = function()
	notifications = notifications + 1
end

vim.api.nvim_set_hl(0, "DotnetWorkspaceExplorerFile", { link = "Error" })
view.open()
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
assert_equal({ "README.md", nil, { default = false } }, lookups[1], "solution item lookup")
assert_equal({ "Multi\r\n\tName.fs", nil, { default = false } }, lookups[2], "project file lookup")

local icon_range
for _, item in ipairs(highlights) do
	if item[1] == "DevIconFsharp" and item[2] == 5 then
		icon_range = item
	end
end
assert(icon_range, "project file Devicon highlight")
assert_equal(#"", icon_range[4] - icon_range[3], "Devicon byte range length")
assert_equal("", lines[6]:sub(icon_range[3] + 1, icon_range[4]), "Devicon byte range contents")

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
assert_equal(0, notifications, "fallbacks stay silent")

vim.api.nvim_buf_add_highlight = add_highlight
vim.notify = original_notify
print("DWE-007 presentation probe passed")
