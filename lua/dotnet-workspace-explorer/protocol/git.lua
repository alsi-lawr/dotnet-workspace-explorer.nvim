local states = require("dotnet-workspace-explorer.git.states")
local value = require("dotnet-workspace-explorer.protocol.value")

local M = {}

---Validates a Git status snapshot and returns decorations keyed by node ID.
---@param result unknown
---@return table<DweNodeId, DweGitState[]>?
function M.snapshot(result)
	if
		not value.is_map(result)
		or type(result.available) ~= "boolean"
		or not value.is_integer(result.workspaceRevision)
		or not value.is_integer(result.statusRevision)
		or type(result.decorations) ~= "table"
		or not vim.islist(result.decorations)
	then
		return nil
	end

	local decorations, seen = {}, {}
	for _, decoration in ipairs(result.decorations) do
		if not value.is_map(decoration) then
			return nil
		end
		local normalized = states.normalize(decoration.states, false)
		if
			not value.is_nonempty_string(decoration.nodeId)
			or not normalized
			or seen[decoration.nodeId]
		then
			return nil
		end
		seen[decoration.nodeId], decorations[decoration.nodeId] = true, normalized
	end
	if not result.available and next(decorations) ~= nil then
		return nil
	end
	return decorations
end

return M
