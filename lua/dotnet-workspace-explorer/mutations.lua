local rpc = require("dotnet-workspace-explorer.rpc")

local M = {}
local Mutations = {}
Mutations.__index = Mutations

local command_capabilities = {
	"workspace.commands.describe",
	"workspace.commands.preview",
	"workspace.commands.execute",
}

local function integer(value)
	return type(value) == "number" and value >= 0 and value % 1 == 0
end

local function map(value)
	return type(value) == "table" and not vim.islist(value)
end

local function exact_keys(value, allowed)
	if not map(value) then
		return false
	end
	for key in pairs(value) do
		if allowed[key] == nil then
			return false
		end
	end
	for key, required in pairs(allowed) do
		if required and value[key] == nil then
			return false
		end
	end
	return true
end

local function nonempty(value)
	return type(value) == "string" and value ~= ""
end

local function string_list(value)
	if type(value) ~= "table" or not vim.islist(value) then
		return false
	end
	local seen = {}
	for _, item in ipairs(value) do
		if not nonempty(item) or seen[item] then
			return false
		end
		seen[item] = true
	end
	return true
end

local function valid_parameter(value)
	return exact_keys(value, {
		id = true,
		name = true,
		type = true,
		required = true,
	}) and nonempty(value.id) and nonempty(value.name) and nonempty(value.type) and type(
		value.required
	) == "boolean"
end

local function compatible_descriptor(result, command_id, target_kind)
	if not exact_keys(result, { command = true }) then
		return false
	end
	local descriptor = result.command
	if
		not exact_keys(descriptor, {
			id = true,
			name = true,
			access = true,
			parameters = true,
			targetKinds = true,
		})
		or descriptor.id ~= command_id
		or not nonempty(descriptor.name)
		or descriptor.access ~= "write"
		or type(descriptor.parameters) ~= "table"
		or not vim.islist(descriptor.parameters)
		or not string_list(descriptor.targetKinds)
	then
		return false
	end

	local targets = {}
	for _, kind in ipairs(descriptor.targetKinds) do
		targets[kind] = true
	end
	if not targets[target_kind] then
		return false
	end

	local expected = command_id == "workspace.create"
			and {
				selectionId = "text",
				name = "text",
			}
		or command_id == "workspace.addExisting" and {
			selectorId = "text",
			entryIds = "textArray",
		}
		or {}
	local found = {}
	for _, parameter in ipairs(descriptor.parameters) do
		if
			not valid_parameter(parameter)
			or parameter.required ~= true
			or expected[parameter.id] ~= parameter.type
			or found[parameter.id]
		then
			return false
		end
		found[parameter.id] = true
	end
	return vim.tbl_count(found) == vim.tbl_count(expected)
end

local option_keys = {
	selectionId = true,
	kind = true,
	displayName = true,
	description = true,
	execution = true,
	language = false,
}
local add_existing_targets = {
	workspace = true,
	solutionFolder = true,
	project = true,
	projectFolder = true,
}

local function compatible_option(value, add_existing, target_kind)
	if
		not exact_keys(value, option_keys)
		or not nonempty(value.selectionId)
		or not nonempty(value.displayName)
		or type(value.description) ~= "string"
		or (value.language ~= nil and not nonempty(value.language))
	then
		return false
	end
	if value.kind == "empty" then
		return value.execution == "transaction" and value.language == nil
	elseif value.kind == "itemTemplate" or value.kind == "projectTemplate" then
		return value.execution == "operation"
	elseif value.kind == "solutionFolder" then
		return value.execution == "transaction"
			and value.language == nil
			and (target_kind == "workspace" or target_kind == "solutionFolder")
	elseif value.kind == "addExisting" then
		return add_existing
			and add_existing_targets[target_kind] == true
			and value.execution == "transaction"
			and value.language == nil
	end
	return false
end

local function compatible_options(result, revision, add_existing, target_kind)
	if
		not exact_keys(result, { revision = true, options = true })
		or result.revision ~= revision
		or type(result.options) ~= "table"
		or not vim.islist(result.options)
	then
		return false
	end
	local seen = {}
	for _, option in ipairs(result.options) do
		if not compatible_option(option, add_existing, target_kind) or seen[option.selectionId] then
			return false
		end
		seen[option.selectionId] = true
	end
	return true
end

local effect_operations = {
	create = true,
	modify = true,
	trash = true,
	addToProject = true,
	removeFromProject = true,
	addToSolution = true,
	removeFromSolution = true,
}

local function compatible_effect(value)
	return exact_keys(value, {
		operation = true,
		target = true,
		recursive = true,
	}) and effect_operations[value.operation] == true and nonempty(value.target) and type(
		value.recursive
	) == "boolean"
end

local function compatible_preview(result)
	if
		not exact_keys(result, {
			confirmationToken = true,
			expiresAtUtc = true,
			summary = true,
			effects = true,
		})
		or not nonempty(result.confirmationToken)
		or not nonempty(result.expiresAtUtc)
		or not nonempty(result.summary)
		or type(result.effects) ~= "table"
		or not vim.islist(result.effects)
	then
		return false
	end
	for _, effect in ipairs(result.effects) do
		if not compatible_effect(effect) then
			return false
		end
	end
	return true
end

local function compatible_applied(result)
	return exact_keys(result, { applied = true, revision = true })
		and result.applied == true
		and integer(result.revision)
end

local function compatible_operation(result)
	return exact_keys(result, { operationId = true, revision = true })
		and nonempty(result.operationId)
		and integer(result.revision)
end

local function compatible_diagnostic(value, workspace_id, revision)
	if
		not exact_keys(value, {
			workspaceId = true,
			revision = true,
			severity = true,
			code = true,
			message = true,
			retryable = true,
		})
		or value.workspaceId ~= workspace_id
		or value.revision ~= revision
		or not nonempty(value.severity)
		or not nonempty(value.code)
		or not nonempty(value.message)
		or type(value.retryable) ~= "boolean"
	then
		return false
	end
	return true
end

local function compatible_completion(parameters, pending)
	local outcome = parameters.outcome
	if
		not exact_keys(parameters, {
			workspaceId = true,
			operationId = true,
			sequence = true,
			revision = true,
			outcome = true,
			diagnostics = true,
		})
		or parameters.workspaceId ~= pending.workspace_id
		or parameters.operationId ~= pending.operation_id
		or not integer(parameters.sequence)
		or not integer(parameters.revision)
		or parameters.revision < pending.revision
		or (outcome ~= "succeeded" and outcome ~= "cancelled" and outcome ~= "failed")
		or type(parameters.diagnostics) ~= "table"
		or not vim.islist(parameters.diagnostics)
	then
		return false
	end
	for _, diagnostic in ipairs(parameters.diagnostics) do
		if not compatible_diagnostic(diagnostic, pending.workspace_id, parameters.revision) then
			return false
		end
	end
	return parameters.outcome == "succeeded" or #parameters.diagnostics > 0
end

local function completion_problem(parameters)
	local diagnostic = parameters.diagnostics[1]
	return {
		code = diagnostic and diagnostic.code or parameters.outcome,
		message = diagnostic and diagnostic.message
			or ("The workspace operation " .. parameters.outcome .. "."),
	}
end

local function effects_prompt(preview)
	local lines = { preview.summary }
	for _, effect in ipairs(preview.effects) do
		local suffix = effect.recursive and " (recursive)" or ""
		lines[#lines + 1] = ("• %s %s%s"):format(effect.operation, effect.target, suffix)
	end
	return table.concat(lines, "\n")
end

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

function Mutations:_live()
	return self.valid and self.is_live()
end

function Mutations:_fail(problem)
	if self:_live() then
		self.on_error(problem)
	end
end

function Mutations:_supports(names)
	for _, name in ipairs(names) do
		if not self.workspace:has_capability(name) then
			return false
		end
	end
	return true
end

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
		if not compatible_descriptor(result, command_id, target_kind) then
			return self:_fail({
				code = "incompatible_command",
				message = "The workspace command descriptor is incompatible.",
			})
		end
		callback()
	end)
end

function Mutations:_preview(request, destructive, execution)
	self.workspace:request("workspace/commands/preview", request, function(err, preview)
		if not self:_live() then
			return
		end
		if err then
			return self:_fail(err)
		end
		if not compatible_preview(preview) then
			return self:_fail({
				code = "incompatible_preview",
				message = "The workspace command preview is incompatible.",
			})
		end

		local confirm = destructive and "Delete" or "Create"
		vim.ui.select({ confirm, "Cancel" }, {
			prompt = effects_prompt(preview),
			kind = destructive and "warning" or "confirmation",
		}, function(choice)
			if not self:_live() or choice ~= confirm then
				return
			end
			local execute = vim.deepcopy(request)
			execute.confirmationToken = preview.confirmationToken
			self:_execute(execute, execution)
		end)
	end)
end

function Mutations:_execute(request, execution)
	self.workspace:request("workspace/commands/execute", request, function(err, result)
		if not self:_live() then
			return
		end
		if err then
			return self:_fail(err)
		end
		if execution == "operation" then
			if not compatible_operation(result) then
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
		if not compatible_applied(result) then
			return self:_fail({
				code = "incompatible_result",
				message = "The workspace command result is incompatible.",
			})
		end
		self.on_refresh(result.revision)
	end)
end

function Mutations:create()
	if not self:_live() then
		return
	end
	local required = vim.list_extend(vim.deepcopy(command_capabilities), {
		"workspace.create.options",
		"workspace.operations.completed",
	})
	if not self:_supports(required) then
		return self:_fail({
			code = "unsupported_capability",
			message = "The workspace does not support contextual creation.",
		})
	end

	local target_id = self.selected()
	local node = target_id and self.workspace:get_node(target_id)
	if not node then
		return self:_fail({ code = "unknown_node", message = "Select a workspace node first." })
	end
	local revision = self.workspace.revision
	self.workspace:request("workspace/create/options", {
		targetNodeId = target_id,
		expectedRevision = revision,
	}, function(err, result)
		if not self:_live() then
			return
		end
		if err then
			return self:_fail(err)
		end
		if
			not compatible_options(
				result,
				revision,
				self.workspace:has_capability("workspace.addExisting.selector"),
				node.kind
			)
		then
			return self:_fail({
				code = "incompatible_options",
				message = "The workspace creation options are incompatible.",
			})
		end

		vim.ui.select(result.options, {
			prompt = "New",
			kind = "workspace-create-option",
			format_item = function(option)
				if option.description == "" then
					return option.displayName
				end
				return option.displayName .. " — " .. option.description
			end,
		}, function(option)
			if not self:_live() or option == nil then
				return
			end
			if option.kind == "addExisting" then
				if not self.on_add_existing then
					return self:_fail({
						code = "unsupported_capability",
						message = "The Add Existing selector is unavailable.",
					})
				end
				return self.on_add_existing({
					selection_id = option.selectionId,
					target_id = target_id,
					target_kind = node.kind,
					revision = revision,
				})
			end
			vim.ui.input({ prompt = option.displayName .. " name: " }, function(name)
				if not self:_live() or name == nil then
					return
				end
				self:_describe("workspace.create", target_id, node.kind, function()
					local request = {
						commandId = "workspace.create",
						targetNodeId = target_id,
						arguments = {
							selectionId = option.selectionId,
							name = name,
						},
						expectedRevision = revision,
					}
					self:_preview(request, false, option.execution)
				end)
			end)
		end)
	end)
end

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
		}, true, "transaction")
	end)
end

function Mutations:notification(method, parameters)
	if
		not self:_live()
		or method ~= "workspace/operations/completed"
		or not self.workspace:has_capability("workspace.operations.completed")
		or not map(parameters)
		or not nonempty(parameters.operationId)
	then
		return
	end
	local pending = self.pending[parameters.operationId]
	if not pending then
		return
	end
	self.pending[parameters.operationId] = nil
	if not compatible_completion(parameters, pending) then
		return self:_fail({
			code = "incompatible_completion",
			message = "The workspace operation completion is incompatible.",
		})
	end
	if parameters.outcome == "succeeded" then
		return self.on_refresh(parameters.revision)
	end
	self:_fail(completion_problem(parameters))
end

function Mutations:invalidate()
	self.valid, self.pending = false, {}
end

M.Mutations = Mutations
M.compatible_applied = compatible_applied
M.compatible_descriptor = compatible_descriptor
M.compatible_preview = compatible_preview
M.effects_prompt = effects_prompt

return M
