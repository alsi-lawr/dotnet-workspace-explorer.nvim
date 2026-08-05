local config = require("dotnet-workspace-explorer.config")
local window = require("dotnet-workspace-explorer.ui.window")

local M = {}
local selector_mappings = { "a", "<Space>", "<CR>", "q", "<Esc>" }

---@param state DweViewState
---@param lhs string
---@return table?
local function local_mapping(state, lhs)
	local raw = vim.keycode(lhs)
	for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(state.buf, "n")) do
		if mapping.lhsraw == raw then
			return mapping
		end
	end
end

---Installs configured explorer mappings without overwriting user-owned buffer mappings.
---@param state DweViewState
---@param actions table<string, function>
function M.install(state, actions)
	if not window.valid("buf", state.buf) or state.selector_snapshot then
		return
	end
	local blocked = {}
	for lhs, callback in pairs(state.owned_mappings) do
		local mapping = local_mapping(state, lhs)
		if mapping and mapping.callback == callback then
			vim.keymap.del("n", lhs, { buffer = state.buf })
		elseif mapping then
			blocked[lhs] = true
		end
	end
	state.owned_mappings = {}
	local configured = config.get().mappings
	if configured == false then
		return
	end
	for action, lhs in pairs(configured) do
		if lhs ~= false and not blocked[lhs] and not local_mapping(state, lhs) then
			local callback = function()
				actions[action]()
			end
			vim.keymap.set("n", lhs, callback, {
				buffer = state.buf,
				desc = "Workspace explorer: " .. action:gsub("_", " "),
				nowait = true,
				silent = true,
			})
			state.owned_mappings[lhs] = callback
		end
	end
end

---@param state DweViewState
---@param lhs string
---@param mapping table|false|nil
local function restore_mapping(state, lhs, mapping)
	pcall(vim.keymap.del, "n", lhs, { buffer = state.buf })
	if not mapping then
		return
	end
	local options = {
		noremap = mapping.noremap == 1,
		nowait = mapping.nowait == 1,
		silent = mapping.silent == 1,
		script = mapping.script == 1,
		expr = mapping.expr == 1,
		replace_keycodes = mapping.replace_keycodes == 1,
		desc = mapping.desc,
		callback = mapping.callback,
	}
	vim.api.nvim_buf_set_keymap(state.buf, "n", mapping.lhs, mapping.rhs or "", options)
end

---Replaces the normal tree mappings with Add Existing modal mappings.
---@param state DweViewState
---@param snapshot DweViewSnapshot
---@param selector table
---@param actions table
function M.enter_selector(state, snapshot, selector, actions)
	snapshot.mappings = {}
	for _, lhs in ipairs(selector_mappings) do
		snapshot.mappings[lhs] = local_mapping(state, lhs) or false
	end
	state.selector_snapshot = snapshot
	for _, lhs in ipairs(selector_mappings) do
		pcall(vim.keymap.del, "n", lhs, { buffer = state.buf })
	end
	local modal = {
		["<Space>"] = function()
			selector:toggle()
		end,
		["<CR>"] = actions.activate,
		q = actions.close,
		["<Esc>"] = actions.close,
	}
	for lhs, callback in pairs(modal) do
		vim.keymap.set("n", lhs, callback, {
			buffer = state.buf,
			desc = "Workspace explorer: Add Existing",
			nowait = true,
			silent = true,
		})
	end
end

---Restores all mappings captured before entering selector mode.
---@param state DweViewState
---@return DweViewSnapshot?
function M.leave_selector(state)
	local snapshot = state.selector_snapshot
	if not snapshot then
		return nil
	end
	for _, lhs in ipairs(selector_mappings) do
		restore_mapping(state, lhs, snapshot.mappings[lhs] or nil)
	end
	state.selector_snapshot = nil
	return snapshot
end

return M
