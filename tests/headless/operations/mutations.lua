vim.opt.runtimepath:prepend(vim.fn.getcwd())

local MutationOperations = require("dotnet-workspace-explorer.operations.mutations").Mutations
local rpc = require("dotnet-workspace-explorer.rpc")

local function assert_equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(
			("%s\nexpected: %s\nactual: %s"):format(
				message,
				vim.inspect(expected),
				vim.inspect(actual)
			)
		)
	end
end

local function create_descriptor()
	return {
		command = {
			id = "workspace.create",
			name = "New",
			access = "write",
			parameters = {
				{ id = "selectionId", name = "Selection", type = "text", required = true },
				{ id = "name", name = "Name", type = "text", required = true },
			},
			targetKinds = { "projectFile" },
		},
	}
end

local function delete_descriptor()
	return {
		command = {
			id = "workspace.delete",
			name = "Delete",
			access = "write",
			parameters = {},
			targetKinds = { "projectFile" },
		},
	}
end

local function creation_options()
	return {
		revision = 7,
		options = {
			{
				selectionId = "empty-token",
				kind = "empty",
				displayName = "Empty file",
				description = "Create an empty file",
				execution = "transaction",
			},
			{
				selectionId = "interface-token",
				kind = "itemTemplate",
				displayName = "Interface",
				description = "Create a C# interface",
				execution = "operation",
				language = "C#",
			},
		},
	}
end

local function preview(summary)
	return {
		confirmationToken = "preview-token",
		expiresAtUtc = "2026-07-31T00:00:00.0000000Z",
		summary = summary,
		effects = {
			{ operation = "create", target = "/workspace/Thing.cs", recursive = false },
			{ operation = "modify", target = "/workspace/App.csproj", recursive = false },
		},
	}
end

local function harness(options)
	options = options or {}
	local calls, errors, metrics = {}, {}, {}
	local capabilities = {
		["workspace.create.options"] = true,
		["workspace.commands.describe"] = true,
		["workspace.commands.preview"] = true,
		["workspace.commands.execute"] = true,
		["workspace.operations.completed"] = true,
	}
	for name, enabled in pairs(options.capabilities or {}) do
		capabilities[name] = enabled
	end

	local workspace = {
		revision = 7,
		workspace_id = "workspace-id",
	}
	workspace.has_capability = function(_, name)
		return capabilities[name] == true
	end
	workspace.get_node = function(_, id)
		return id == "selected-node" and { id = id, kind = options.target_kind or "projectFile" }
			or nil
	end
	workspace.request = function(_, method, parameters, callback)
		calls[#calls + 1] = { method = method, parameters = vim.deepcopy(parameters) }
		local override = options.responses and options.responses[method]
		if override then
			return override(parameters, callback)
		end
		if method == "workspace/create/options" then
			return callback(nil, creation_options())
		elseif method == "workspace/commands/describe" then
			local result = parameters.commandId == "workspace.create" and create_descriptor()
				or delete_descriptor()
			return callback(nil, result)
		elseif method == "workspace/commands/preview" then
			return callback(
				nil,
				preview(parameters.commandId == "workspace.create" and "Create" or "Delete")
			)
		elseif method == "workspace/commands/execute" then
			if options.pick == 2 then
				return callback(nil, { operationId = "operation-1", revision = 7 })
			end
			return callback(nil, { applied = true, revision = 8 })
		end
	end

	local live = true
	local controller = MutationOperations.new({
		workspace = workspace,
		is_live = function()
			return live
		end,
		selected = function()
			return "selected-node"
		end,
		on_error = function(err)
			errors[#errors + 1] = vim.deepcopy(err)
		end,
		on_refresh = function(revision)
			metrics.refresh_revision = revision
		end,
		on_add_existing = function(request)
			metrics.add_existing = vim.deepcopy(request)
		end,
	})

	local pending_confirmation
	local original_select, original_input = vim.ui.select, vim.ui.input
	vim.ui.select = function(items, _, callback)
		callback(options.pick == false and nil or items[options.pick or 1])
	end
	local name_answered = false
	vim.ui.input = function(_, callback)
		if options.action ~= "delete" and not name_answered then
			name_answered = true
			if options.name == false then
				callback(nil)
			else
				callback(options.name or "Thing.cs")
			end
		else
			if options.defer_confirmation then
				pending_confirmation = callback
			elseif options.confirm == false then
				callback(nil)
			else
				callback("y")
			end
		end
	end

	return {
		controller = controller,
		calls = calls,
		errors = errors,
		metrics = metrics,
		answer_confirmation = function(answer)
			assert(pending_confirmation, "no confirmation callback is pending")
			local callback = pending_confirmation
			pending_confirmation = nil
			callback(answer)
		end,
		restore = function()
			vim.ui.select, vim.ui.input = original_select, original_input
		end,
	}
end

local function run(options, action)
	options = options or {}
	options.action = action
	local state = harness(options)
	state.controller[action or "create"](state.controller)
	state.restore()
	return state
end

local function request(state, method)
	for _, call in ipairs(state.calls) do
		if call.method == method then
			return call.parameters
		end
	end
end

-- Add Existing is a distinct Create behavior, routed with opaque identifiers instead of a name
-- and command mutation flow.
do
	local option = {
		selectionId = "add-token",
		kind = "addExisting",
		displayName = "Add Existing",
		description = "Browse",
		execution = "transaction",
	}
	local state = run({
		target_kind = "project",
		capabilities = { ["workspace.addExisting.selector"] = true },
		responses = {
			["workspace/create/options"] = function(_, callback)
				callback(nil, { revision = 7, options = { option } })
			end,
		},
	})
	assert_equal({
		selection_id = "add-token",
		target_id = "selected-node",
		target_kind = "project",
		revision = 7,
	}, state.metrics.add_existing, "Add Existing routes its opaque selection")
	assert_equal(
		nil,
		request(state, "workspace/commands/preview"),
		"Add Existing does not preview Create"
	)
end

-- Keep one incompatible response at the Create-options boundary.
do
	local state = run({
		responses = {
			["workspace/create/options"] = function(_, callback)
				callback(nil, { revision = 7, options = { { selectionId = "broken" } } })
			end,
		},
	})
	assert_equal("incompatible_options", state.errors[1].code, "incompatible options are rejected")
	assert_equal(
		nil,
		request(state, "workspace/commands/describe"),
		"incompatible options stop Create"
	)
end

-- Additive response fields and new effect names are forward-compatible at every Create boundary.
do
	local options = creation_options()
	options.extension = "ignored"
	options.options[1].extension = { version = 2 }
	local state = run({
		responses = {
			["workspace/create/options"] = function(_, callback)
				callback(nil, options)
			end,
			["workspace/commands/describe"] = function(_, callback)
				local result = create_descriptor()
				result.extension = "ignored"
				result.command.extension = { version = 2 }
				result.command.parameters[1].extension = true
				callback(nil, result)
			end,
			["workspace/commands/preview"] = function(_, callback)
				local result = preview("Create")
				result.extension = "ignored"
				result.effects[1].operation = "futureWorkspaceEffect"
				result.effects[1].extension = { detail = "new metadata" }
				callback(nil, result)
			end,
			["workspace/commands/execute"] = function(_, callback)
				callback(nil, { applied = true, revision = 9, extension = "ignored" })
			end,
		},
	})
	assert_equal({}, state.errors, "additive Create responses remain compatible")
	assert_equal(
		9,
		state.metrics.refresh_revision,
		"new effect names still permit confirmed execution"
	)
end

-- Transactional Create preserves the preview envelope, waits for confirmation, executes with only
-- the server token added, and reconciles the returned revision.
do
	local state = harness({ defer_confirmation = true })
	state.controller:create()
	local expected = {
		commandId = "workspace.create",
		targetNodeId = "selected-node",
		arguments = { selectionId = "empty-token", name = "Thing.cs" },
		expectedRevision = 7,
	}
	assert_equal(expected, request(state, "workspace/commands/preview"), "Create preview envelope")
	assert_equal(nil, request(state, "workspace/commands/execute"), "Create waits for confirmation")
	state.answer_confirmation("y")
	local execute = vim.deepcopy(expected)
	execute.confirmationToken = "preview-token"
	assert_equal(execute, request(state, "workspace/commands/execute"), "Create execute envelope")
	assert_equal(
		8,
		state.metrics.refresh_revision,
		"transactional Create reconciles the returned revision"
	)
	assert_equal({}, state.errors, "successful Create has no error")
	state.restore()
end

do
	local state = run({ confirm = false })
	assert_equal(
		nil,
		request(state, "workspace/commands/execute"),
		"cancelled Create does not execute"
	)
	assert_equal(nil, state.metrics.refresh_revision, "cancelled Create does not reconcile")
	assert_equal({}, state.errors, "cancelled Create has no error")
end

do
	local state = run({ capabilities = { ["workspace.create.options"] = false } })
	assert_equal(
		nil,
		request(state, "workspace/create/options"),
		"unsupported Create makes no request"
	)
	assert_equal("unsupported_capability", state.errors[1].code, "missing capability is rejected")
end

-- Keep one incompatible descriptor, preview, and execute response for the remaining RPC boundaries.
for _, case in ipairs({
	{
		label = "descriptor",
		method = "workspace/commands/describe",
		result = { command = { id = "workspace.create" } },
		code = "incompatible_command",
	},
	{
		label = "preview",
		method = "workspace/commands/preview",
		result = { confirmationToken = "only" },
		code = "incompatible_preview",
	},
	{
		label = "execute",
		method = "workspace/commands/execute",
		result = { applied = false, revision = 8 },
		code = "incompatible_result",
	},
}) do
	local state = run({
		responses = {
			[case.method] = function(_, callback)
				callback(nil, case.result)
			end,
		},
	})
	assert_equal(case.code, state.errors[1].code, case.label .. " incompatibility is surfaced")
	assert_equal(
		nil,
		state.metrics.refresh_revision,
		case.label .. " incompatibility does not reconcile"
	)
end

-- A server-side command rejection is surfaced without treating the mutation as applied.
do
	local state = run({
		responses = {
			["workspace/commands/execute"] = function(_, callback)
				callback({ code = "revision_conflict", message = "Workspace changed." })
			end,
		},
	})
	assert_equal("revision_conflict", state.errors[1].code, "Create surfaces server rejection")
	assert_equal(nil, state.metrics.refresh_revision, "rejected Create does not reconcile")
end

local function completion(operation_id, outcome, diagnostics)
	return {
		workspaceId = "workspace-id",
		operationId = operation_id,
		sequence = 3,
		revision = 8,
		outcome = outcome,
		diagnostics = diagnostics or {},
	}
end

local function diagnostic(code, message)
	return {
		workspaceId = "workspace-id",
		revision = 8,
		severity = "error",
		code = code,
		message = message,
		retryable = false,
	}
end

-- Operation-backed Create waits for and reconciles only its matching completion.
do
	local state = run({ pick = 2, name = "IThing" })
	assert_equal(
		nil,
		state.metrics.refresh_revision,
		"operation-backed Create waits for completion"
	)
	state.controller:notification(
		"workspace/operations/completed",
		completion("different-operation", "succeeded")
	)
	assert_equal(nil, state.metrics.refresh_revision, "unrelated completion is ignored")
	state.controller:notification(
		"workspace/operations/completed",
		completion("operation-1", "succeeded")
	)
	assert_equal(8, state.metrics.refresh_revision, "matching completion reconciles the revision")
end

-- Failed asynchronous operations surface the server diagnostic and do not refresh.
do
	local state = run({ pick = 2 })
	state.controller:notification(
		"workspace/operations/completed",
		completion("operation-1", "failed", { diagnostic("template_failed", "Core failed") })
	)
	assert_equal("template_failed", state.errors[1].code, "failed operation surfaces diagnostic")
	assert_equal(
		"Core failed",
		state.errors[1].message,
		"failed operation preserves server message"
	)
	assert_equal(nil, state.metrics.refresh_revision, "failed operation does not reconcile")
end

-- Keep one incompatible response at the operation-completion boundary.
do
	local state = run({ pick = 2 })
	local malformed = completion("operation-1", "succeeded")
	malformed.revision = "eight"
	state.controller:notification("workspace/operations/completed", malformed)
	assert_equal(
		"incompatible_completion",
		state.errors[1].code,
		"incompatible completion is rejected"
	)
	assert_equal(nil, state.metrics.refresh_revision, "incompatible completion does not reconcile")
end

-- Delete uses an empty argument map and the same preview/confirmation/execute compatibility
-- contract.
do
	local state = harness({ action = "delete", defer_confirmation = true })
	state.controller:delete()
	local expected = {
		commandId = "workspace.delete",
		targetNodeId = "selected-node",
		arguments = rpc.empty(),
		expectedRevision = 7,
	}
	assert_equal(expected, request(state, "workspace/commands/preview"), "Delete preview envelope")
	assert_equal(nil, request(state, "workspace/commands/execute"), "Delete waits for confirmation")
	state.answer_confirmation("y")
	local execute = vim.deepcopy(expected)
	execute.confirmationToken = "preview-token"
	assert_equal(execute, request(state, "workspace/commands/execute"), "Delete execute envelope")
	assert_equal(8, state.metrics.refresh_revision, "Delete reconciles the returned revision")
	state.restore()
end

do
	local state = run({ confirm = false }, "delete")
	assert_equal(
		nil,
		request(state, "workspace/commands/execute"),
		"cancelled Delete does not execute"
	)
	assert_equal(nil, state.metrics.refresh_revision, "cancelled Delete does not reconcile")
end

print("DWE mutation probe passed")
