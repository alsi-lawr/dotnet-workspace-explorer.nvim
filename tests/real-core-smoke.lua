local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local core = assert(vim.env.DWE_CORE, "DWE_CORE is required")
local fixture = assert(vim.env.DWE_FIXTURE, "DWE_FIXTURE is required")
local fixture_root = vim.fs.dirname(fixture)
local explorer = require("dotnet-workspace-explorer")
local view = require("dotnet-workspace-explorer.view")
local notification

local function wait_for(predicate, message)
	assert(
		vim.wait(30000, predicate, 20),
		message
			.. "\n"
			.. vim.inspect(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false))
			.. "\n"
			.. tostring(notification)
	)
end

local function lines()
	return vim.api.nvim_buf_get_lines(view.buf, 0, -1, false)
end

local function select_matching(text)
	for index, line in ipairs(lines()) do
		if line:find(text, 1, true) then
			vim.api.nvim_win_set_cursor(view.win, { index, 0 })
			return
		end
	end
	error("missing explorer row: " .. text .. "\n" .. vim.inspect(lines()))
end

vim.notify = function(message, level)
	if level == vim.log.levels.ERROR then
		notification = message
	end
end
vim.ui.select = function(items, _, callback)
	callback(items[1])
end

explorer.setup({
	command = core,
	target = function()
		return fixture
	end,
	git = { enable = true },
	presentation = { devicons = false },
	width = 37,
})
explorer._register_commands()
explorer.open()
wait_for(function()
	return view.good == true
end, "real core did not open")

explorer.expand_all()
wait_for(function()
	for _, line in ipairs(lines()) do
		if line:find("Version:", 1, true) then
			return true
		end
	end
	return false
end, "ExpandAll did not hydrate dependency properties")

select_matching("P Studio.CSharp")
explorer.edit()
wait_for(function()
	return vim.api.nvim_buf_get_name(0) ~= "" or notification ~= nil
end, "Edit did not complete")
assert(
	vim.fs.normalize(vim.api.nvim_buf_get_name(0))
		== vim.fs.normalize(fixture_root .. "/src/Studio.CSharp/Studio.CSharp.csproj"),
	"Edit did not open the C# project in the previous editor: "
		.. vim.api.nvim_buf_get_name(0)
		.. " / "
		.. tostring(notification)
)
assert(view.is_open(), "Edit closed the explorer")

vim.ui.input = function(_, callback)
	callback("BootstrapRenamed.cs")
end
select_matching("Bootstrap.cs")
explorer.rename()
wait_for(function()
	return vim.fn.filereadable(fixture_root .. "/src/Studio.CSharp/BootstrapRenamed.cs") == 1
end, "Rename did not complete")
wait_for(function()
	for _, line in ipairs(lines()) do
		if line:find("BootstrapRenamed.cs", 1, true) then
			return true
		end
	end
	return false
end, "renamed node did not reconcile")

select_matching("BootstrapRenamed.cs")
explorer.mark_copy()
select_matching("Actions")
explorer.place()
wait_for(function()
	return vim.fn.filereadable(fixture_root .. "/src/Studio.CSharp/Actions/BootstrapRenamed.cs") == 1
end, "Copy Place did not complete")

wait_for(function()
	local copies = 0
	for _, line in ipairs(lines()) do
		if line:find("BootstrapRenamed.cs", 1, true) then
			copies = copies + 1
		end
	end
	return copies == 2
end, "copied node did not reconcile")
select_matching("ProjectNode.cs")
explorer.mark_move()
select_matching("Actions")
explorer.place()
wait_for(function()
	return vim.fn.filereadable(fixture_root .. "/src/Studio.CSharp/Actions/ProjectNode.cs") == 1
		and vim.fn.filereadable(fixture_root .. "/src/Studio.CSharp/Models/ProjectNode.cs") == 0
end, "Move Place did not complete")

explorer.collapse_all()
assert(#lines() == 1, "CollapseAll did not show one collapsed tree")
explorer.git_refresh()
wait_for(function()
	return lines()[1]:match("[+~]$") ~= nil
end, "opt-in Git status did not decorate the solution")

assert(notification == nil, notification or "unexpected explorer error")
explorer.close()
print("DWE bounded real-core smoke passed")
