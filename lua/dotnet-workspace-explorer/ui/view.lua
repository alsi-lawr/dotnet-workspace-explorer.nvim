local mappings = require("dotnet-workspace-explorer.ui.mappings")
local renderer = require("dotnet-workspace-explorer.ui.renderer")
local state = require("dotnet-workspace-explorer.ui.state")
local window = require("dotnet-workspace-explorer.ui.window")

local M = {}
local render_window_ms = 50

local function sync_public_state()
	M.rows = state.rows
	M.owned_mappings = state.owned_mappings
	M.buf, M.win, M.editor_win = state.buf, state.win, state.editor_win
	M.selector_snapshot, M.good = state.selector_snapshot, state.good
end
sync_public_state()

---Opens the workspace explorer split.
function M.open()
	window.open(state)
	sync_public_state()
end

---Invalidates the one pending normal-tree render, if any.
function M.invalidate()
	state.render_token = state.render_token + 1
	local pending = state.pending_render
	state.pending_render = nil
	if pending and pending.cancel then
		pcall(pending.cancel)
	end
end

function M.close()
	M.invalidate()
	window.close(state)
	sync_public_state()
end

function M.focus()
	window.focus(state)
	sync_public_state()
end

---@return boolean
function M.is_open()
	return window.is_open(state)
end

---@param path string
---@return true?, string?
function M.open_file(path)
	local opened, err = window.open_file(state, path)
	sync_public_state()
	return opened, err
end

---@param actions table<string, function>
function M.mappings(actions)
	mappings.install(state, actions)
	sync_public_state()
end

---Selects the row under the explorer cursor in a workspace model.
---@param tree DweWorkspaceTree
---@return DweNodeId?
function M.selected(tree)
	if window.valid("win", state.win) then
		local row = state.rows[vim.api.nvim_win_get_cursor(state.win)[1]]
		if row then
			if row.provisional or row.actionable == false then
				return nil
			end
			tree:select(row.id)
		end
	end
	return tree.selected_id
end

---Enters the Add Existing modal view while preserving tree viewport and mappings.
---@param selector table
---@param actions table
---@param tree DweWorkspaceTree
function M.enter_selector(selector, actions, tree)
	if not window.valid("buf", state.buf) or state.selector_snapshot then
		return
	end
	M.invalidate()
	local snapshot = renderer.capture(state, tree.selected_id)
	mappings.enter_selector(state, snapshot, selector, actions)
	renderer.selector(state, selector)
	sync_public_state()
end

---Leaves selector mode and restores the semantic tree viewport.
---@param tree DweWorkspaceTree
function M.leave_selector(tree)
	M.invalidate()
	local snapshot = mappings.leave_selector(state)
	if not snapshot then
		return
	end
	renderer.tree(state, tree, snapshot)
	sync_public_state()
end

---@param selector table
---@return string?
function M.selected_selector(selector)
	if window.valid("win", state.win) then
		local row = state.rows[vim.api.nvim_win_get_cursor(state.win)[1]]
		if row then
			selector:select(row.id)
		end
	end
	return selector.selected_id
end

---@param selector table
function M.render_selector(selector)
	M.invalidate()
	renderer.selector(state, selector)
	sync_public_state()
end

---@param tree DweWorkspaceTree
---@param restoration? DweViewSnapshot
function M.render(tree, restoration)
	M.invalidate()
	renderer.tree(state, tree, restoration)
	sync_public_state()
end

---Coalesces normal-tree changes into one replaceable render per bounded window.
---@param tree DweWorkspaceTree
function M.schedule(tree)
	if not window.valid("win", state.win) or state.selector_snapshot then
		return
	end
	if state.pending_render then
		state.pending_render.tree = tree
		return
	end

	local pending = {
		token = state.render_token,
		tree = tree,
	}
	state.pending_render = pending
	pending.cancel = state.schedule_render(render_window_ms, function()
		if state.pending_render ~= pending or state.render_token ~= pending.token then
			return
		end
		state.pending_render = nil
		pending.cancel = nil
		if not window.valid("win", state.win) or state.selector_snapshot then
			return
		end
		renderer.tree(state, pending.tree)
		sync_public_state()
	end)
end

---Injects the normal-render scheduler; nil restores the production timer.
---@param scheduler? DweRenderScheduler
function M.configure_scheduler(scheduler)
	M.invalidate()
	state.schedule_render = scheduler or state.default_scheduler
end

function M.loading()
	M.invalidate()
	renderer.loading(state)
	sync_public_state()
end

---@param problem DweProblem|string|unknown
function M.failure(problem)
	M.invalidate()
	renderer.failure(state, problem)
	sync_public_state()
end

return M
