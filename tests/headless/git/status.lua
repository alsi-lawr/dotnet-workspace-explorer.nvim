vim.opt.runtimepath:prepend(vim.fn.getcwd())

local GitStatus = require("dotnet-workspace-explorer.git.status").Git
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

local function scenario(identifier, action)
	local ok, err = pcall(action)
	if not ok then
		error(("DWE-017/%s: %s"):format(identifier, err))
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

local function harness(capabilities)
	capabilities = capabilities == nil and { ["workspace.git.status"] = true } or capabilities
	local calls, callbacks, errors = {}, {}, {}
	local workspace = {
		phase = "ready",
		revision = 7,
		decorations = {},
		has_capability = function(_, name)
			return capabilities[name] == true
		end,
		request = function(_, method, parameters, callback)
			calls[#calls + 1] = { method = method, parameters = vim.deepcopy(parameters) }
			callbacks[#callbacks + 1] = callback
		end,
	}
	local git = GitStatus.new({
		workspace = workspace,
		is_live = function()
			return true
		end,
		on_error = function(err)
			errors[#errors + 1] = vim.deepcopy(err)
		end,
		on_render = function() end,
	})
	return {
		git = git,
		workspace = workspace,
		calls = calls,
		callbacks = callbacks,
		errors = errors,
	}
end

scenario("unnegotiated Git status installs no event source and sends no request", function()
	local state = harness({})
	state.git:start()
	assert_equal(nil, state.calls[1], "unnegotiated Git sends no status request")
end)

scenario("Git status preserves ordered multi-state decorations and freshness boundaries", function()
	local state = harness()
	state.git:start()
	assert_equal({
		method = "workspace/git/status",
		parameters = { expectedRevision = 7 },
	}, state.calls[1], "open sends exact Git status request")
	state.callbacks[1](
		nil,
		result(1, {
			{ nodeId = "file", states = { "staged", "unstaged", "renamed", "deleted" } },
			{ nodeId = "project", states = { "unmerged", "untracked", "ignored" } },
		})
	)
	assert_equal({
		file = { "staged", "unstaged", "renamed", "deleted" },
		project = { "unmerged", "untracked", "ignored" },
	}, state.workspace.decorations, "valid current snapshot applies every ordered state")

	state.git:request()
	state.callbacks[2](nil, result(1, { { nodeId = "file", states = { "untracked" } } }))
	assert_equal(
		{ "staged", "unstaged", "renamed", "deleted" },
		state.workspace.decorations.file,
		"duplicate status revision is ignored"
	)

	state.git:request()
	state.workspace.revision = 8
	state.callbacks[3](nil, result(2, { { nodeId = "file", states = { "untracked" } } }, true, 7))
	assert_equal(
		{ "staged", "unstaged", "renamed", "deleted" },
		state.workspace.decorations.file,
		"response for a replaced workspace revision is ignored"
	)

	state.git:request()
	state.callbacks[4](nil, result(3, {}, false, 8))
	assert_equal({}, state.workspace.decorations, "newer unavailable snapshot clears decorations")

	state.git:request()
	state.callbacks[5](
		nil,
		result(4, { { nodeId = "file", states = { "unstaged", "staged" } } }, true, 8)
	)
	assert_equal("incompatible_git_status", state.errors[1].code, "invalid ordered states reject")

	state.git:disable(true)
	assert_equal({}, state.workspace.decorations, "disable clears decorations")
end)

scenario("Git status accepts additive response fields but requires revision identity", function()
	local state = harness()
	state.git:start()
	local response = result(1, {
		{
			nodeId = "file",
			states = { "staged" },
			additiveDecorationField = "future",
		},
	})
	response.additiveResponseField = { future = true }
	state.callbacks[1](nil, response)
	assert_equal(
		{ file = { "staged" } },
		state.workspace.decorations,
		"additive fields are ignored"
	)

	state.git:request()
	response = result(2, { { nodeId = "file", states = { "unstaged" } } })
	response.workspaceRevision = nil
	state.callbacks[2](nil, response)
	assert_equal(
		"incompatible_git_status",
		state.errors[1].code,
		"missing workspace revision rejects the response"
	)
	assert_equal({ file = { "staged" } }, state.workspace.decorations, "invalid response is inert")
	state.git:disable(false)
end)

scenario("Git status rejects a singular state decoration", function()
	local state = harness()
	state.git:start()
	state.callbacks[1](nil, result(1, { { nodeId = "file", state = "added" } }))
	assert_equal("incompatible_git_status", state.errors[1].code, "singular state rejects")
	state.git:disable(false)
end)

scenario("canonical negotiation authorizes the Git status method", function()
	local frames, started, response_error, response = {}, false
	local client = rpc.Client.new({
		command = "unused",
		target = "unused",
		git_enabled = true,
		spawn = function(_, stream)
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
								workspace = { id = "workspace-id", revision = 7 },
								capabilities = { "workspace.git.status" },
								limits = { maxFrameBytes = 65536, maxPageSize = 100 },
							},
						})
					)
				elseif frame[3] == "workspace/git/status" then
					stream.stdout(
						nil,
						vim.mpack.encode({
							1,
							frame[2],
							vim.NIL,
							result(1, { { nodeId = "file", states = { "staged" } } }),
						})
					)
				end
			end
			function process.kill() end
			return process
		end,
	})
	client:start(function(err)
		assert_equal(nil, err, "Git status initialization")
		started = true
	end)
	assert(
		vim.wait(1000, function()
			return started
		end),
		"Git status initialization timed out"
	)
	local requested = frames[1][4].capabilities
	assert_equal(
		"workspace.git.status",
		requested[#requested],
		"initialization requests Git status"
	)
	client:request("workspace/git/status", { expectedRevision = 7 }, function(err, value)
		response_error, response = err, value
	end)
	assert(
		vim.wait(1000, function()
			return response ~= nil or response_error ~= nil
		end),
		"Git status timed out"
	)
	assert_equal(nil, response_error, "Git status authorization")
	assert_equal("workspace/git/status", frames[2][3], "Git status method is sent")
	assert_equal({ "staged" }, response.decorations[1].states, "Git status response is delivered")
	client:stop("test_complete", true)
end)

scenario("late Git response from a replaced session remains inert", function()
	local state = harness()
	state.git:start()
	state.git:request()
	state.git:invalidate()
	state.callbacks[1](nil, result(1, { { nodeId = "late", states = { "untracked" } } }))
	assert_equal({}, state.workspace.decorations, "late replaced-session response is inert")
end)

print("DWE-017 Git status scenarios passed")
