local errors = require("dotnet-workspace-explorer.workspace.errors")
local node_model = require("dotnet-workspace-explorer.workspace.node")
local rpc = require("dotnet-workspace-explorer.rpc")

local M = {}
local noop = function() end

---@param self table
---@param id DweNodeId
---@param kinds table<DweNodeKind, boolean>
---@param callback? fun(error: DweProblem?, path?: string)
function M.resolve(self, id, kinds, callback)
	callback = callback or noop
	local node = self.nodes[id]
	if not node or not kinds[node.kind] then
		return callback(rpc.problem("not_openable", "The selected node is not an openable file."))
	end
	local generation, epoch, workspace_id = self.client.generation, self.epoch, self.workspace_id
	local revision = self.revision
	self.client:request(
		"workspace/file/resolve",
		{ targetNodeId = id, expectedRevision = revision },
		function(err, result)
			if not self:_valid(generation, epoch, workspace_id) then
				return callback(errors.stale())
			end
			if err then
				if err.code == "workspace_conflict" then
					self:_invalidate()
				end
				return callback(err)
			end
			if not node_model.valid_file_resolution(result, id, revision) then
				return self.client:_terminate(
					rpc.problem(
						"invalid_file_resolution",
						"The workspace file response is incompatible."
					)
				)
			end
			if
				node.kind == "project"
				and not (
					result.path:lower():match("%.csproj$")
					or result.path:lower():match("%.fsproj$")
					or result.path:lower():match("%.vbproj$")
				)
			then
				return self.client:_terminate(
					rpc.problem(
						"invalid_file_resolution",
						"The workspace project path is incompatible."
					)
				)
			end
			callback(nil, result.path)
		end
	)
end

---@param self table
---@param id DweNodeId
---@param callback? fun(error: DweProblem?, path?: string)
function M.resolve_file(self, id, callback)
	self:_resolve_file(id, { projectFile = true, solutionItem = true }, callback)
end

---@param self table
---@param id DweNodeId
---@param callback? fun(error: DweProblem?, path?: string)
function M.resolve_project(self, id, callback)
	self:_resolve_file(id, { project = true }, callback)
end

return M
