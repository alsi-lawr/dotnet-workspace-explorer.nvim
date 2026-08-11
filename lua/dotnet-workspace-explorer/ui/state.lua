---Mutable UI state shared only by the view feature modules.
---@class DweViewState
---@field rows DweRenderRow[]
---@field owned_mappings table<string, function>
---@field ns integer
---@field buf? integer
---@field win? integer
---@field editor_win? integer
---@field editor_group? integer
---@field selector_snapshot? DweViewSnapshot
---@field good? boolean
---@field render_token integer
---@field pending_render? DwePendingNormalRender
---@field schedule_render DweRenderScheduler
---@field default_scheduler DweRenderScheduler

---@class DwePendingNormalRender
---@field token integer
---@field tree DweWorkspaceTree
---@field restoration? DweViewSnapshot
---@field cancel? function

---@alias DweRenderScheduler fun(delay_ms: integer, callback: function): function?

---@param delay_ms integer
---@param callback function
---@return function
local function default_scheduler(delay_ms, callback)
	local timer = vim.defer_fn(callback, delay_ms)
	return function()
		if timer and not timer:is_closing() then
			timer:stop()
			timer:close()
		end
	end
end

---@type DweViewState
local state = {
	rows = {},
	owned_mappings = {},
	ns = vim.api.nvim_create_namespace("dotnet-workspace-explorer"),
	render_token = 0,
	schedule_render = default_scheduler,
}

state.default_scheduler = default_scheduler

return state
