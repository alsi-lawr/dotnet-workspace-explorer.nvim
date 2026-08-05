local value = require("dotnet-workspace-explorer.protocol.value")
local message = require("dotnet-workspace-explorer.rpc.message")

local M = {}
local UINT32_MAX = 4294967295

---@param candidate unknown
---@return boolean
function M.request_id(candidate)
	return type(candidate) == "number"
		and candidate >= 0
		and candidate <= UINT32_MAX
		and candidate % 1 == 0
end

---Validates initialization and returns a capability lookup on success.
---@param result unknown
---@param requested table<string, boolean>
---@return table<string, boolean>?, DweProblem?
function M.initialize(result, requested)
	if
		not value.is_map(result)
		or not value.is_map(result.protocolVersion)
		or result.protocolVersion.major ~= 1
		or not value.is_integer(result.protocolVersion.minor)
		or not value.is_map(result.workspace)
		or not value.is_nonempty_string(result.workspace.id)
		or not value.is_integer(result.workspace.revision)
		or type(result.capabilities) ~= "table"
		or not vim.islist(result.capabilities)
		or not value.is_map(result.limits)
		or not value.is_integer(result.limits.maxFrameBytes)
		or result.limits.maxFrameBytes <= 0
		or result.limits.maxFrameBytes > 16777216
		or not value.is_integer(result.limits.maxPageSize)
		or result.limits.maxPageSize <= 0
		or result.limits.maxPageSize > 4096
	then
		return nil, message.problem("invalid_initialize", "The initialize response is malformed.")
	end

	local negotiated = {}
	for _, name in ipairs(result.capabilities) do
		if not value.is_nonempty_string(name) or negotiated[name] or not requested[name] then
			return nil,
				message.problem("invalid_initialize", "The returned capabilities are invalid.")
		end
		negotiated[name] = true
	end
	return negotiated
end

M.UINT32_MAX = UINT32_MAX
return M
