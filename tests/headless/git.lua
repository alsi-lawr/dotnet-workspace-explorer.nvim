vim.opt.runtimepath:prepend(vim.fn.getcwd())

local Git = require("dotnet-workspace-explorer.git").Git
local rpc = require("dotnet-workspace-explorer.rpc")

local function assert_equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(
			("%s\nexpected: %s\nactual: %s"):format(message, vim.inspect(expected), vim.inspect(actual))
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
	capabilities = capabilities == nil and { ["workspace.git.status.v2"] = true } or capabilities
	local calls, callbacks, errors, renders = {}, {}, {}, 0
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

scenario("unnegotiated Git status installs no event source and sends no request", function()
	local state = harness({})
	state.git:start()
	assert_equal(0, #state.calls, "unnegotiated Git sends no status request")
	assert_equal(nil, state.git.group, "unnegotiated Git installs no autocmd")
end)

scenario(
	"version two Git status preserves ordered multi-state decorations and freshness boundaries",
	function()
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
				{ nodeId = "file", states = { "staged", "unstaged", "renamed", "deleted" } },
				{ nodeId = "project", states = { "unmerged", "untracked", "ignored" } },
			})
		)
		assert_equal(2, #state.calls, "coalesced events create one trailing request")
		assert_equal({
			file = { "staged", "unstaged", "renamed", "deleted" },
			project = { "unmerged", "untracked", "ignored" },
		}, state.workspace.decorations, "valid current snapshot applies every ordered state")
		assert_equal(1, state.renders(), "valid snapshot renders once")

		state.callbacks[2](nil, result(1, { { nodeId = "file", states = { "untracked" } } }))
		assert_equal(
			{ "staged", "unstaged", "renamed", "deleted" },
			state.workspace.decorations.file,
			"duplicate status revision is ignored"
		)

		state.git:request()
		state.workspace.revision = 8
		state.callbacks[3](nil, result(2, { { nodeId = "file", states = { "untracked" } } }, true, 7))
		assert_equal(1, state.renders(), "workspace mismatch does not render")

		state.git:request()
		state.callbacks[4](
			nil,
			result(3, {
				{ nodeId = "same", states = { "staged" } },
				{ nodeId = "same", states = { "unstaged" } },
			}, true, 8)
		)
		assert_equal("incompatible_git_status", state.errors[1].code, "duplicate node IDs reject")

		state.git:request()
		state.callbacks[5](nil, result(4, {}, false, 8))
		assert_equal({}, state.workspace.decorations, "newer unavailable snapshot clears decorations")
		assert_equal(2, state.renders(), "unavailable clear renders once")

		for index, states in ipairs({
			{ "unstaged", "staged" },
			{ "staged", "staged" },
			{ "unknown" },
			{},
		}) do
			state.git:request()
			state.callbacks[5 + index](
				nil,
				result(4 + index, { { nodeId = "file", states = states } }, true, 8)
			)
			assert_equal(
				"incompatible_git_status",
				state.errors[1 + index].code,
				"invalid ordered states reject"
			)
		end

		state.git:disable(true)
		assert_equal(nil, state.git.group, "disable removes owned autocmd group")
		assert_equal({}, state.workspace.decorations, "disable clears decorations")
		assert(
			not pcall(vim.api.nvim_get_autocmds, { group = "DotnetWorkspaceExplorerGit" }),
			"owned Git autocmd group still exists"
		)
	end
)

scenario("legacy Git status maps added and changed into the full presentation model", function()
	local state = harness({ ["workspace.git.status"] = true })
	state.git:start()
	state.callbacks[1](
		nil,
		result(1, {
			{ nodeId = "added", state = "added" },
			{ nodeId = "changed", state = "changed" },
		})
	)
	assert_equal({
		added = { "untracked" },
		changed = { "unstaged" },
	}, state.workspace.decorations, "legacy states map to v2 presentation states")
	state.git:disable(false)
end)

scenario("version two shape takes precedence when both Git capabilities are negotiated", function()
	local state = harness({
		["workspace.git.status"] = true,
		["workspace.git.status.v2"] = true,
	})
	state.git:start()
	state.callbacks[1](nil, result(1, { { nodeId = "file", state = "added" } }))
	assert_equal("incompatible_git_status", state.errors[1].code, "legacy shape rejects under v2")
	state.git:disable(false)
end)

scenario("version two only negotiation authorizes the shared Git status method", function()
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
								capabilities = { "workspace.git.status.v2" },
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
		assert_equal(nil, err, "v2-only initialization")
		started = true
	end)
	assert(
		vim.wait(1000, function()
			return started
		end),
		"v2-only initialization timed out"
	)
	client:request("workspace/git/status", { expectedRevision = 7 }, function(err, value)
		response_error, response = err, value
	end)
	assert(
		vim.wait(1000, function()
			return response ~= nil or response_error ~= nil
		end),
		"v2-only Git status timed out"
	)
	assert_equal(nil, response_error, "v2-only Git status authorization")
	assert_equal("workspace/git/status", frames[2][3], "shared Git status method is sent")
	assert_equal({ "staged" }, response.decorations[1].states, "v2 response is delivered")
	client:stop("test_complete", true)
end)

scenario("late Git response from a replaced session remains inert", function()
	local state = harness()
	state.git:start()
	state.git:request()
	state.git:invalidate()
	state.callbacks[1](nil, result(1, { { nodeId = "late", states = { "untracked" } } }))
	assert_equal({}, state.workspace.decorations, "late replaced-session response is inert")
	assert_equal(0, state.renders(), "late replaced-session response does not render")
end)

print("DWE-017 Git status scenarios passed")
