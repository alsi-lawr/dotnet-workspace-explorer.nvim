local root = vim.fn.getcwd()
assert(vim.o.runtimepath:find(root, 1, true) == 1, "checkout is not first on runtimepath")

local public = require("dotnet-workspace-explorer")
local view = require("dotnet-workspace-explorer.view")
local system, spawned = vim.system, 0
vim.system = function(...)
	spawned = spawned + 1
	return system(...)
end

public._register_commands()
for _, command in ipairs({
	"DotnetWorkspaceExplorerOpen",
	"DotnetWorkspaceExplorerClose",
	"DotnetWorkspaceExplorerToggle",
	"DotnetWorkspaceExplorerFocus",
	"DotnetWorkspaceExplorerRefresh",
	"DotnetWorkspaceExplorerActivate",
	"DotnetWorkspaceExplorerExpand",
	"DotnetWorkspaceExplorerCollapse",
	"DotnetWorkspaceExplorerAddFile",
}) do
	assert(vim.fn.exists(":" .. command) == 2, command .. " is missing")
end

assert(not pcall(public.setup, { presentation = { devicons = "yes" } }))
public.setup({ command = root .. "/does-not-exist", mappings = false, position = "left" })
view.open()
view.mappings(public)
assert(vim.api.nvim_win_get_position(view.win)[2] == 0, "left dock was not leftmost")
assert(#vim.api.nvim_buf_get_keymap(view.buf, "n") == 0, "mappings=false installed a mapping")
view.close()

public.setup({
	command = root .. "/does-not-exist",
	position = "right",
	mappings = {
		activate = false,
		collapse = false,
		expand = "L",
		add_file = false,
		refresh = false,
		close = false,
	},
})
view.open()
view.mappings(public)
local mappings = vim.api.nvim_buf_get_keymap(view.buf, "n")
assert(vim.api.nvim_win_get_position(view.win)[2] > 0, "right dock was not rightmost")
assert(#mappings == 1 and mappings[1].lhs == "L", "replacement mapping policy failed")
assert(spawned == 0, "setup or no-server view spawned a process")
view.close()
vim.system = system
print("DWE-008 no-server smoke passed")
