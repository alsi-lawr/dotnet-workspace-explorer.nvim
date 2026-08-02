vim.opt.runtimepath:prepend(vim.fn.getcwd())

local function assert_equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(
			("%s\nexpected: %s\nactual: %s"):format(message, vim.inspect(expected), vim.inspect(actual))
		)
	end
end

local client
local FakeClient = {}
FakeClient.__index = FakeClient

function FakeClient.new(options)
	client = setmetatable({
		generation = 1,
		inert = false,
		state = "ready",
		limits = { maxPageSize = 256 },
		options = options,
		revision = 0,
	}, FakeClient)
	return client
end

function FakeClient:start(callback)
	callback(nil, {
		workspace = {
			id = "workspace-id",
			revision = self.revision,
		},
	})
end

local function node(id, kind, name, revision, load_state)
	return {
		workspaceId = "workspace-id",
		revision = revision,
		id = id,
		kind = kind,
		name = name,
		loadState = load_state or "loaded",
		capabilities = {},
	}
end

function FakeClient:request(method, parameters, callback)
	if method == "workspace/root" then
		return callback(nil, {
			revision = self.revision,
			nodes = {
				node("workspace", "workspace", "Example.slnx", self.revision),
			},
		})
	end
	if method ~= "workspace/children" then
		error("unexpected request " .. method)
	end
	if parameters.parentNodeId == "workspace" then
		return callback(nil, {
			revision = self.revision,
			parentNodeId = "workspace",
			nodes = {
				node(
					"project",
					"project",
					"Example.fsproj",
					self.revision,
					self.revision == 0 and "unloaded" or "hydrated"
				),
			},
		})
	end
	if parameters.parentNodeId ~= "project" then
		error("unexpected parent " .. parameters.parentNodeId)
	end
	if self.revision == 0 then
		self.revision = 1
		callback(nil, {
			revision = self.revision,
			parentNodeId = "project",
			nodes = {
				node("file", "projectFile", "Program.fs", self.revision),
			},
		})
		return self.options.on_notification("workspace/delta", {
			workspaceId = "workspace-id",
			baseRevision = 0,
			newRevision = 1,
			changes = {
				{
					kind = "update",
					parentNodeId = "workspace",
					index = 0,
					node = node("project", "project", "Example.fsproj", 1, "hydrated"),
				},
			},
			diagnostics = {},
		})
	end
	local files = {
		node("file", "projectFile", "Program.fs", self.revision),
	}
	if self.revision == 2 then
		files[#files + 1] = node("second-file", "projectFile", "Feature.fs", self.revision)
	end
	callback(nil, {
		revision = self.revision,
		parentNodeId = "project",
		nodes = files,
	})
end

function FakeClient:_terminate(reason)
	self.inert, self.state, self.termination = true, "failed", reason
end

function FakeClient.has_capability()
	return true
end

function FakeClient:stop()
	self.inert, self.state = true, "stopped"
end

package.loaded["dotnet-workspace-explorer.rpc"] = {
	Client = FakeClient,
	problem = function(code, message, data)
		return { code = code, message = message, data = data }
	end,
}
package.loaded["dotnet-workspace-explorer.workspace"] = nil

local Workspace = require("dotnet-workspace-explorer.workspace").Workspace
local changes, errors = {}, {}
local tree

local function visible_ids()
	local result = {}
	local function add(id)
		result[#result + 1] = id
		if tree.expanded[id] then
			for _, child in ipairs(tree.children[id] or {}) do
				add(child)
			end
		end
	end
	for _, id in ipairs(tree.roots) do
		add(id)
	end
	return result
end

tree = Workspace.new({
	command = "fake",
	target = "Example.slnx",
	on_change = function()
		changes[#changes + 1] = visible_ids()
	end,
	on_error = function(problem)
		errors[#errors + 1] = problem
	end,
})

local start_error
tree:start(function(problem)
	start_error = problem
end)
assert_equal(nil, start_error, "workspace start")
assert_equal({ "workspace" }, changes[#changes], "initial root")

local root_error
tree:expand("workspace", function(problem)
	root_error = problem
end)
assert_equal(nil, root_error, "root expansion")
assert_equal({ "workspace", "project" }, changes[#changes], "loaded root children")

tree:select("project")
local before_hydration = #changes
local project_error
tree:expand("project", function(problem)
	project_error = problem
end)
assert_equal(nil, project_error, "project hydration retries without a stale-tree error")
assert_equal({}, errors, "project hydration does not report a workspace-changed failure")
assert_equal(before_hydration + 1, #changes, "hydration commits one restored tree")
assert_equal(
	{ "workspace", "project", "file" },
	changes[#changes],
	"hydration retains the complete expanded path"
)
assert_equal(true, tree.expanded.workspace, "workspace remains expanded")
assert_equal(true, tree.expanded.project, "project remains expanded")
assert_equal("project", tree.selected_id, "project selection survives hydration")

tree:select("file")
local before_reset = #changes
client.revision = 2
client.options.on_notification("workspace/reset", {
	workspaceId = "workspace-id",
	revision = 2,
	diagnostics = {},
})
assert_equal(before_reset + 1, #changes, "reset commits one restored tree")
assert_equal(
	{ "workspace", "project", "file", "second-file" },
	changes[#changes],
	"reset updates the expanded tree in place"
)
assert_equal("file", tree.selected_id, "deep selection survives reset")
assert_equal(true, tree.expanded.workspace, "workspace remains expanded after reset")
assert_equal(true, tree.expanded.project, "project remains expanded after reset")
assert_equal({}, errors, "reset reconciliation stays silent")
assert_equal(nil, client.termination, "valid reconciliation keeps the session live")

do
	tree:select("project")
	local before_deltas = #changes
	local function notify(base_revision, new_revision, delta_changes)
		client.options.on_notification("workspace/delta", {
			workspaceId = "workspace-id",
			baseRevision = base_revision,
			newRevision = new_revision,
			changes = delta_changes,
			diagnostics = {},
		})
	end

	notify(2, 3, {
		{
			kind = "add",
			parentNodeId = "workspace",
			index = 1,
			node = node("second-project", "project", "Second.fsproj", 3),
		},
	})
	notify(3, 4, {
		{
			kind = "update",
			parentNodeId = "workspace",
			index = 0,
			node = node("project", "project", "Renamed.fsproj", 4),
		},
	})
	notify(4, 5, {
		{
			kind = "move",
			id = "second-file",
			oldParentId = "project",
			oldIndex = 1,
			newParentId = "project",
			newIndex = 0,
		},
	})
	notify(5, 6, {
		{
			kind = "replace",
			oldId = "project",
			parentNodeId = "workspace",
			index = 0,
			node = node("replacement-project", "project", "Replacement.fsproj", 6),
		},
	})
	notify(6, 7, {
		{
			kind = "remove",
			id = "second-project",
			parentNodeId = "workspace",
			index = 1,
		},
	})

	assert_equal(before_deltas + 5, #changes, "compatible deltas render without reconciliation")
	assert_equal(7, tree.revision, "compatible deltas advance the workspace revision")
	assert_equal(
		{ "replacement-project" },
		tree.children.workspace,
		"add, update, replace, and remove preserve root ordering"
	)
	assert_equal(
		{ "second-file", "file" },
		tree.children["replacement-project"],
		"move and replace preserve hydrated children"
	)
	assert_equal(
		"replacement-project",
		tree.nodes["second-file"].parent_id,
		"replacement reparents hydrated children"
	)
	assert_equal(true, tree.expanded["replacement-project"], "replacement preserves expansion")
	assert_equal("replacement-project", tree.selected_id, "replacement preserves selection")
	assert_equal(nil, tree.nodes.project, "replacement removes the old identity")
end

do
	local delta = require("dotnet-workspace-explorer.workspace_delta")
	local state = {
		workspace_id = "workspace-id",
		revision = 1,
		nodes = {
			parent = { id = "parent", parent_id = nil, revision = 1 },
			child = { id = "child", parent_id = "parent", revision = 1 },
		},
		children = { parent = { "child" } },
		roots = { "parent" },
		expanded = { parent = true },
		selected_id = "child",
	}
	local applied = delta.apply(state, {
		workspaceId = "workspace-id",
		baseRevision = 1,
		newRevision = 2,
		changes = {
			{
				kind = "move",
				id = "child",
				oldParentId = "parent",
				oldIndex = 1,
				newParentId = "parent",
				newIndex = 0,
			},
		},
		diagnostics = {},
	}, function()
		error("move normalization was not expected")
	end)
	assert_equal(false, applied, "an inconsistent move index requires reconciliation")
	assert_equal({ "child" }, state.children.parent, "a rejected delta leaves state unchanged")
	assert_equal(1, state.revision, "a rejected delta leaves the revision unchanged")
end

do
	local invalidations, notifications = 0, {}
	local deferred = setmetatable({
		revision = 7,
		on_notification = function(method, parameters)
			notifications[#notifications + 1] = { method, parameters }
		end,
	}, { __index = Workspace })
	deferred._invalidate = function()
		invalidations = invalidations + 1
	end
	deferred:defer_reconciliation()
	deferred:_notification("workspace/reset", { revision = 8 })
	assert_equal(0, invalidations, "selector mode defers semantic reconciliation")
	assert_equal("workspace/reset", notifications[1][1], "deferred reset reaches selector")
	deferred:resume_reconciliation(8)
	assert_equal(1, invalidations, "selector exit starts exactly one reconciliation")
end

local function refresh_harness()
	local requests, invalidations = {}, 0
	local refresh = setmetatable({
		revision = 7,
		epoch = 0,
		workspace_id = "workspace-id",
		reconcile_waiters = {},
		client = {
			generation = 1,
			inert = false,
		},
	}, { __index = Workspace })
	refresh.client.request = function(_, method, parameters, callback)
		assert_equal("workspace/refresh", method, "refresh method")
		requests[#requests + 1] = {
			parameters = parameters,
			callback = callback,
		}
	end
	refresh._invalidate = function(self)
		invalidations = invalidations + 1
		self.epoch = self.epoch + 1
		self.reconciling = true
	end
	local function reconcile(revision)
		refresh.revision = revision
		refresh.reconciling = false
		refresh:_finish_reconcile()
	end
	return refresh, requests, function()
		return invalidations
	end, reconcile
end

do
	local refresh, requests, invalidations, reconcile = refresh_harness()
	local callback_error, callback_result
	refresh:refresh(function(err, result)
		callback_error, callback_result = err, result
	end)
	assert_equal(1, #requests, "refresh starts once")
	assert_equal({ expectedRevision = 7 }, requests[1].parameters, "initial refresh revision")

	refresh.epoch = refresh.epoch + 1
	refresh.reconciling = true
	requests[1].callback(nil, { revision = 8, reset = false })
	assert_equal(1, #requests, "stale refresh waits for active reconciliation")
	assert_equal(nil, callback_error, "stale refresh does not fail before reconciliation")

	reconcile(8)
	assert_equal(2, #requests, "refresh retries once after reconciliation")
	assert_equal({ expectedRevision = 8 }, requests[2].parameters, "retry uses reconciled revision")
	requests[2].callback(nil, { revision = 8, reset = false })
	assert_equal(nil, callback_error, "reconciled refresh succeeds")
	assert_equal({ revision = 8, reset = false }, callback_result, "refresh result")
	assert_equal(1, invalidations(), "successful retry starts one final reconciliation")
end

do
	local refresh, requests, _, reconcile = refresh_harness()
	local callback_error, callback_count = nil, 0
	refresh:refresh(function(err)
		callback_error, callback_count = err, callback_count + 1
	end)
	requests[1].callback({
		code = "workspace_conflict",
		message = "The expected workspace revision is stale.",
	})
	assert_equal(1, #requests, "workspace conflict waits for reconciliation")
	reconcile(8)
	assert_equal(2, #requests, "workspace conflict retries once")

	requests[2].callback({
		code = "workspace_conflict",
		message = "The expected workspace revision is stale again.",
	})
	assert_equal(2, #requests, "second workspace conflict does not retry again")
	assert_equal(1, callback_count, "bounded refresh finishes once")
	assert_equal(
		"workspace_conflict",
		callback_error.code,
		"second conflict reports bounded refresh failure"
	)
end

print("DWE workspace reconciliation probe passed")
