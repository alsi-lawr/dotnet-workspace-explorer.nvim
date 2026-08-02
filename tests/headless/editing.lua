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

local function preview()
	return {
		confirmationToken = "exact-token",
		expiresAtUtc = "2026-07-31T00:00:00Z",
		summary = "Apply workspace edit",
		effects = {
			{ operation = "modify", target = "/workspace/App.fsproj", recursive = false },
		},
	}
end

local function harness(options)
	options = options or {}
	local selected, calls, errors, renders, successes, inputs, confirmations =
		"file-a", {}, {}, 0, {}, {}, {}
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
			callback(nil, preview())
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
		on_render = function()
			renders = renders + 1
		end,
		on_success = function(revision)
			successes[#successes + 1] = revision
		end,
	})
	local original_select, original_input, original_confirm =
		vim.ui.select, vim.ui.input, vim.fn.confirm
	vim.ui.select = function(items, _, callback)
		if options.confirm == false then
			callback(nil)
		else
			callback(items[1])
		end
	end
	vim.ui.input = function(input_options, callback)
		inputs[#inputs + 1] = vim.deepcopy(input_options)
		if options.name == false then
			callback(nil)
		else
			callback(options.name or "Renamed.fs")
		end
	end
	vim.fn.confirm = function(prompt, choices, default)
		confirmations[#confirmations + 1] = {
			prompt = prompt,
			choices = choices,
			default = default,
		}
		return options.rename_confirm == false and 2 or 1
	end
	return {
		editing = editing,
		workspace = workspace,
		calls = calls,
		errors = errors,
		successes = successes,
		inputs = inputs,
		confirmations = confirmations,
		renders = function()
			return renders
		end,
		select = function(id)
			selected = id
		end,
		set_live = function(value)
			live = value
		end,
		restore = function()
			vim.ui.select, vim.ui.input, vim.fn.confirm =
				original_select, original_input, original_confirm
		end,
	}
end

do
	local state = harness()
	state.editing:toggle("move")
	state.select("file-b")
	state.editing:toggle("move")
	assert_equal("move", state.workspace.mark_mode, "move mode")
	assert_equal({ ["file-a"] = true, ["file-b"] = true }, state.workspace.marks, "move marks")

	state.editing:toggle("copy")
	assert_equal("copy", state.workspace.mark_mode, "switching mode")
	assert_equal({ ["file-b"] = true }, state.workspace.marks, "switch clears old marks")
	state.editing:toggle("copy")
	assert_equal(nil, state.workspace.mark_mode, "empty mode is cleared")
	assert_equal({}, state.workspace.marks, "active key toggles mark off")

	state.editing:toggle("move")
	state.select("file-a")
	state.editing:toggle("move")
	state.select("destination")
	state.editing:place()
	assert_equal({
		commandId = "workspace.move",
		targetNodeId = "destination",
		arguments = { sourceNodeIds = { "file-b", "file-a" } },
		expectedRevision = 9,
	}, state.calls[2].parameters, "Place sends semantic destination and ordered marks")
	local execute = vim.deepcopy(state.calls[2].parameters)
	execute.confirmationToken = "exact-token"
	assert_equal(execute, state.calls[3].parameters, "Place executes preview request plus only token")
	assert_equal(nil, state.calls[2].parameters.confirmationToken, "preview request is unchanged")
	assert_equal({}, state.workspace.marks, "successful Place clears marks")
	assert_equal({ 10 }, state.successes, "successful Place reconciles once")
	state.restore()
end

do
	local state = harness({ confirm = false })
	state.editing:toggle("copy")
	state.select("destination")
	state.editing:place()
	assert_equal(2, #state.calls, "cancelled Place stops before execute")
	assert_equal({ ["file-a"] = true }, state.workspace.marks, "cancelled Place retains marks")
	assert_equal({}, state.successes, "cancelled Place does not reconcile")
	state.restore()
end

do
	local state = harness({
		responses = {
			["workspace/commands/execute"] = function(_, callback)
				callback({ code = "collision", message = "Destination exists." })
			end,
		},
	})
	state.editing:toggle("move")
	state.select("destination")
	state.editing:place()
	assert_equal("collision", state.errors[1].code, "Place surfaces core failure")
	assert_equal({ ["file-a"] = true }, state.workspace.marks, "failed Place retains marks")
	assert_equal({}, state.successes, "failed Place does not reconcile")
	state.restore()
end

do
	local state = harness({ name = "Feature.fs" })
	state.editing:rename()
	assert_equal({ prompt = "New name: ", default = "FileA.fs" }, state.inputs[1], "Rename input")
	assert_equal({
		commandId = "workspace.rename",
		targetNodeId = "file-a",
		arguments = { name = "Feature.fs" },
		expectedRevision = 9,
	}, state.calls[2].parameters, "Rename exact preview envelope")
	assert_equal(nil, state.calls[2].parameters.arguments.sourceNodeIds, "Rename has no source array")
	assert(state.confirmations[1].prompt:find("/workspace/App.fsproj", 1, true))
	assert_equal("&Yes\n&No", state.confirmations[1].choices, "compact Rename choices")
	assert_equal(2, state.confirmations[1].default, "Rename defaults to No")
	state.restore()
end

do
	local state = harness({ name = "Feature.fs", rename_confirm = false })
	state.editing:rename()
	assert_equal(2, #state.calls, "cancelled Rename confirmation stops before execute")
	assert_equal({}, state.successes, "cancelled Rename does not reconcile")
	state.restore()
end

do
	local state = harness({ name = false })
	state.editing:rename()
	assert_equal(0, #state.calls, "cancelled Rename sends no request")
	state.restore()
end

for _, case in ipairs({
	{
		label = "descriptor",
		method = "workspace/commands/describe",
		result = { command = { id = "workspace.move" } },
		code = "incompatible_command",
		calls = 1,
	},
	{
		label = "preview",
		method = "workspace/commands/preview",
		result = { confirmationToken = "only" },
		code = "incompatible_preview",
		calls = 2,
	},
	{
		label = "execute",
		method = "workspace/commands/execute",
		result = { applied = false, revision = 10 },
		code = "incompatible_result",
		calls = 3,
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
	assert_equal(case.calls, #state.calls, case.label .. " stops the mutation")
	assert_equal(case.code, state.errors[1].code, case.label .. " schema error")
	assert_equal({ ["file-a"] = true }, state.workspace.marks, case.label .. " retains marks")
	state.restore()
end

do
	local state = harness({ capabilities = { ["workspace.commands.preview"] = false } })
	state.editing:toggle("move")
	state.select("destination")
	state.editing:place()
	assert_equal(0, #state.calls, "missing capability sends no request")
	assert_equal("unsupported_capability", state.errors[1].code, "missing capability error")
	assert_equal({ ["file-a"] = true }, state.workspace.marks, "missing capability retains marks")
	state.restore()
end

do
	local state = harness()
	state.editing:toggle("move")
	state.select("file-b")
	state.editing:toggle("move")
	state.workspace.nodes["file-a"] = nil
	state.editing:reconcile()
	assert_equal({ ["file-b"] = true }, state.workspace.marks, "reconciliation keeps present IDs")
	state.editing:clear()
	assert_equal({}, state.workspace.marks, "ClearMarks clears marks")
	assert_equal(nil, state.workspace.mark_mode, "ClearMarks clears mode")
	state.editing:invalidate()
	assert_equal({}, state.workspace.marks, "session replacement clears marks")
	state.restore()
end

print("DWE semantic editing probe passed")
