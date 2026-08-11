local root = vim.fn.getcwd()

local public = require("dotnet-workspace-explorer")
local config = require("dotnet-workspace-explorer.config")
local rpc = require("dotnet-workspace-explorer.rpc")
local view = require("dotnet-workspace-explorer.ui.view")
assert(config.get().command == "dotnet-we", "installed core command default changed")
assert(config.get().package_command == "dotnet-pe", "Package Explorer command default changed")
assert(config.get().mappings.new == "a", "New mapping default changed")
assert(config.get().mappings.place == "p", "Place mapping default changed")
assert(config.get().mappings.packages == "P", "Package Explorer mapping default changed")
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
	"DotnetWorkspaceExplorerNew",
	"DotnetWorkspaceExplorerDelete",
	"DotnetWorkspaceExplorerEdit",
	"DotnetWorkspaceExplorerRename",
	"DotnetWorkspaceExplorerMarkMove",
	"DotnetWorkspaceExplorerMarkCopy",
	"DotnetWorkspaceExplorerPlace",
	"DotnetWorkspaceExplorerClearMarks",
	"DotnetWorkspaceExplorerExpandAll",
	"DotnetWorkspaceExplorerCollapseAll",
	"DotnetWorkspaceExplorerGitRefresh",
	"DotnetWorkspaceExplorerPackages",
	"DotnetWorkspaceExplorerPackagesKill",
}) do
	assert(vim.fn.exists(":" .. command) == 2, command .. " is missing")
end
for action, command in pairs({
	edit = "DotnetWorkspaceExplorerEdit",
	rename = "DotnetWorkspaceExplorerRename",
	mark_move = "DotnetWorkspaceExplorerMarkMove",
	mark_copy = "DotnetWorkspaceExplorerMarkCopy",
	place = "DotnetWorkspaceExplorerPlace",
	clear_marks = "DotnetWorkspaceExplorerClearMarks",
	expand_all = "DotnetWorkspaceExplorerExpandAll",
	collapse_all = "DotnetWorkspaceExplorerCollapseAll",
	git_refresh = "DotnetWorkspaceExplorerGitRefresh",
}) do
	local original, invoked = public[action], false
	public[action] = function()
		invoked = true
	end
	vim.cmd(command)
	assert(invoked, command .. " does not invoke public." .. action)
	public[action] = original
end

local command_target
local original_packages = public.packages
public.packages = function(target)
	command_target = target
end
local exact_target = "/tmp/package target;$(not-a-shell).fsproj"
vim.cmd({ cmd = "DotnetWorkspaceExplorerPackages", args = { exact_target } })
assert(command_target == exact_target, "Packages command changed its required target")
command_target = nil
assert(not pcall(vim.cmd, "DotnetWorkspaceExplorerPackages"))
assert(command_target == nil, "Packages command supplied a target fallback")
public.packages = original_packages

local kill_invoked = false
local original_packages_kill = public.packages_kill
public.packages_kill = function()
	kill_invoked = true
end
vim.cmd("DotnetWorkspaceExplorerPackagesKill")
assert(kill_invoked, "PackagesKill command did not invoke the public kill action")
kill_invoked = false
assert(not pcall(vim.cmd, "DotnetWorkspaceExplorerPackagesKill unexpected"))
assert(not kill_invoked, "PackagesKill command accepted an argument")
public.packages_kill = original_packages_kill

local process_options, process_exit, exit_problem
local client = rpc.Client.new({
	command = "fake-workspace-explorer",
	target = root,
	spawn = function(_, options, on_exit)
		process_options, process_exit = options, on_exit
		return {
			write = function() end,
			kill = function() end,
		}
	end,
	on_error = function(problem)
		exit_problem = problem
	end,
})
client:start(function() end)
process_options.stderr(nil, "  exact startup failure\n")
process_exit({ code = 64, signal = 0 })
assert(
	vim.wait(1000, function()
		return exit_problem ~= nil
	end),
	"unexpected process exit was not reported"
)
assert(exit_problem.message == "exact startup failure", "process stderr was not surfaced")

assert(not pcall(public.setup, { presentation = { devicons = "yes" } }))
assert(not pcall(public.setup, { git = { enable = "yes" } }))
assert(not pcall(public.setup, { git = { poll = true } }))
assert(not pcall(public.setup, { actions = {} }))
assert(not pcall(public.setup, { package_command = "" }))
assert(not pcall(public.setup, { package_command = false }))
local unique, duplicate_error = pcall(public.setup, { mappings = { packages = "a" } })
assert(not unique, "duplicate merged mappings were accepted")
assert(
	tostring(duplicate_error):find("mappings.packages", 1, true)
		and tostring(duplicate_error):find("mappings.new", 1, true),
	"duplicate mapping error did not identify both actions"
)
public.setup({ package_command = "custom-dotnet-pe", mappings = { packages = false, new = false } })
assert(config.get().package_command == "custom-dotnet-pe", "package command override was lost")
assert(config.get().mappings.packages == false, "disabled Packages mapping was rejected")
assert(config.get().mappings.new == false, "multiple disabled mappings collided")

public.setup({ command = root .. "/does-not-exist" })
assert(config.get().git.enable == true, "Git does not default to enabled")
view.open()
view.mappings(public)
local user_delete_invoked = false
local user_delete = function()
	user_delete_invoked = true
end
vim.keymap.set("n", "d", user_delete, { buffer = view.buf })
public.setup({ command = root .. "/does-not-exist" })
view.mappings(public)
vim.api.nvim_win_call(view.win, function()
	vim.cmd("normal d")
end)
assert(user_delete_invoked, "re-setup replaced a user-local map")
vim.keymap.del("n", "d", { buffer = view.buf })

local packages_invoked = false
original_packages = public.packages
public.packages = function()
	packages_invoked = true
end
public.setup({ command = root .. "/does-not-exist" })
view.mappings(public)
vim.api.nvim_win_call(view.win, function()
	vim.cmd("normal P")
end)
assert(packages_invoked, "default P mapping does not invoke Packages")

local user_packages_invoked = false
vim.keymap.set("n", "P", function()
	user_packages_invoked = true
end, { buffer = view.buf })
packages_invoked = false
public.setup({ command = root .. "/does-not-exist" })
view.mappings(public)
vim.api.nvim_win_call(view.win, function()
	vim.cmd("normal P")
end)
assert(user_packages_invoked, "re-setup replaced a user-local P map")
assert(not packages_invoked, "user-local P map also invoked Packages")
vim.keymap.del("n", "P", { buffer = view.buf })
public.packages = original_packages

local expanded = false
public.expand = function()
	expanded = true
end
public.setup({ command = root .. "/does-not-exist", mappings = { expand = "L" } })
view.mappings(public)
vim.api.nvim_win_call(view.win, function()
	vim.cmd("normal L")
end)
assert(expanded, "replacement mapping does not invoke its public action")

public.setup({ command = root .. "/does-not-exist", mappings = false })
view.mappings(public)
expanded = false
vim.api.nvim_win_call(view.win, function()
	vim.cmd("normal L")
end)
assert(not expanded, "mappings=false left a plugin mapping active")
assert(spawned == 0, "setup or no-server view spawned a process")
view.close()
vim.system = system
print("DWE-008 no-server smoke passed")
