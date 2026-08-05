local commands = require("dotnet-workspace-explorer.protocol.commands")
local creation = require("dotnet-workspace-explorer.operations.creation")
local confirmation = require("dotnet-workspace-explorer.ui.confirmation")
local rpc = require("dotnet-workspace-explorer.rpc")
local value = require("dotnet-workspace-explorer.protocol.value")

local M = {}
local Mutations = {}
Mutations.__index = Mutations

local command_capabilities = {
	"workspace.commands.describe",
	"workspace.commands.preview",
	"workspace.commands.execute",
}

---@class DweMutationOptions
---@field workspace DweWorkspaceTree
---@field is_live fun(): boolean
---@field selected fun(): DweNodeId?
---@field on_error fun(problem: DweProblem)
---@field on_refresh fun(revision: integer)
---@field on_add_existing? fun(options: DweSelectorStartOptions)

---Creates contextual create/delete workflows for one workspace session.
---@param options DweMutationOptions
---@return table
function Mutations.new(options)
	return setmetatable({
		workspace = options.workspace,
		is_live = options.is_live,
		selected = options.selected,
		on_error = options.on_error,
		on_refresh = options.on_refresh,
		on_add_existing = options.on_add_existing,
		pending = {},
		valid = true,
	}, Mutations)
end

---@return boolean
function Mutations:_live()
	return self.valid and self.is_live()
end

---@param problem DweProblem
function Mutations:_fail(problem)
	if self:_live() then
		self.on_error(problem)
	end
end

---@param names string[]
---@return boolean
function Mutations:_supports(names)
	for _, name in ipairs(names) do
		if not self.workspace:has_capability(name) then
			return false
		end
	end
	return true
end

---@param command_id string
---@param target_id DweNodeId
---@param target_kind DweNodeKind
---@param callback fun()
function Mutations:_describe(command_id, target_id, target_kind, callback)
	self.workspace:request("workspace/commands/describe", {
		commandId = command_id,
		targetNodeId = target_id,
	}, function(err, result)
		if not self:_live() then
			return
		end
		if err then
			return self:_fail(err)
		end
		if not commands.compatible_descriptor(result, command_id, target_kind) then
			return self:_fail({
				code = "incompatible_command",
				message = "The workspace command descriptor is incompatible.",
			})
		end
		callback()
	end)
end

---@param request DweCommandRequest
---@param execution DweCommandExecution
function Mutations:_preview(request, execution)
	self.workspace:request("workspace/commands/preview", request, function(err, preview)
		if not self:_live() then
			return
		end
		if err then
			return self:_fail(err)
		end
		if not commands.compatible_preview(preview) then
			return self:_fail({
				code = "incompatible_preview",
				message = "The workspace command preview is incompatible.",
			})
		end

		confirmation.yes_no(commands.effects_prompt(preview), function(confirmed)
			if not self:_live() or not confirmed then
				return
			end
			local execute = vim.deepcopy(request)
			execute.confirmationToken = preview.confirmationToken
			self:_execute(execute, execution)
		end)
	end)
end

---@param request DweCommandRequest
---@param execution DweCommandExecution
function Mutations:_execute(request, execution)
	self.workspace:request("workspace/commands/execute", request, function(err, result)
		if not self:_live() then
			return
		end
		if err then
			return self:_fail(err)
		end
		if execution == "operation" then
			if not commands.compatible_operation(result) then
				return self:_fail({
					code = "incompatible_result",
					message = "The workspace operation result is incompatible.",
				})
			end
			if self.pending[result.operationId] then
				return self:_fail({
					code = "duplicate_operation",
					message = "The workspace returned a duplicate operation identifier.",
				})
			end
			self.pending[result.operationId] = {
				operation_id = result.operationId,
				revision = result.revision,
				workspace_id = self.workspace.workspace_id,
			}
			return
		end
		if not commands.compatible_applied(result) then
			return self:_fail({
				code = "incompatible_result",
				message = "The workspace command result is incompatible.",
			})
		end
		self.on_refresh(result.revision)
	end)
end

---Prompts for a contextual creation option and executes it.
function Mutations:delete()
	if not self:_live() then
		return
	end
	if not self:_supports(command_capabilities) then
		return self:_fail({
			code = "unsupported_capability",
			message = "The workspace does not support contextual deletion.",
		})
	end
	local target_id = self.selected()
	local node = target_id and self.workspace:get_node(target_id)
	if not node then
		return self:_fail({ code = "unknown_node", message = "Select a workspace node first." })
	end
	local revision = self.workspace.revision
	self:_describe("workspace.delete", target_id, node.kind, function()
		self:_preview({
			commandId = "workspace.delete",
			targetNodeId = target_id,
			arguments = rpc.empty(),
			expectedRevision = revision,
		}, "transaction")
	end)
end

---Consumes asynchronous operation-completion notifications for creation templates.
---@param method string
---@param parameters unknown
function Mutations:notification(method, parameters)
	if
		not self:_live()
		or method ~= "workspace/operations/completed"
		or not self.workspace:has_capability("workspace.operations.completed")
		or not value.is_map(parameters)
		or not value.is_nonempty_string(parameters.operationId)
	then
		return
	end
	local pending = self.pending[parameters.operationId]
	if not pending then
		return
	end
	self.pending[parameters.operationId] = nil
	if not commands.compatible_completion(parameters, pending) then
		return self:_fail({
			code = "incompatible_completion",
			message = "The workspace operation completion is incompatible.",
		})
	end
	if parameters.outcome == "succeeded" then
		return self.on_refresh(parameters.revision)
	end
	self:_fail(commands.completion_problem(parameters))
end

function Mutations:invalidate()
	self.valid, self.pending = false, {}
end

Mutations.create = creation.run

M.Mutations = Mutations
M.compatible_applied = commands.compatible_applied
M.compatible_descriptor = commands.compatible_descriptor
M.compatible_preview = commands.compatible_preview
M.effects_prompt = commands.effects_prompt
return M
