local M = {}

local workspace = {
	"workspace.root",
	"workspace.children",
	"workspace.file.resolve",
	"workspace.refresh",
	"workspace.delta",
	"workspace.reset",
	"workspace.create.options",
	"workspace.addExisting.selector",
	"workspace.addExisting.presentation.v2",
	"workspace.addExisting.directories.v1",
	"workspace.commands.list",
	"workspace.commands.describe",
	"workspace.commands.preview",
	"workspace.commands.execute",
	"workspace.operations.completed",
}

local git = {
	"workspace.git.status",
	"workspace.git.status.v2",
}

local by_method = {
	["workspace/root"] = "workspace.root",
	["workspace/children"] = "workspace.children",
	["workspace/file/resolve"] = "workspace.file.resolve",
	["workspace/git/status"] = git,
	["workspace/refresh"] = "workspace.refresh",
	["workspace/create/options"] = "workspace.create.options",
	["workspace/addExisting/start"] = "workspace.addExisting.selector",
	["workspace/addExisting/children"] = "workspace.addExisting.selector",
	["workspace/addExisting/close"] = "workspace.addExisting.selector",
	["workspace/commands/list"] = "workspace.commands.list",
	["workspace/commands/describe"] = "workspace.commands.describe",
	["workspace/commands/preview"] = "workspace.commands.preview",
	["workspace/commands/execute"] = "workspace.commands.execute",
}

---Builds the ordered capability list sent during initialization.
---@param git_enabled boolean
---@return string[]
function M.requested(git_enabled)
	local result = vim.deepcopy(workspace)
	if git_enabled then
		vim.list_extend(result, git)
	end
	return result
end

---Returns the capability requirement for an RPC method.
---@param method string
---@return string|string[]|nil
function M.for_method(method)
	return by_method[method]
end

---Checks whether a negotiated capability map satisfies a method requirement.
---@param negotiated table<string, boolean>
---@param required string|string[]|nil
---@return boolean
function M.supports(negotiated, required)
	if required == nil then
		return true
	end
	if type(required) == "string" then
		return negotiated[required] == true
	end
	for _, name in ipairs(required) do
		if negotiated[name] then
			return true
		end
	end
	return false
end

return M
