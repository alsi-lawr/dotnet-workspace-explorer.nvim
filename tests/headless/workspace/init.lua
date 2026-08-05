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
		refresh_requests = {},
		refresh_responses = {},
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
	if method == "workspace/refresh" then
		self.refresh_requests[#self.refresh_requests + 1] = vim.deepcopy(parameters)
		local response = table.remove(self.refresh_responses, 1)
		if not response then
			error("unexpected refresh request")
		end
		return callback(response.error, response.result)
	end
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
local errors = {}
local tree

local function visible_ids()
	local result = {}
	local function add(id)
		result[#result + 1] = id
		for _, child in ipairs(tree:children_of(id) or {}) do
			add(child)
		end
	end
	add("workspace")
	return result
end

tree = Workspace.new({
	command = "fake",
	target = "Example.slnx",
	on_change = function() end,
	on_error = function(problem)
		errors[#errors + 1] = problem
	end,
})

local start_error
tree:start(function(problem)
	start_error = problem
end)
assert_equal(nil, start_error, "workspace start")
assert_equal({ "workspace" }, visible_ids(), "initial root")

local root_error
tree:expand("workspace", function(problem)
	root_error = problem
end)
assert_equal(nil, root_error, "root expansion")
assert_equal({ "workspace", "project" }, visible_ids(), "loaded root children")

tree:select("project")
local project_error
tree:expand("project", function(problem)
	project_error = problem
end)
assert_equal(nil, project_error, "project hydration retries without a stale-tree error")
assert_equal({}, errors, "project hydration does not report a workspace-changed failure")
assert_equal(
	{ "workspace", "project", "file" },
	visible_ids(),
	"hydration retains the complete expanded path"
)
assert_equal("project", tree.selected_id, "project selection survives hydration")

tree:select("file")
client.revision = 2
client.options.on_notification("workspace/reset", {
	workspaceId = "workspace-id",
	revision = 2,
	diagnostics = {},
})
assert_equal(
	{ "workspace", "project", "file", "second-file" },
	visible_ids(),
	"reset updates the expanded tree in place"
)
assert_equal("file", tree.selected_id, "deep selection survives reset")
assert_equal({}, errors, "reset reconciliation stays silent")

do
	tree:select("project")
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

	assert_equal(
		{ "workspace", "replacement-project", "second-file", "file" },
		visible_ids(),
		"compatible add, update, move, replace, and remove deltas preserve the visible tree"
	)
	assert_equal("replacement-project", tree.selected_id, "replacement preserves selection")
end

do
	client.revision = 8
	client.options.on_notification("workspace/delta", {
		workspaceId = "workspace-id",
		baseRevision = 7,
		newRevision = 8,
		changes = {
			{
				kind = "move",
				id = "second-file",
				oldParentId = "replacement-project",
				oldIndex = 1,
				newParentId = "replacement-project",
				newIndex = 0,
			},
		},
		diagnostics = {},
	})
	assert_equal(
		{ "workspace", "project" },
		visible_ids(),
		"an inconsistent delta is rejected in favour of the authoritative tree"
	)
end

do
	client.revision = 9
	client.refresh_responses = {
		{
			error = {
				code = "workspace_conflict",
				message = "The expected workspace revision is stale.",
			},
		},
		{
			error = {
				code = "workspace_conflict",
				message = "The expected workspace revision is stale again.",
			},
		},
	}
	local callback_error
	tree:refresh(function(err)
		callback_error = err
	end)
	assert_equal(
		{ expectedRevision = 8 },
		client.refresh_requests[1],
		"refresh uses the current revision"
	)
	assert_equal(
		{ expectedRevision = 9 },
		client.refresh_requests[2],
		"conflict retry uses the reconciled revision"
	)
	assert_equal(
		"workspace_conflict",
		callback_error.code,
		"second conflict reports bounded refresh failure"
	)
end

print("DWE workspace reconciliation probe passed")
