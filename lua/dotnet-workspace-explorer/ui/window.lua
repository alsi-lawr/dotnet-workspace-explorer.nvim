local config = require("dotnet-workspace-explorer.config")
local presentation = require("dotnet-workspace-explorer.ui.presentation")

local M = {}

---@param kind "buf"|"win"
---@param id? integer
---@return boolean
function M.valid(kind, id)
	return id ~= nil and vim.api["nvim_" .. kind .. "_is_valid"](id)
end

---@param state DweViewState
---@param win? integer
---@return boolean
function M.normal_editor(state, win)
	return M.valid("win", win)
		and win ~= state.win
		and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ""
end

---@param state DweViewState
---@param win? integer
function M.remember_editor(state, win)
	if M.normal_editor(state, win) then
		state.editor_win = win
	end
end

---@param state DweViewState
local function start_editor_tracking(state)
	state.editor_group =
		vim.api.nvim_create_augroup("DotnetWorkspaceExplorerEditorWindow", { clear = true })
	vim.api.nvim_create_autocmd("WinEnter", {
		group = state.editor_group,
		callback = function()
			M.remember_editor(state, vim.api.nvim_get_current_win())
		end,
	})
end

---@param state DweViewState
local function stop_editor_tracking(state)
	if state.editor_group then
		pcall(vim.api.nvim_del_augroup_by_id, state.editor_group)
	end
	state.editor_group, state.editor_win = nil, nil
end

---Creates the explorer buffer and split if either does not yet exist.
---@param state DweViewState
function M.open(state)
	local current = vim.api.nvim_get_current_win()
	M.remember_editor(state, current)
	if not M.valid("buf", state.buf) then
		state.buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(state.buf, "dotnet-workspace-explorer://tree")
		vim.bo[state.buf].buftype, vim.bo[state.buf].bufhidden = "nofile", "hide"
		vim.bo[state.buf].swapfile, vim.bo[state.buf].modifiable = false, false
		for name, link in pairs(presentation.links) do
			vim.api.nvim_set_hl(0, "DotnetWorkspaceExplorer" .. name, {
				default = true,
				link = link,
			})
		end
	end
	if not M.valid("win", state.win) then
		local options = config.get()
		vim.cmd(options.position == "left" and "topleft vsplit" or "botright vsplit")
		state.win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(state.win, state.buf)
		vim.api.nvim_win_set_width(state.win, options.width)
		vim.wo[state.win].cursorline, vim.wo[state.win].wrap, vim.wo[state.win].signcolumn =
			true, false, "yes"
		vim.api.nvim_set_current_win(current)
		start_editor_tracking(state)
	end
end

---@param state DweViewState
function M.close(state)
	if M.valid("win", state.win) then
		vim.api.nvim_win_close(state.win, true)
	end
	state.win = nil
	stop_editor_tracking(state)
end

---@param state DweViewState
function M.focus(state)
	if M.valid("win", state.win) then
		M.remember_editor(state, vim.api.nvim_get_current_win())
		vim.api.nvim_set_current_win(state.win)
	end
end

---@param state DweViewState
---@return boolean
function M.is_open(state)
	return M.valid("win", state.win)
end

---Opens a path in the most recently used normal editor window.
---@param state DweViewState
---@param path string
---@return true?, string?
function M.open_file(state, path)
	M.remember_editor(state, vim.api.nvim_get_current_win())
	local target = M.normal_editor(state, state.editor_win) and state.editor_win or nil
	if not target then
		local alternate = vim.fn.win_getid(vim.fn.winnr("#"))
		target = M.normal_editor(state, alternate) and alternate or nil
	end
	if not target then
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			if M.normal_editor(state, win) then
				target = win
				break
			end
		end
	end
	local opened, open_error = pcall(function()
		if not target then
			if not M.valid("win", state.win) then
				error("The workspace explorer is not open.")
			end
			vim.api.nvim_set_current_win(state.win)
			vim.cmd(config.get().position == "left" and "rightbelow vsplit" or "leftabove vsplit")
			target = vim.api.nvim_get_current_win()
		else
			vim.api.nvim_set_current_win(target)
		end
		vim.cmd({ cmd = "edit", args = { path } })
		state.editor_win = target
	end)
	if not opened then
		return nil, tostring(open_error)
	end
	return true
end

return M
