local value = require("dotnet-workspace-explorer.protocol.value")

local M = {}

local expected_parameters = {
	["workspace.create"] = { selectionId = "text", name = "text" },
	["workspace.addExisting"] = { selectorId = "text", entryIds = "textArray" },
	["workspace.rename"] = { name = "text" },
	["workspace.move"] = { sourceNodeIds = "nodeIdArray" },
	["workspace.copy"] = { sourceNodeIds = "nodeIdArray" },
	["workspace.delete"] = {},
}

---@param parameter unknown
---@return boolean
local function valid_parameter(parameter)
	return value.has_required_keys(parameter, {
		id = true,
		name = true,
		type = true,
		required = true,
	}) and value.is_nonempty_string(parameter.id) and value.is_nonempty_string(parameter.name) and value.is_nonempty_string(
		parameter.type
	) and type(parameter.required) == "boolean"
end

---Validates a write-command descriptor against the command's protocol schema.
---@param result unknown
---@param command_id string
---@param target_kind DweNodeKind
---@return boolean
function M.compatible_descriptor(result, command_id, target_kind)
	if not value.has_required_keys(result, { command = true }) then
		return false
	end
	local descriptor = result.command
	if
		not value.has_required_keys(descriptor, {
			id = true,
			name = true,
			access = true,
			parameters = true,
			targetKinds = true,
		})
		or descriptor.id ~= command_id
		or not value.is_nonempty_string(descriptor.name)
		or descriptor.access ~= "write"
		or type(descriptor.parameters) ~= "table"
		or not vim.islist(descriptor.parameters)
		or not value.unique_string_list(descriptor.targetKinds)
	then
		return false
	end

	local supported_target = false
	for _, kind in ipairs(descriptor.targetKinds) do
		if kind == target_kind then
			supported_target = true
			break
		end
	end
	if not supported_target then
		return false
	end

	local expected = expected_parameters[command_id]
	if not expected then
		return false
	end
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

local add_existing_targets = {
	workspace = true,
	solutionFolder = true,
	project = true,
	projectFolder = true,
}

---@param option unknown
---@param add_existing boolean
---@param target_kind DweNodeKind
---@return boolean
local function compatible_creation_option(option, add_existing, target_kind)
	if
		not value.has_required_keys(option, {
			selectionId = true,
			kind = true,
			displayName = true,
			description = true,
			execution = true,
		})
		or not value.is_nonempty_string(option.selectionId)
		or not value.is_nonempty_string(option.displayName)
		or type(option.description) ~= "string"
		or (option.language ~= nil and not value.is_nonempty_string(option.language))
	then
		return false
	end

	if option.kind == "empty" then
		return option.execution == "transaction" and option.language == nil
	elseif option.kind == "itemTemplate" or option.kind == "projectTemplate" then
		return option.execution == "operation"
	elseif option.kind == "solutionFolder" then
		return option.execution == "transaction"
			and option.language == nil
			and (target_kind == "workspace" or target_kind == "solutionFolder")
	elseif option.kind == "addExisting" then
		return add_existing
			and add_existing_targets[target_kind] == true
			and option.execution == "transaction"
			and option.language == nil
	end
	return false
end

---Validates contextual creation options for a specific workspace revision and target.
---@param result unknown
---@param revision integer
---@param add_existing boolean
---@param target_kind DweNodeKind
---@return boolean
function M.compatible_creation_options(result, revision, add_existing, target_kind)
	if
		not value.has_required_keys(result, { revision = true, options = true })
		or result.revision ~= revision
		or type(result.options) ~= "table"
		or not vim.islist(result.options)
	then
		return false
	end
	local seen = {}
	for _, option in ipairs(result.options) do
		if
			not compatible_creation_option(option, add_existing, target_kind)
			or seen[option.selectionId]
		then
			return false
		end
		seen[option.selectionId] = true
	end
	return true
end

return M
