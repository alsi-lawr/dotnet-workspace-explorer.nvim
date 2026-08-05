local rpc = require("dotnet-workspace-explorer.rpc")

local M = {}

---@return DweProblem
function M.stale()
	return rpc.problem("stale_tree", "The workspace tree changed while the request was running.")
end

return M
