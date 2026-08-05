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

---@type DweViewState
local state = {
	rows = {},
	owned_mappings = {},
	ns = vim.api.nvim_create_namespace("dotnet-workspace-explorer"),
}

return state
