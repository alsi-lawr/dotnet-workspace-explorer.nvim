local value = require("dotnet-workspace-explorer.protocol.value")

local M = {}

---@param path string
---@return boolean
local function is_absolute(path)
	local absolute = vim.fs.abspath(path)
	return absolute == path or vim.fs.normalize(absolute) == vim.fs.normalize(path)
end

---Normalizes a protocol node into the plugin's internal node representation.
---@param candidate unknown
---@param workspace_id string
---@param revision integer
---@param parent_id? DweNodeId
---@return DweNode?
function M.normalize(candidate, workspace_id, revision, parent_id)
	if
		type(candidate) ~= "table"
		or candidate.workspaceId ~= workspace_id
		or candidate.revision ~= revision
		or not value.is_nonempty_string(candidate.id)
		or type(candidate.kind) ~= "string"
		or type(candidate.name) ~= "string"
		or type(candidate.loadState) ~= "string"
		or type(candidate.capabilities) ~= "table"
		or not vim.islist(candidate.capabilities)
	then
		return nil
	end

	local capabilities, unique = {}, {}
	for index, capability in ipairs(candidate.capabilities) do
		if not value.is_nonempty_string(capability) or unique[capability] then
			return nil
		end
		capabilities[index], unique[capability] = capability, true
	end
	return {
		id = candidate.id,
		parent_id = parent_id,
		kind = candidate.kind,
		name = candidate.name,
		load_state = candidate.loadState,
		capabilities = capabilities,
		revision = revision,
	}
end

---@param node? DweNode
---@return boolean
function M.is_expandable(node)
	return node ~= nil
		and (
			node.kind == "workspace"
			or node.kind == "solutionFolder"
			or node.kind == "project"
			or node.kind == "projectFolder"
			or node.kind == "dependencyContainer"
			or node.kind == "dependency"
		)
end

---Validates a file-resolution response exactly, including its absolute path.
---@param result unknown
---@param id DweNodeId
---@param revision integer
---@return boolean
function M.valid_file_resolution(result, id, revision)
	if
		type(result) ~= "table"
		or result.revision ~= revision
		or result.targetNodeId ~= id
		or not value.is_nonempty_string(result.path)
		or not is_absolute(result.path)
	then
		return false
	end
	local keys = { path = true, revision = true, targetNodeId = true }
	local count = 0
	for key in pairs(result) do
		if not keys[key] then
			return false
		end
		count = count + 1
	end
	return count == 3
end

return M
