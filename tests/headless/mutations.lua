vim.opt.runtimepath:prepend(vim.fn.getcwd())

local Mutations = require("dotnet-workspace-explorer.mutations").Mutations
local rpc = require("dotnet-workspace-explorer.rpc")

local function assert_equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(
			("%s\nexpected: %s\nactual: %s"):format(message, vim.inspect(expected), vim.inspect(actual))
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
	local calls, errors, refreshes, selections, inputs = {}, {}, {}, {}, {}
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
		return id == "selected-node" and { id = id, kind = "projectFile" } or nil
	end
	workspace.request = function(_, method, parameters, callback)
		calls[#calls + 1] = { method = method, parameters = vim.deepcopy(parameters) }
		local override = options.responses and options.responses[method]
		if override then
			return override(parameters, callback, calls)
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
	local controller = Mutations.new({
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
			refreshes[#refreshes + 1] = revision
		end,
	})

	local original_select, original_input = vim.ui.select, vim.ui.input
	vim.ui.select = function(items, select_options, callback)
		selections[#selections + 1] = {
			items = vim.deepcopy(items),
			options = vim.deepcopy(select_options),
		}
		if select_options.kind == "workspace-create-option" then
			if options.pick == false then
				callback(nil)
			else
				callback(items[options.pick or 1])
			end
		else
			local choice = options.confirm
			if choice == nil then
				choice = select_options.kind == "warning" and "Delete" or "Create"
			end
			callback(choice == false and nil or choice)
		end
	end
	vim.ui.input = function(input_options, callback)
		inputs[#inputs + 1] = vim.deepcopy(input_options)
		if options.name == false then
			callback(nil)
		else
			callback(options.name or "Thing.cs")
		end
	end

	return {
		controller = controller,
		workspace = workspace,
		calls = calls,
		errors = errors,
		refreshes = refreshes,
		selections = selections,
		inputs = inputs,
		set_live = function(value)
			live = value
		end,
		restore = function()
			vim.ui.select, vim.ui.input = original_select, original_input
		end,
	}
end

local function run(options, action)
	local state = harness(options)
	state.controller[action or "create"](state.controller)
	state.restore()
	return state
end

do
	local state = run()
	assert_equal(
		{ targetNodeId = "selected-node", expectedRevision = 7 },
		state.calls[1].parameters,
		"New sends only the semantic target and current revision"
	)
	assert_equal(
		creation_options().options,
		state.selections[1].items,
		"picker preserves core options"
	)
	assert_equal("workspace-create-option", state.selections[1].options.kind, "creation picker kind")
	assert_equal({ prompt = "Empty file name: " }, state.inputs[1], "name-only prompt")
	assert_equal({
		commandId = "workspace.create",
		targetNodeId = "selected-node",
		arguments = { selectionId = "empty-token", name = "Thing.cs" },
		expectedRevision = 7,
	}, state.calls[3].parameters, "create preview request")
	local execute = vim.deepcopy(state.calls[3].parameters)
	execute.confirmationToken = "preview-token"
	assert_equal(execute, state.calls[4].parameters, "execute is preview request plus token")
	assert_equal(
		nil,
		state.calls[3].parameters.confirmationToken,
		"preview request remains unchanged"
	)
	assert(state.selections[2].options.prompt:find("/workspace/App.csproj", 1, true))
	assert_equal({ 8 }, state.refreshes, "synchronous creation refreshes once")
	assert_equal({}, state.errors, "successful creation errors")
end

for _, case in ipairs({
	{ label = "picker", options = { pick = false }, calls = 1 },
	{ label = "name", options = { name = false }, calls = 1 },
	{ label = "confirmation", options = { confirm = "Cancel" }, calls = 3 },
}) do
	local state = run(case.options)
	assert_equal(case.calls, #state.calls, case.label .. " cancellation request count")
	assert_equal({}, state.refreshes, case.label .. " cancellation refresh")
	assert_equal({}, state.errors, case.label .. " cancellation errors")
end

for _, missing in ipairs({ "workspace.create.options", "workspace.operations.completed" }) do
	local state = run({ capabilities = { [missing] = false } })
	assert_equal(0, #state.calls, missing .. " absence makes no request")
	assert_equal(0, #state.selections, missing .. " absence opens no picker")
	assert_equal({}, state.refreshes, missing .. " absence refresh")
	assert_equal("unsupported_capability", state.errors[1].code, missing .. " error")
end

do
	local state = run({
		responses = {
			["workspace/create/options"] = function(_, callback)
				callback(nil, { revision = 7, options = { { selectionId = "broken" } } })
			end,
		},
	})
	assert_equal(1, #state.calls, "malformed options stops the flow")
	assert_equal("incompatible_options", state.errors[1].code, "malformed options error")
	assert_equal({}, state.refreshes, "malformed options refresh")
end

do
	local state = run({
		responses = {
			["workspace/commands/describe"] = function(_, callback)
				local descriptor = create_descriptor()
				descriptor.command.parameters[1].type = "path"
				callback(nil, descriptor)
			end,
		},
	})
	assert_equal(2, #state.calls, "malformed descriptor stops before preview")
	assert_equal("incompatible_command", state.errors[1].code, "descriptor validation")
end

do
	local state = run({
		responses = {
			["workspace/commands/preview"] = function(_, callback)
				callback(nil, { confirmationToken = "token" })
			end,
		},
	})
	assert_equal(3, #state.calls, "malformed preview stops before confirmation")
	assert_equal("incompatible_preview", state.errors[1].code, "preview validation")
	assert_equal({}, state.refreshes, "malformed preview refresh")
end

do
	local state = run({
		responses = {
			["workspace/commands/execute"] = function(_, callback)
				callback(nil, { applied = false, revision = 8 })
			end,
		},
	})
	assert_equal("incompatible_result", state.errors[1].code, "execute result validation")
	assert_equal({}, state.refreshes, "invalid execute result refresh")
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

do
	local state = run({ pick = 2, name = "IThing" })
	assert_equal({}, state.refreshes, "operation response does not refresh")
	state.controller:notification(
		"workspace/operations/completed",
		completion("different-operation", "succeeded")
	)
	assert_equal({}, state.refreshes, "mismatched completion is ignored")
	state.controller:notification(
		"workspace/operations/completed",
		completion("operation-1", "succeeded")
	)
	assert_equal({ 8 }, state.refreshes, "matching completion refreshes once")
	state.controller:notification(
		"workspace/operations/completed",
		completion("operation-1", "succeeded")
	)
	assert_equal({ 8 }, state.refreshes, "duplicate completion is ignored")
end

for _, outcome in ipairs({ "failed", "cancelled" }) do
	local state = run({ pick = 2 })
	state.controller:notification(
		"workspace/operations/completed",
		completion("operation-1", outcome, { diagnostic(outcome, "Core " .. outcome) })
	)
	assert_equal({}, state.refreshes, outcome .. " operation refresh")
	assert_equal("Core " .. outcome, state.errors[1].message, outcome .. " core diagnostic")
end

do
	local state = run({ pick = 2 })
	state.controller:invalidate()
	state.controller:notification(
		"workspace/operations/completed",
		completion("operation-1", "succeeded")
	)
	assert_equal({}, state.refreshes, "invalidated session completion refresh")
	assert_equal({}, state.errors, "invalidated session completion errors")
end

do
	local state = run({ pick = 2 })
	local malformed = completion("operation-1", "succeeded")
	malformed.revision = "eight"
	state.controller:notification("workspace/operations/completed", malformed)
	assert_equal({}, state.refreshes, "malformed matching completion refresh")
	assert_equal("incompatible_completion", state.errors[1].code, "completion validation")
end

do
	local state = run(nil, "delete")
	assert_equal("warning", state.selections[1].options.kind, "Delete confirmation is destructive")
	assert(state.selections[1].options.prompt:find("/workspace/Thing.cs", 1, true))
	assert_equal({
		commandId = "workspace.delete",
		targetNodeId = "selected-node",
		arguments = rpc.empty(),
		expectedRevision = 7,
	}, state.calls[2].parameters, "Delete targets the exact selected node")
	local execute = vim.deepcopy(state.calls[2].parameters)
	execute.confirmationToken = "preview-token"
	assert_equal(execute, state.calls[3].parameters, "Delete executes exact preview plus token")
	assert_equal({ 8 }, state.refreshes, "Delete refreshes once")
end

do
	local state = run({ confirm = "Cancel" }, "delete")
	assert_equal(2, #state.calls, "Delete cancellation stops before execute")
	assert_equal({}, state.refreshes, "Delete cancellation refresh")
	assert_equal({}, state.errors, "Delete cancellation errors")
end

do
	local frames, started = {}, false
	local client = rpc.Client.new({
		command = "unused",
		target = "unused",
		spawn = function(_, stream, _)
			local process = {}
			function process.write(_, bytes)
				local frame = vim.mpack.decode(bytes)
				frames[#frames + 1] = frame
				if frame[3] == "initialize" then
					stream.stdout(
						nil,
						vim.mpack.encode({
							1,
							frame[2],
							vim.NIL,
							{
								protocolVersion = { major = 1, minor = 0 },
								workspace = { id = "workspace-id", revision = 0 },
								capabilities = frame[4].capabilities,
								limits = { maxFrameBytes = 65536, maxPageSize = 100 },
							},
						})
					)
				end
			end
			function process.kill() end
			return process
		end,
	})
	client:start(function(err)
		assert_equal(nil, err, "RPC initialization")
		started = true
	end)
	assert(
		vim.wait(1000, function()
			return started
		end),
		"RPC initialization timed out"
	)
	local requested = {}
	for _, capability in ipairs(frames[1][4].capabilities) do
		requested[capability] = true
	end
	assert(requested["workspace.create.options"], "creation-options capability was not requested")
	assert(
		requested["workspace.operations.completed"],
		"operation-completion capability was not requested"
	)
	client:stop("test_complete", true)
end

print("DWE mutation probe passed")
