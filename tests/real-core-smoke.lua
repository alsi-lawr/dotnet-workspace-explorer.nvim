local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local core = assert(vim.env.DWE_CORE, "DWE_CORE is required")
local fixture = assert(vim.env.DWE_FIXTURE, "DWE_FIXTURE is required")
local fixture_root = vim.fs.dirname(fixture)
local explorer = require("dotnet-workspace-explorer")
local context = require("dotnet-workspace-explorer.controller.context")
local view = require("dotnet-workspace-explorer.ui.view")
local notification, desired_create_kind, desired_display_name, desired_name, confirmation_result

local function assert_equal(expected, actual, message)
	assert(vim.deep_equal(expected, actual), message)
end

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

local function expand_all_complete()
	if not context.tree or context.tree.expansion_owner then
		return false
	end
	for _, row in ipairs(view.rows) do
		if row.loading or row.provisional or row.actionable == false then
			return false
		end
	end
	return true
end

local function file_contents(path)
	return table.concat(vim.fn.readfile(path), "\n")
end

local function semantic_root(line)
	return line and line:match("^S ") and line:find("SemanticStudio", 1, true)
end

local function matches(line, text)
	local semantic_kind, semantic_name = text:match("^([SPDF]) (.+)$")
	return line:find(text, 1, true)
		or (
			semantic_name
			and line:match("^%s*" .. semantic_kind .. " ")
			and line:find(semantic_name, 1, true)
		)
end

local function nested_under(parent, child)
	local current = lines()
	local parent_index, parent_indent
	for index, line in ipairs(current) do
		if matches(line, parent) then
			parent_index = index
			parent_indent = #(line:match("^%s*") or "")
			break
		end
	end
	if not parent_index then
		return false
	end
	for index = parent_index + 1, #current do
		local line = current[index]
		local indent = #(line:match("^%s*") or "")
		if indent <= parent_indent then
			return false
		end
		if matches(line, child) then
			return true
		end
	end
	return false
end

local function select_matching(text)
	for index, line in ipairs(lines()) do
		if matches(line, text) then
			vim.api.nvim_win_set_cursor(view.win, { index, 0 })
			return index
		end
	end
	error("missing explorer row: " .. text .. "\n" .. vim.inspect(lines()))
end

local function local_mapping(lhs)
	local raw = vim.keycode(lhs)
	for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(view.buf, "n")) do
		if mapping.lhsraw == raw then
			return {
				callback = mapping.callback,
				rhs = mapping.rhs,
				noremap = mapping.noremap,
				nowait = mapping.nowait,
				silent = mapping.silent,
				expr = mapping.expr,
				desc = mapping.desc,
			}
		end
	end
	return false
end

local function new_kind(kind, name, display_name)
	desired_create_kind, desired_name, desired_display_name = kind, name, display_name
	explorer.new()
end

local function move_logical(source, destination, description)
	local before = file_contents(fixture)
	notification = nil
	select_matching(source)
	explorer.mark_move()
	select_matching(destination)
	explorer.place()
	wait_for(function()
		return notification ~= nil or file_contents(fixture) ~= before
	end, description .. " did not execute")
	vim.wait(250, function()
		return notification ~= nil
	end, 10)
	assert_equal(nil, notification, description .. " reported an error")
	explorer.expand_all()
	wait_for(function()
		return nested_under(destination, source) and expand_all_complete()
	end, description .. " did not reconcile beneath its destination")
end

vim.notify = function(message, level)
	if level == vim.log.levels.ERROR then
		notification = message
	end
end
vim.ui.select = function(items, options, callback)
	if options.kind == "workspace-create-option" then
		for _, item in ipairs(items) do
			if item.kind == desired_create_kind then
				if desired_display_name then
					assert_equal(
						desired_display_name,
						item.displayName,
						"New picker did not preserve the core option name"
					)
				end
				desired_create_kind = nil
				desired_display_name = nil
				return callback(item)
			end
		end
		return error("missing New kind: " .. tostring(desired_create_kind))
	end
	callback(items[1])
end
vim.ui.input = function(options, callback)
	if options.kind == "confirmation" then
		callback(confirmation_result or "y")
		return
	end
	local value = desired_name
	desired_name = nil
	callback(value)
end

explorer.setup({
	command = core,
	target = function()
		return fixture
	end,
	git = { enable = true },
	presentation = { devicons = false },
	width = 37,
	mappings = {
		new = "n",
	},
})
explorer._register_commands()
explorer.open()
wait_for(function()
	return view.good == true
end, "real core did not open")

explorer.expand_all()
wait_for(function()
	local hydrated = false
	for _, line in ipairs(lines()) do
		if line:find("Version:", 1, true) then
			hydrated = true
			break
		end
	end
	if not hydrated then
		return false
	end
	return expand_all_complete()
end, "ExpandAll did not finish hydrating dependency properties")
assert(not lines()[1]:find("◌", 1, true), "ignored descendants decorated the solution")

select_matching("S SemanticStudio")
new_kind("solutionFolder", "Solution Items")
wait_for(function()
	for _, line in ipairs(lines()) do
		if line:find("D Solution Items", 1, true) then
			return true
		end
	end
	return false
end, "logical Solution Folder did not reconcile")

select_matching("S SemanticStudio")
new_kind("addExisting", nil, "Add Existing Projects")
wait_for(function()
	for _, line in ipairs(lines()) do
		if line:find("existing", 1, true) then
			return true
		end
	end
	return false
end, "root Add Existing selector did not open")
assert_equal(false, local_mapping("a"), "selector retained the semantic New key")
assert(local_mapping("<Space>"), "selector did not install Space")
local configured_new = local_mapping("n")
assert(configured_new, "configured semantic New mapping disappeared")
configured_new.callback()
explorer.new()
vim.cmd("DotnetWorkspaceExplorerNew")
assert_equal(nil, notification, "semantic New reported an error while the selector was active")

local ignored_row = select_matching("ignored")
assert(
	lines()[ignored_row]:find("◌", 1, true),
	"the exact ignored selector directory was not decorated"
)
assert(not lines()[1]:find("◌", 1, true), "ignored state propagated to the selector root")

select_matching("NOTES.md")
local_mapping("<Space>").callback()
assert_equal(
	"Only .NET project files or non-symbolic directories containing them can be added.",
	notification,
	"root ineligible file did not explain project-only eligibility"
)
notification = nil
select_matching("existing")
explorer.activate()
for _, project in ipairs({
	{ directory = "Root.CSharp", file = "Root.CSharp.csproj" },
	{ directory = "Root.FSharp", file = "Root.FSharp.fsproj" },
	{ directory = "Root.VisualBasic", file = "Root.VisualBasic.vbproj" },
}) do
	wait_for(function()
		for _, line in ipairs(lines()) do
			if line:find(project.directory, 1, true) then
				return true
			end
		end
		return false
	end, "root project directory did not appear: " .. project.directory)
	select_matching(project.directory)
	local_mapping("<Space>").callback()
end
select_matching("NOTES.md")
explorer.activate()
wait_for(function()
	local found = {}
	for _, line in ipairs(lines()) do
		for _, name in ipairs({ "Root.CSharp", "Root.FSharp", "Root.VisualBasic" }) do
			if line:find("P " .. name, 1, true) then
				found[name] = true
			end
		end
	end
	return vim.tbl_count(found) == 3
end, "root C#/F#/VB multi-select did not reconcile")

select_matching("D Solution Items")
explorer.expand()
new_kind("addExisting")
wait_for(function()
	for _, line in ipairs(lines()) do
		if line:find("NOTES.md", 1, true) then
			return true
		end
	end
	return false
end, "solution-folder Add Existing selector did not open")
select_matching("NOTES.md")
local_mapping("<Space>").callback()
confirmation_result = "n"
explorer.activate()
assert(not semantic_root(lines()[1]), "cancelled Add Existing confirmation left the selector")
confirmation_result = "y"
explorer.activate()
wait_for(function()
	local current = lines()
	if not semantic_root(current[1]) then
		return false
	end
	for _, line in ipairs(current) do
		if line:find("NOTES.md", 1, true) then
			return true
		end
	end
	return false
end, "solution item did not reconcile")

select_matching("P Studio.FSharp")
new_kind("addExisting")
wait_for(function()
	for _, line in ipairs(lines()) do
		if line:find("Loose.fs", 1, true) then
			return true
		end
	end
	return false
end, "project Add Existing selector did not open")
select_matching("Loose.fs")
local_mapping("<Space>").callback()
explorer.activate()
wait_for(function()
	local current = lines()
	if not semantic_root(current[1]) then
		return false
	end
	for _, line in ipairs(current) do
		if line:find("Loose.fs", 1, true) then
			return true
		end
	end
	return false
end, "project item did not reconcile")

select_matching("D Foundation")
new_kind("addExisting")
wait_for(function()
	local current = lines()
	if semantic_root(current[1]) then
		return false
	end
	for _, line in ipairs(current) do
		if line:find("Foundation", 1, true) then
			return true
		end
	end
	return false
end, "project-folder Add Existing selector did not open")
select_matching("Foundation")
local_mapping("<Space>").callback()
explorer.activate()
wait_for(function()
	for _, line in ipairs(lines()) do
		if line:find("LooseNested.fs", 1, true) then
			return true
		end
	end
	return false
end, "nested project item did not appear")
select_matching("LooseNested.fs")
explorer.activate()
wait_for(function()
	local current = lines()
	if not semantic_root(current[1]) then
		return false
	end
	for _, line in ipairs(current) do
		if line:find("LooseNested.fs", 1, true) then
			return true
		end
	end
	return false
end, "project-folder item did not reconcile")

select_matching("S SemanticStudio")
new_kind("solutionFolder", "Move Target")
wait_for(function()
	for _, line in ipairs(lines()) do
		if line:find("D Move Target", 1, true) then
			return true
		end
	end
	return false
end, "logical move target did not reconcile")
move_logical("P Root.CSharp", "D Move Target", "logical project move")
move_logical("NOTES.md", "D Move Target", "logical solution-item move")
move_logical("D Solution Items", "D Move Target", "logical Solution Folder move")

select_matching("P Studio.FSharp")
vim.api.nvim_win_set_width(view.win, 43)
local before_cancel_lines = vim.deepcopy(lines())
local before_cancel_maps = {}
for _, lhs in ipairs({ "a", "<Space>", "<CR>", "q", "<Esc>" }) do
	before_cancel_maps[lhs] = local_mapping(lhs)
end
new_kind("addExisting")
wait_for(function()
	local current = lines()
	if semantic_root(current[1]) then
		return false
	end
	for _, line in ipairs(current) do
		if line:find("Studio.FSharp", 1, true) then
			return true
		end
	end
	return false
end, "cancellation selector did not open")
explorer.close()
assert_equal(before_cancel_lines, lines(), "selector cancellation changed semantic rows")
assert_equal(43, vim.api.nvim_win_get_width(view.win), "selector cancellation changed width")
for _, lhs in ipairs({ "a", "<Space>", "<CR>", "q", "<Esc>" }) do
	assert_equal(before_cancel_maps[lhs], local_mapping(lhs), lhs .. " mapping did not restore")
end

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

vim.ui.input = function(options, callback)
	if options.kind == "confirmation" then
		callback("y")
		return
	end
	assert(options.default == "Bootstrap.cs", "Rename did not default to the current node name")
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
	return vim.fn.filereadable(fixture_root .. "/src/Studio.CSharp/Actions/BootstrapRenamed.cs")
		== 1
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
explorer.refresh()
wait_for(function()
	local actions, models, moved
	for index, line in ipairs(lines()) do
		if line:find("Actions", 1, true) then
			actions = index
		elseif line:find("Models", 1, true) then
			models = index
		elseif line:find("ProjectNode.cs", 1, true) then
			moved = index
		end
	end
	return actions and models and moved and actions < moved and moved < models
end, "post-mutation semantic revision did not reconcile")

select_matching("ProjectNode.cs")
explorer.delete()
wait_for(function()
	return vim.fn.filereadable(fixture_root .. "/src/Studio.CSharp/Actions/ProjectNode.cs") == 0
end, "Delete did not complete")
wait_for(function()
	for _, line in ipairs(lines()) do
		if line:find("ProjectNode.cs", 1, true) then
			return false
		end
	end
	return true
end, "deleted node did not reconcile")

explorer.collapse_all()
wait_for(function()
	return #lines() == 1
end, "CollapseAll did not show one collapsed tree")
explorer.git_refresh()
wait_for(function()
	return lines()[1]:find("★", 1, true) ~= nil or lines()[1]:find("✗", 1, true) ~= nil
end, "opt-in Git status did not decorate the solution")

assert(notification == nil, notification or "unexpected explorer error")
explorer.close()
print("DWE bounded real-core smoke passed")
