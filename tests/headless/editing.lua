vim.opt.runtimepath:prepend(vim.fn.getcwd())

local Editing = require("dotnet-workspace-explorer.editing").Editing

local function assert_equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(
			("%s\nexpected: %s\nactual: %s"):format(message, vim.inspect(expected), vim.inspect(actual))
		)
	end
end

local function descriptor(command_id, target_kind)
	local rename = command_id == "workspace.rename"
	return {
		command = {
			id = command_id,
			name = rename and "Rename" or (command_id == "workspace.move" and "Move" or "Copy"),
			access = "write",
			parameters = {
				{
					id = rename and "name" or "sourceNodeIds",
					name = rename and "Name" or "Sources",
					type = rename and "text" or "nodeIdArray",
					required = true,
				},
			},
			targetKinds = { target_kind },
		},
	}
end

local function preview(operation)
	return {
		confirmationToken = "exact-token",
		expiresAtUtc = "2026-07-31T00:00:00Z",
		summary = "Apply workspace edit",
		effects = {
			{
				operation = operation or "modify",
				target = "/workspace/App.fsproj",
				recursive = false,
			},
		},
	}
end

local function harness(options)
	options = options or {}
	local selected, calls, errors, metrics = "file-a", {}, {}, {}
	local nodes = {
		["file-a"] = { id = "file-a", kind = "projectFile", name = "FileA.fs" },
		["file-b"] = { id = "file-b", kind = "projectFile", name = "FileB.fs" },
		destination = { id = "destination", kind = "projectFolder", name = "Destination" },
	}
	local capabilities = {
		["workspace.commands.describe"] = true,
		["workspace.commands.preview"] = true,
		["workspace.commands.execute"] = true,
	}
	for name, value in pairs(options.capabilities or {}) do
		capabilities[name] = value
	end
	local workspace = {
		revision = 9,
		workspace_id = "workspace-id",
		nodes = nodes,
		get_node = function(self, id)
			return self.nodes[id]
		end,
		has_capability = function(_, name)
			return capabilities[name] == true
		end,
	}
	workspace.request = function(_, method, parameters, callback)
		calls[#calls + 1] = { method = method, parameters = vim.deepcopy(parameters) }
		local override = options.responses and options.responses[method]
		if override then
			return override(parameters, callback)
		end
		if method == "workspace/commands/describe" then
			callback(nil, descriptor(parameters.commandId, nodes[parameters.targetNodeId].kind))
		elseif method == "workspace/commands/preview" then
			local operation = parameters.commandId == "workspace.move" and "moveInSolution" or nil
			callback(nil, preview(operation))
		else
			callback(nil, { applied = true, revision = 10 })
		end
	end
	local live = true
	local editing = Editing.new({
		workspace = workspace,
		is_live = function()
			return live
		end,
		selected = function()
			return selected
		end,
		on_error = function(err)
			errors[#errors + 1] = vim.deepcopy(err)
		end,
		on_render = function() end,
		on_success = function(revision)
			metrics.success_revision = revision
		end,
	})
	local pending_confirmation
	local original_select, original_input = vim.ui.select, vim.ui.input
	vim.ui.select = function(items, _, callback)
		if options.defer_confirmation then
			pending_confirmation = callback
		elseif options.confirm == false then
			callback(nil)
		else
			callback(items[1])
		end
	end
	local name_answered = false
	vim.ui.input = function(_, callback)
		if options.rename and not name_answered then
			name_answered = true
			if options.name == false then
				callback(nil)
			else
				callback(options.name or "Renamed.fs")
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
		editing = editing,
		workspace = workspace,
		calls = calls,
		errors = errors,
		metrics = metrics,
		select = function(id)
			selected = id
		end,
		set_live = function(value)
			live = value
		end,
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

local function request(state, method)
	for _, call in ipairs(state.calls) do
		if call.method == method then
			return call.parameters
		end
	end
end

-- Mode switches, reconciliation, and explicit clearing affect the next user action rather than
-- exposing mark storage as a test contract.
do
	local state = harness()
	state.editing:toggle("move")
	state.select("file-b")
	state.editing:toggle("move")
	state.editing:toggle("copy")
	state.select("destination")
	state.editing:place()
	assert_equal({
		commandId = "workspace.copy",
		targetNodeId = "destination",
		arguments = { sourceNodeIds = { "file-b" } },
		expectedRevision = 9,
	}, request(state, "workspace/commands/preview"), "switching mode replaces prior marks")
	state.restore()
end

do
	local state = harness()
	state.editing:toggle("move")
	state.workspace.nodes["file-a"] = nil
	state.editing:reconcile()
	state.select("destination")
	state.editing:place()
	assert_equal("no_marks", state.errors[1].code, "reconciliation removes stale marks")
	state.restore()
end

do
	local state = harness()
	state.editing:toggle("move")
	state.editing:clear()
	state.select("destination")
	state.editing:place()
	assert_equal("no_marks", state.errors[1].code, "ClearMarks removes marks from the next action")
	state.restore()
end

-- Move previews the semantic request, waits for confirmation, then executes the same envelope
-- with only the confirmation token added.
do
	local state = harness({ defer_confirmation = true })
	state.editing:toggle("move")
	state.select("destination")
	state.editing:place()
	local expected = {
		commandId = "workspace.move",
		targetNodeId = "destination",
		arguments = { sourceNodeIds = { "file-a" } },
		expectedRevision = 9,
	}
	assert_equal(expected, request(state, "workspace/commands/preview"), "Move preview envelope")
	assert_equal(nil, request(state, "workspace/commands/execute"), "Move waits for confirmation")
	state.answer_confirmation("Move")
	local execute = vim.deepcopy(expected)
	execute.confirmationToken = "exact-token"
	assert_equal(execute, request(state, "workspace/commands/execute"), "Move execute envelope")
	assert_equal(
		10,
		state.metrics.success_revision,
		"successful Move reconciles the returned revision"
	)
	state.editing:place()
	assert_equal("no_marks", state.errors[1].code, "successful Move clears marks")
	state.restore()
end

-- Copy uses its own command and completes the same mark lifecycle.
do
	local state = harness()
	state.editing:toggle("copy")
	state.select("destination")
	state.editing:place()
	local expected = {
		commandId = "workspace.copy",
		targetNodeId = "destination",
		arguments = { sourceNodeIds = { "file-a" } },
		expectedRevision = 9,
	}
	assert_equal(expected, request(state, "workspace/commands/preview"), "Copy preview envelope")
	local execute = vim.deepcopy(expected)
	execute.confirmationToken = "exact-token"
	assert_equal(execute, request(state, "workspace/commands/execute"), "Copy execute envelope")
	state.restore()
end

-- Cancelling confirmation leaves the user's Copy marks available for another destination.
do
	local options = { confirm = false }
	local state = harness(options)
	state.editing:toggle("copy")
	state.select("destination")
	state.editing:place()
	assert_equal(nil, request(state, "workspace/commands/execute"), "cancelled Copy does not execute")
	assert_equal(nil, state.metrics.success_revision, "cancelled Copy does not reconcile")
	options.confirm = true
	state.editing:place()
	assert_equal(10, state.metrics.success_revision, "cancelled Copy retains marks for a retry")
	state.restore()
end

-- A server rejection is surfaced and preserves the marks so the operation can be retried.
do
	local attempts = 0
	local state = harness({
		responses = {
			["workspace/commands/execute"] = function(_, callback)
				attempts = attempts + 1
				if attempts == 1 then
					callback({ code = "collision", message = "Destination exists." })
				else
					callback(nil, { applied = true, revision = 10 })
				end
			end,
		},
	})
	state.editing:toggle("move")
	state.select("destination")
	state.editing:place()
	assert_equal("collision", state.errors[1].code, "Move surfaces the server rejection")
	assert_equal(nil, state.metrics.success_revision, "rejected Move does not reconcile")
	state.editing:place()
	assert_equal(10, state.metrics.success_revision, "rejected Move retains marks for a retry")
	state.restore()
end

-- Rename uses the selected node and also requires preview confirmation before execution.
do
	local state = harness({ rename = true, name = "Feature.fs", defer_confirmation = true })
	state.editing:rename()
	local expected = {
		commandId = "workspace.rename",
		targetNodeId = "file-a",
		arguments = { name = "Feature.fs" },
		expectedRevision = 9,
	}
	assert_equal(expected, request(state, "workspace/commands/preview"), "Rename preview envelope")
	assert_equal(nil, request(state, "workspace/commands/execute"), "Rename waits for confirmation")
	state.answer_confirmation("y")
	local execute = vim.deepcopy(expected)
	execute.confirmationToken = "exact-token"
	assert_equal(execute, request(state, "workspace/commands/execute"), "Rename execute envelope")
	assert_equal(
		10,
		state.metrics.success_revision,
		"successful Rename reconciles the returned revision"
	)
	state.restore()
end

-- Additive response fields and new effect names are forward-compatible at every editing boundary.
do
	local state = harness({
		responses = {
			["workspace/commands/describe"] = function(_, callback)
				local result = descriptor("workspace.move", "projectFolder")
				result.extension = "ignored"
				result.command.extension = { version = 2 }
				result.command.parameters[1].extension = true
				callback(nil, result)
			end,
			["workspace/commands/preview"] = function(_, callback)
				local result = preview("futureWorkspaceEffect")
				result.extension = "ignored"
				result.effects[1].extension = { detail = "new metadata" }
				callback(nil, result)
			end,
			["workspace/commands/execute"] = function(_, callback)
				callback(nil, { applied = true, revision = 11, extension = "ignored" })
			end,
		},
	})
	state.editing:toggle("move")
	state.select("destination")
	state.editing:place()
	assert_equal({}, state.errors, "additive editing responses remain compatible")
	assert_equal(
		11,
		state.metrics.success_revision,
		"new effect names still permit confirmed execution"
	)
	state.restore()
end

do
	local state = harness({ rename = true, name = false })
	state.editing:rename()
	assert_equal(
		nil,
		request(state, "workspace/commands/describe"),
		"cancelled Rename sends no request"
	)
	assert_equal(nil, state.metrics.success_revision, "cancelled Rename does not reconcile")
	state.restore()
end

-- Keep one incompatible response for each RPC response boundary.
for _, case in ipairs({
	{
		label = "descriptor",
		method = "workspace/commands/describe",
		result = { command = { id = "workspace.move" } },
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
		result = { applied = false, revision = 10 },
		code = "incompatible_result",
	},
}) do
	local state = harness({
		responses = {
			[case.method] = function(_, callback)
				callback(nil, case.result)
			end,
		},
	})
	state.editing:toggle("move")
	state.select("destination")
	state.editing:place()
	assert_equal(case.code, state.errors[1].code, case.label .. " incompatibility is surfaced")
	state.restore()
end

do
	local state = harness({ capabilities = { ["workspace.commands.preview"] = false } })
	state.editing:toggle("move")
	state.select("destination")
	state.editing:place()
	assert_equal(
		nil,
		request(state, "workspace/commands/describe"),
		"unsupported editing makes no request"
	)
	assert_equal("unsupported_capability", state.errors[1].code, "missing capability is rejected")
	state.restore()
end

print("DWE semantic editing probe passed")
