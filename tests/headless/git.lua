vim.opt.runtimepath:prepend(vim.fn.getcwd())

local Git = require("dotnet-workspace-explorer.git").Git

local function assert_equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(
			("%s\nexpected: %s\nactual: %s"):format(message, vim.inspect(expected), vim.inspect(actual))
		)
	end
end

local function result(status_revision, decorations, available, workspace_revision)
	return {
		available = available ~= false,
		workspaceRevision = workspace_revision or 7,
		statusRevision = status_revision,
		decorations = decorations or {},
	}
end

local function harness(capable)
	local calls, callbacks, errors, renders = {}, {}, {}, 0
	local workspace = {
		phase = "ready",
		revision = 7,
		decorations = {},
		has_capability = function(_, name)
			return capable ~= false and name == "workspace.git.status"
		end,
		request = function(_, method, parameters, callback)
			calls[#calls + 1] = { method = method, parameters = vim.deepcopy(parameters) }
			callbacks[#callbacks + 1] = callback
		end,
	}
	local live = true
	local git = Git.new({
		workspace = workspace,
		is_live = function()
			return live
		end,
		on_error = function(err)
			errors[#errors + 1] = vim.deepcopy(err)
		end,
		on_render = function()
			renders = renders + 1
		end,
	})
	return {
		git = git,
		workspace = workspace,
		calls = calls,
		callbacks = callbacks,
		errors = errors,
		renders = function()
			return renders
		end,
		set_live = function(value)
			live = value
		end,
	}
end

do
	local state = harness(false)
	state.git:start()
	assert_equal(0, #state.calls, "unnegotiated Git sends no status request")
	assert_equal(nil, state.git.group, "unnegotiated Git installs no autocmd")
end

do
	local state = harness()
	state.git:start()
	assert_equal({
		method = "workspace/git/status",
		parameters = { expectedRevision = 7 },
	}, state.calls[1], "open sends exact Git status request")
	assert_equal(2, #vim.api.nvim_get_autocmds({ group = state.git.group }), "owned Git autocmds")

	state.git:request()
	state.git:request()
	assert_equal(1, #state.calls, "events coalesce behind one in-flight request")
	state.callbacks[1](
		nil,
		result(1, {
			{ nodeId = "file", state = "changed" },
			{ nodeId = "project", state = "added" },
		})
	)
	assert_equal(2, #state.calls, "coalesced events create one trailing request")
	assert_equal({
		file = "changed",
		project = "added",
	}, state.workspace.decorations, "valid current snapshot applies")
	assert_equal(1, state.renders(), "valid snapshot renders once")

	state.callbacks[2](nil, result(1, { { nodeId = "file", state = "added" } }))
	assert_equal("changed", state.workspace.decorations.file, "duplicate status revision is ignored")
	assert_equal(1, state.renders(), "duplicate status revision does not render")

	state.git:request()
	state.workspace.revision = 8
	state.callbacks[3](nil, result(2, { { nodeId = "file", state = "added" } }, true, 7))
	assert_equal("changed", state.workspace.decorations.file, "workspace mismatch is ignored")
	assert_equal(1, state.renders(), "workspace mismatch does not render")

	state.git:request()
	state.callbacks[4](
		nil,
		result(3, {
			{ nodeId = "same", state = "added" },
			{ nodeId = "same", state = "changed" },
		}, true, 8)
	)
	assert_equal("incompatible_git_status", state.errors[1].code, "duplicate node IDs reject")
	assert_equal("changed", state.workspace.decorations.file, "malformed snapshot leaves decorations")

	state.git:request()
	state.callbacks[5](nil, result(4, {}, false, 8))
	assert_equal({}, state.workspace.decorations, "newer unavailable snapshot clears decorations")
	assert_equal(2, state.renders(), "unavailable clear renders once")

	state.git:request()
	state.callbacks[6](nil, result(3, { { nodeId = "late", state = "added" } }, true, 8))
	assert_equal({}, state.workspace.decorations, "older same-session snapshot is ignored")
	assert_equal(2, state.renders(), "older same-session snapshot does not render")

	state.git:request()
	state.callbacks[7](nil, result(5, { { nodeId = "file", state = "deleted" } }, true, 8))
	assert_equal("incompatible_git_status", state.errors[2].code, "invalid decoration state rejects")
	assert_equal({}, state.workspace.decorations, "invalid decoration leaves the current snapshot")

	state.git:disable(true)
	assert_equal(nil, state.git.group, "disable removes owned autocmd group")
	assert_equal({}, state.workspace.decorations, "disable clears decorations")
	assert(
		not pcall(vim.api.nvim_get_autocmds, { group = "DotnetWorkspaceExplorerGit" }),
		"owned Git autocmd group still exists"
	)
end

do
	local state = harness()
	state.git:start()
	state.git:request()
	state.git:invalidate()
	state.callbacks[1](nil, result(1, { { nodeId = "late", state = "added" } }))
	assert_equal({}, state.workspace.decorations, "late replaced-session response is inert")
	assert_equal(0, state.renders(), "late replaced-session response does not render")
end

print("DWE Git status probe passed")
