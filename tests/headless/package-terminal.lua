vim.opt.runtimepath:prepend(vim.fn.getcwd())

local function assert_equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(
			("%s\nexpected: %s\nactual: %s"):format(
				message,
				vim.inspect(expected),
				vim.inspect(actual)
			)
		)
	end
end

local function file_text(path)
	local file = io.open(path, "r")
	if not file then
		return ""
	end
	local content = file:read("*a")
	file:close()
	return content
end

local function expected_dimension(total, ratio, minimum)
	local maximum = math.max(1, total - 2)
	return math.min(maximum, math.max(math.min(minimum, maximum), math.floor(total * ratio)))
end

local float_highlight = "DotnetWorkspaceExplorerPackageFloat"
local border_highlight = "DotnetWorkspaceExplorerPackageFloatBorder"
local title_highlight = "DotnetWorkspaceExplorerPackageFloatTitle"

local terminal = require("dotnet-workspace-explorer.package_terminal")
local context = require("dotnet-workspace-explorer.controller.context")
local explorer_session = require("dotnet-workspace-explorer.controller.session")
local view = require("dotnet-workspace-explorer.ui.view")

for name, link in pairs({
	[float_highlight] = "Normal",
	[border_highlight] = "Normal",
	[title_highlight] = "Title",
}) do
	assert_equal(link, vim.api.nvim_get_hl(0, { name = name, link = true }).link, name .. " link")
end
vim.api.nvim_set_hl(0, float_highlight, { link = "ErrorMsg" })
vim.api.nvim_exec_autocmds("ColorScheme", {})
assert_equal(
	"ErrorMsg",
	vim.api.nvim_get_hl(0, { name = float_highlight, link = true }).link,
	"ColorScheme relinking replaced a user override"
)

local original = {
	executable = vim.fn.executable,
	jobstart = vim.fn.jobstart,
	jobstop = vim.fn.jobstop,
	notify = vim.notify,
	open_win = vim.api.nvim_open_win,
	schedule = vim.schedule,
}
local launches, stopped, notifications, scheduled, opened = {}, {}, {}, {}, {}
local next_job = 40
local next_start_result

vim.notify = function(message, level)
	notifications[#notifications + 1] = { message = message, level = level }
end
vim.fn.executable = function(command)
	return command == "missing-package-explorer" and 0 or 1
end
vim.fn.jobstart = function(argv, options)
	local record = {
		argv = vim.deepcopy(argv),
		buf = vim.api.nvim_get_current_buf(),
		options = options,
	}
	launches[#launches + 1] = record
	if next_start_result ~= nil then
		local result = next_start_result
		next_start_result = nil
		return result
	end
	next_job = next_job + 1
	record.job_id = next_job
	return next_job
end
vim.fn.jobstop = function(job_id)
	stopped[#stopped + 1] = job_id
	return 1
end
vim.api.nvim_open_win = function(buf, enter, config)
	opened[#opened + 1] = vim.deepcopy(config)
	return original.open_win(buf, enter, config)
end
vim.schedule = function(callback)
	scheduled[#scheduled + 1] = callback
end

local function run_scheduled()
	while #scheduled > 0 do
		table.remove(scheduled, 1)()
	end
end

local function install_explorer_context(target)
	local stopped_explorer = false
	context.target = target
	context.tree = {
		stop = function()
			stopped_explorer = true
		end,
	}
	return function()
		return stopped_explorer
	end
end

local base_win = vim.api.nvim_get_current_win()
view.open()
local explorer_stopped = install_explorer_context("workspace-one")

local target = "/tmp/project with spaces;$(not-a-shell).fsproj"
assert(terminal.open({ "fake-package-explorer", target }, target), "initial terminal launch failed")
assert_equal(1, #launches, "initial launch count")
assert_equal({ "fake-package-explorer", target }, launches[1].argv, "exact argv")
assert_equal(true, launches[1].options.term, "terminal PTY option")
local first_buf = launches[1].buf
local first_win = vim.api.nvim_get_current_win()
assert(vim.api.nvim_buf_is_valid(first_buf), "initial terminal buffer is invalid")
assert_equal(first_buf, vim.api.nvim_win_get_buf(first_win), "float does not show terminal buffer")

local initial_float = opened[1]
assert_equal("editor", initial_float.relative, "float relative mode")
assert_equal("minimal", initial_float.style, "float style")
assert_equal("rounded", initial_float.border, "float border")
assert_equal("center", initial_float.title_pos, "float title position")
assert_equal({ { " Package Explorer ", title_highlight } }, initial_float.title, "float title")
assert_equal(expected_dimension(vim.o.columns, 0.85, 20), initial_float.width, "float width")
assert_equal(expected_dimension(vim.o.lines, 0.80, 5), initial_float.height, "float height")
assert_equal(
	"Normal:"
		.. float_highlight
		.. ",NormalFloat:"
		.. float_highlight
		.. ",FloatBorder:"
		.. border_highlight
		.. ",FloatTitle:"
		.. title_highlight
		.. ",EndOfBuffer:",
	vim.api.nvim_get_option_value("winhighlight", { win = first_win }),
	"float window highlights"
)

explorer_session.close()
assert(explorer_stopped(), "visible explorer session was not closed")
assert(vim.api.nvim_buf_is_valid(first_buf), "explorer close deleted the package buffer")
assert(vim.api.nvim_win_is_valid(first_win), "explorer close hid the visible package float")
assert_equal(0, #stopped, "explorer close stopped the package job")

vim.api.nvim_set_current_win(base_win)
view.open()
local later_explorer_stopped = install_explorer_context("workspace-two")
explorer_session.close()
assert(later_explorer_stopped(), "later explorer session was not independently closed")
assert(vim.api.nvim_buf_is_valid(first_buf), "later explorer session rebound the package buffer")
assert(vim.api.nvim_win_is_valid(first_win), "later explorer session changed package visibility")

vim.api.nvim_win_close(first_win, true)
assert(vim.api.nvim_buf_is_valid(first_buf), "float close deleted the terminal buffer")
assert_equal(0, #stopped, "float close stopped the terminal job")

view.open()
local hidden_explorer_stopped = install_explorer_context("workspace-three")
explorer_session.close()
assert(hidden_explorer_stopped(), "explorer did not close while package terminal was hidden")
assert(vim.api.nvim_buf_is_valid(first_buf), "explorer close deleted a hidden package buffer")
assert_equal(1, #opened, "explorer close reopened a hidden package float")

assert(terminal.open({ "fake-package-explorer", target }, target), "same target did not reopen")
local reopened_win = vim.api.nvim_get_current_win()
assert_equal(1, #launches, "same target started a second job")
assert_equal(first_buf, vim.api.nvim_win_get_buf(reopened_win), "same target replaced the buffer")
assert(reopened_win ~= first_win, "same target reused a closed window")
vim.api.nvim_set_current_win(base_win)
assert(terminal.open({ "fake-package-explorer", target }, target), "same target did not focus")
assert_equal(reopened_win, vim.api.nvim_get_current_win(), "same target did not focus its float")
assert_equal(2, #opened, "same visible target opened another float")

local accepted, conflict = terminal.open({ "fake-package-explorer", "/tmp/other.fsproj" }, "other")
assert_equal(nil, accepted, "different target was accepted")
assert(conflict:find(target, 1, true), "different-target conflict omitted the active target")
assert_equal(1, #launches, "different target started another job")
assert_equal(0, #stopped, "different target stopped the active job")
assert(vim.api.nvim_win_is_valid(reopened_win), "different target closed the active float")

local old_columns, old_lines = vim.o.columns, vim.o.lines
vim.o.columns, vim.o.lines = 112, 43
scheduled = {}
vim.api.nvim_exec_autocmds("VimResized", {})
assert_equal(1, #scheduled, "VimResized did not schedule layout reconciliation")
local before_resize = vim.api.nvim_win_get_config(reopened_win)
assert(before_resize.width ~= expected_dimension(112, 0.85, 20), "resize ran synchronously")
run_scheduled()
local resized = vim.api.nvim_win_get_config(reopened_win)
local resized_width = expected_dimension(112, 0.85, 20)
local resized_height = expected_dimension(43, 0.80, 5)
assert_equal(resized_width, resized.width, "scheduled float width")
assert_equal(resized_height, resized.height, "scheduled float height")
assert_equal(math.floor((112 - resized_width) / 2), resized.col, "scheduled float column")
assert_equal(math.floor((43 - resized_height) / 2), resized.row, "scheduled float row")

local first_exit = launches[1].options.on_exit
vim.api.nvim_set_current_win(base_win)
view.open()
local explorer_during_kill = install_explorer_context("workspace-four")
terminal.kill()
assert_equal({ 41 }, stopped, "kill did not stop the sole job exactly once")
assert(not vim.api.nvim_buf_is_valid(first_buf), "kill retained the terminal buffer")
assert(not vim.api.nvim_win_is_valid(reopened_win), "kill retained the float")
assert(not explorer_during_kill(), "package kill stopped the explorer session")
assert(view.is_open(), "package kill closed the explorer window")
terminal.kill()
assert_equal({ 41 }, stopped, "empty kill affected another process")
assert(not explorer_during_kill(), "empty package kill stopped the explorer session")
explorer_session.close()
assert(explorer_during_kill(), "explorer did not retain ownership of its own close")

assert(terminal.open({ "fake-package-explorer", target }, target), "second terminal launch failed")
local second = launches[2]
terminal.kill()
assert_equal({ 41, 42 }, stopped, "second kill did not stop its job")
assert(terminal.open({ "fake-package-explorer", target }, target), "third terminal launch failed")
local third = launches[3]
local third_win = vim.api.nvim_get_current_win()
first_exit(41, 0, "exit")
second.options.on_exit(42, 0, "exit")
run_scheduled()
assert(vim.api.nvim_buf_is_valid(third.buf), "stale exit callback deleted a later buffer")
assert(vim.api.nvim_win_is_valid(third_win), "stale exit callback closed a later float")

third.options.on_exit(43, 17, "exit")
run_scheduled()
assert(not vim.api.nvim_buf_is_valid(third.buf), "nonzero exit retained the terminal buffer")
assert(not vim.api.nvim_win_is_valid(third_win), "nonzero exit retained the float")
assert_equal({ 41, 42 }, stopped, "natural exit stopped an unrelated job")

assert(terminal.open({ "fake-package-explorer", target }, target), "wipe terminal launch failed")
local wiped = launches[4]
local wiped_win = vim.api.nvim_get_current_win()
vim.api.nvim_buf_delete(wiped.buf, { force = true })
assert_equal({ 41, 42, 44 }, stopped, "direct buffer wipe did not stop its job")
assert(not vim.api.nvim_win_is_valid(wiped_win), "direct buffer wipe retained the float")

local launch_count = #launches
local missing_ok = terminal.open({ "missing-package-explorer", target }, target)
assert_equal(nil, missing_ok, "missing executable was accepted")
assert_equal(launch_count, #launches, "missing executable reached jobstart")
assert(
	notifications[#notifications].message:find("executable not found", 1, true),
	"missing executable diagnostic"
)

next_start_result = -1
local failed_ok = terminal.open({ "fake-package-explorer", target }, target)
assert_equal(nil, failed_ok, "nonpositive jobstart result was accepted")
local failed = launches[#launches]
assert(not vim.api.nvim_buf_is_valid(failed.buf), "start failure retained its buffer")
assert(notifications[#notifications].message:find("could not start", 1, true), "start diagnostic")

vim.o.columns, vim.o.lines = old_columns, old_lines
terminal.kill()
vim.fn.executable = original.executable
vim.fn.jobstart = original.jobstart
vim.fn.jobstop = original.jobstop
vim.notify = original.notify
vim.api.nvim_open_win = original.open_win
vim.schedule = original.schedule

local child = vim.fn.tempname()
local child_file = assert(io.open(child, "w"))
child_file:write([[#!/bin/sh
if [ ! -t 0 ] || [ ! -t 1 ]; then
  printf 'DWE_NOT_TTY\n' > "$1"
  exit 71
fi
printf 'DWE_TTY_ARGV|%s|%s\n' "$#" "$1" > "$1"
export DWE_REPORT="$1"
exec nvim -u NONE -i NONE --noplugin \
  --cmd 'set noswapfile' \
  --cmd 'au VimResized * call writefile(["S|".&lines." ".&columns],$DWE_REPORT,"a")' \
  --cmd 'call writefile(["DWE_NVIM_READY"],$DWE_REPORT,"a")'
]])
child_file:close()
assert(vim.uv.fs_chmod(child, 493), "could not make terminal child executable")

local real_target = vim.fn.tempname() .. " target with spaces;$(not-a-shell)"
assert(terminal.open({ child, real_target }, real_target), "real PTY launch failed")
local real_win = vim.api.nvim_get_current_win()
local real_buf = vim.api.nvim_win_get_buf(real_win)
local real_job = vim.b[real_buf].terminal_job_id
assert_equal("terminal", vim.bo[real_buf].buftype, "jobstart term=true did not create a terminal")
assert(
	vim.wait(2000, function()
		return file_text(real_target):find("DWE_TTY_ARGV|1|" .. real_target, 1, true) ~= nil
	end),
	"terminal child did not observe TTY stdin/stdout and one exact target argument"
)
assert(
	vim.wait(2000, function()
		return file_text(real_target):find("DWE_NVIM_READY", 1, true) ~= nil
	end),
	"terminal child did not install its resize observer"
)

vim.o.columns, vim.o.lines = 110, 42
vim.api.nvim_exec_autocmds("VimResized", {})
local real_width = expected_dimension(110, 0.85, 20)
local real_height = expected_dimension(42, 0.80, 5)
assert(
	vim.wait(2000, function()
		if not vim.api.nvim_win_is_valid(real_win) then
			return false
		end
		local config = vim.api.nvim_win_get_config(real_win)
		return config.width == real_width and config.height == real_height
	end),
	"real terminal float did not reconcile after resize"
)
assert(
	vim.wait(2000, function()
		return file_text(real_target):find(("S|%d %d"):format(real_height, real_width), 1, true)
			~= nil
	end),
	"terminal PTY did not receive the resized float dimensions"
)

vim.api.nvim_win_close(real_win, true)
assert_equal(
	-1,
	vim.fn.jobwait({ real_job }, 0)[1],
	"real terminal job did not remain running after float close"
)
assert(vim.api.nvim_buf_is_valid(real_buf), "real terminal buffer was deleted on float close")
assert(terminal.open({ child, real_target }, real_target), "real terminal did not reopen")
assert_equal(real_buf, vim.api.nvim_get_current_buf(), "real terminal reopen replaced its buffer")
vim.api.nvim_chan_send(real_job, ":qa!\r")
assert(
	vim.wait(2000, function()
		return not vim.api.nvim_buf_is_valid(real_buf)
	end),
	"natural real-terminal exit did not clean its buffer"
)
assert(vim.fn.delete(child) == 0, "could not remove terminal child")
assert(vim.fn.delete(real_target) == 0, "could not remove terminal child report")

print("DWE-025 package terminal probe passed")
