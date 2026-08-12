local M = {}

local group =
	vim.api.nvim_create_augroup("DotnetWorkspaceExplorerPackageTerminal", { clear = true })
local session
local next_token = 0
local size_query = "\27[18t"

local float_highlight = "DotnetWorkspaceExplorerPackageFloat"
local border_highlight = "DotnetWorkspaceExplorerPackageFloatBorder"
local title_highlight = "DotnetWorkspaceExplorerPackageFloatTitle"
local window_highlights = table.concat({
	"Normal:" .. float_highlight,
	"NormalFloat:" .. float_highlight,
	"FloatBorder:" .. border_highlight,
	"FloatTitle:" .. title_highlight,
	"EndOfBuffer:",
}, ",")

local function notify_error(message)
	vim.notify(message, vim.log.levels.ERROR)
end

local function apply_default_highlights()
	vim.api.nvim_set_hl(0, float_highlight, { default = true, link = "Normal" })
	vim.api.nvim_set_hl(0, border_highlight, { default = true, link = "Normal" })
	vim.api.nvim_set_hl(0, title_highlight, { default = true, link = "Title" })
end

local function dimension(total, ratio, minimum)
	local maximum = math.max(1, total - 2)
	return math.min(maximum, math.max(math.min(minimum, maximum), math.floor(total * ratio)))
end

local function window_config()
	local width = dimension(vim.o.columns, 0.85, 20)
	local height = dimension(vim.o.lines, 0.80, 5)
	return {
		relative = "editor",
		style = "minimal",
		border = "rounded",
		width = width,
		height = height,
		row = math.max(0, math.floor((vim.o.lines - height) / 2)),
		col = math.max(0, math.floor((vim.o.columns - width) / 2)),
		title = { { " Package Explorer ", title_highlight } },
		title_pos = "center",
	}
end

local function valid_buffer(buf)
	return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

local function valid_window(win)
	return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function schedule_size_report(active)
	local token = active.token
	vim.schedule(function()
		local win = active.win
		if
			session ~= active
			or active.token ~= token
			or not active.size_report_pending
			or not valid_window(win)
			or not active.job_id
		then
			return
		end
		local rows = vim.api.nvim_win_get_height(win)
		local columns = vim.api.nvim_win_get_width(win)
		local sent =
			pcall(vim.api.nvim_chan_send, active.job_id, ("\27[8;%d;%dt"):format(rows, columns))
		if sent then
			active.size_report_pending = false
		end
	end)
end

local function observe_output(active, data)
	local output = active.size_query_tail .. table.concat(data or {}, "\n")
	active.size_query_tail = output:sub(math.max(1, #output - #size_query + 2))
	if output:find(size_query, 1, true) then
		active.size_report_pending = true
		schedule_size_report(active)
	end
end

local function close_window(active)
	local win = active.win
	active.win = nil
	if valid_window(win) then
		pcall(vim.api.nvim_win_close, win, true)
	end
end

local function delete_buffer(buf)
	if valid_buffer(buf) then
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
	end
end

local function stop_job(job_id)
	if job_id and job_id > 0 then
		pcall(vim.fn.jobstop, job_id)
	end
end

local function dispose(active, stop)
	if session ~= active then
		return
	end
	session = nil
	close_window(active)
	if stop then
		stop_job(active.job_id)
	end
	delete_buffer(active.buf)
end

local function show(active)
	if valid_window(active.win) then
		vim.api.nvim_set_current_win(active.win)
		vim.cmd("startinsert")
		return
	end

	active.win = nil
	local win = vim.api.nvim_open_win(active.buf, true, window_config())
	active.win = win
	vim.api.nvim_set_option_value("winhighlight", window_highlights, { win = win })
	vim.api.nvim_create_autocmd("WinClosed", {
		group = group,
		pattern = tostring(win),
		once = true,
		callback = function()
			if session == active and active.token == session.token and active.win == win then
				active.win = nil
			end
		end,
	})
	vim.cmd("startinsert")
	if active.size_report_pending then
		schedule_size_report(active)
	end
end

local function reconcile_layout()
	local active = session
	if not active or not valid_window(active.win) then
		return
	end
	vim.api.nvim_win_set_config(active.win, window_config())
	vim.api.nvim_set_option_value("winhighlight", window_highlights, { win = active.win })
end

apply_default_highlights()

vim.api.nvim_create_autocmd("ColorScheme", {
	group = group,
	callback = apply_default_highlights,
})

vim.api.nvim_create_autocmd("VimResized", {
	group = group,
	callback = function()
		vim.schedule(reconcile_layout)
	end,
})

local function valid_launch(argv, target)
	return type(argv) == "table"
		and #argv == 2
		and type(argv[1]) == "string"
		and argv[1] ~= ""
		and type(argv[2]) == "string"
		and type(target) == "string"
		and target ~= ""
end

---Opens the sole Package Explorer terminal, or focuses it when the target already matches.
---@param argv string[]
---@param target string
---@return true?, string?
function M.open(argv, target)
	if not valid_launch(argv, target) then
		local message = "Package Explorer launch arguments are invalid."
		notify_error(message)
		return nil, message
	end

	if session then
		if session.target ~= target then
			local message = (
				"Package Explorer is already active for %s. "
				.. "Kill it before opening another target."
			):format(session.target)
			notify_error(message)
			return nil, message
		end
		local shown, show_error = pcall(show, session)
		if not shown then
			close_window(session)
			local message = "Package Explorer could not reopen: " .. tostring(show_error)
			notify_error(message)
			return nil, message
		end
		return true
	end

	if vim.fn.executable(argv[1]) ~= 1 then
		local message = "Package Explorer executable not found: " .. argv[1]
		notify_error(message)
		return nil, message
	end

	next_token = next_token + 1
	local active = {
		buf = vim.api.nvim_create_buf(false, true),
		job_id = nil,
		size_query_tail = "",
		size_report_pending = false,
		target = target,
		token = next_token,
		win = nil,
	}
	session = active
	vim.bo[active.buf].bufhidden = "hide"
	vim.bo[active.buf].swapfile = false

	local started, job_or_error = pcall(vim.api.nvim_buf_call, active.buf, function()
		return vim.fn.jobstart(argv, {
			env = { DOTNET_PACKAGE_EXPLORER_EMBEDDED = "1" },
			term = true,
			on_stdout = function(_, data)
				observe_output(active, data)
			end,
			on_exit = function(job_id)
				local token = active.token
				vim.schedule(function()
					if
						session == active
						and session.token == token
						and session.job_id == job_id
					then
						dispose(active, false)
					end
				end)
			end,
		})
	end)
	if not started or type(job_or_error) ~= "number" or job_or_error <= 0 then
		dispose(active, false)
		local message = "Package Explorer could not start: " .. tostring(job_or_error)
		notify_error(message)
		return nil, message
	end
	active.job_id = job_or_error

	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		buffer = active.buf,
		once = true,
		callback = function()
			if
				session == active
				and session.token == active.token
				and session.buf == active.buf
			then
				session = nil
				close_window(active)
				stop_job(active.job_id)
			end
		end,
	})

	local shown, show_error = pcall(show, active)
	if not shown then
		dispose(active, true)
		local message = "Package Explorer could not open its terminal: " .. tostring(show_error)
		notify_error(message)
		return nil, message
	end
	return true
end

---Terminates and removes the sole Package Explorer terminal, if one exists.
function M.kill()
	local active = session
	if active then
		dispose(active, true)
	end
end

return M
