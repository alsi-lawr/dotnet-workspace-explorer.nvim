local defaults = require("dotnet-workspace-explorer.config.defaults")
local tables = require("dotnet-workspace-explorer.util.table")
local validate = require("dotnet-workspace-explorer.config.validate")

local M = {}
---@type DweConfig
local current = defaults.create()

---Applies a complete plugin configuration from a partial user override.
---@param options? DweConfigInput
function M.setup(options)
	options = options or {}
	validate.input(options)
	local candidate = tables.deep_merge(defaults.create(), options)
	validate.complete(candidate)
	current = candidate
end

---Returns the active validated configuration.
---@return DweConfig
function M.get()
	return current
end

return M
