local value = require("dotnet-workspace-explorer.protocol.value")

local M = {}

---@param effect unknown
---@return boolean
local function compatible_effect(effect)
	return value.has_required_keys(effect, {
		operation = true,
		target = true,
		recursive = true,
	}) and value.is_nonempty_string(effect.operation) and value.is_nonempty_string(effect.target) and type(
		effect.recursive
	) == "boolean"
end

---Validates a command preview returned by the workspace server.
---@param result unknown
---@return boolean
function M.compatible_preview(result)
	if
		not value.has_required_keys(result, {
			confirmationToken = true,
			expiresAtUtc = true,
			summary = true,
			effects = true,
		})
		or not value.is_nonempty_string(result.confirmationToken)
		or not value.is_nonempty_string(result.expiresAtUtc)
		or not value.is_nonempty_string(result.summary)
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

---@param result unknown
---@return boolean
function M.compatible_applied(result)
	return value.has_required_keys(result, { applied = true, revision = true })
		and result.applied == true
		and value.is_integer(result.revision)
end

---@param result unknown
---@return boolean
function M.compatible_operation(result)
	return value.has_required_keys(result, { operationId = true, revision = true })
		and value.is_nonempty_string(result.operationId)
		and value.is_integer(result.revision)
end

---@param diagnostic unknown
---@param workspace_id string
---@param revision integer
---@return boolean
local function compatible_diagnostic(diagnostic, workspace_id, revision)
	return value.has_required_keys(diagnostic, {
		workspaceId = true,
		revision = true,
		severity = true,
		code = true,
		message = true,
		retryable = true,
	}) and diagnostic.workspaceId == workspace_id and diagnostic.revision == revision and value.is_nonempty_string(
		diagnostic.severity
	) and value.is_nonempty_string(diagnostic.code) and value.is_nonempty_string(
		diagnostic.message
	) and type(diagnostic.retryable) == "boolean"
end

---@param parameters unknown
---@param pending DwePendingOperation
---@return boolean
function M.compatible_completion(parameters, pending)
	if
		not value.has_required_keys(parameters, {
			workspaceId = true,
			operationId = true,
			sequence = true,
			revision = true,
			outcome = true,
			diagnostics = true,
		})
		or parameters.workspaceId ~= pending.workspace_id
		or parameters.operationId ~= pending.operation_id
		or not value.is_integer(parameters.sequence)
		or not value.is_integer(parameters.revision)
		or parameters.revision < pending.revision
		or (parameters.outcome ~= "succeeded" and parameters.outcome ~= "cancelled" and parameters.outcome ~= "failed")
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

---@param completion DweOperationCompletion
---@return DweProblem
function M.completion_problem(completion)
	local diagnostic = completion.diagnostics[1]
	return {
		code = diagnostic and diagnostic.code or completion.outcome,
		message = diagnostic and diagnostic.message
			or ("The workspace operation " .. completion.outcome .. "."),
	}
end

---@param preview DweCommandPreview
---@return string
function M.effects_prompt(preview)
	local lines = { preview.summary }
	for _, effect in ipairs(preview.effects) do
		local suffix = effect.recursive and " (recursive)" or ""
		lines[#lines + 1] = ("• %s %s%s"):format(effect.operation, effect.target, suffix)
	end
	return table.concat(lines, "\n")
end

return M
