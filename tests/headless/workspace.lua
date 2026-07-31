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
		self.options.on_notification("workspace/delta", {
			workspaceId = "workspace-id",
			baseRevision = 0,
			newRevision = 1,
			changes = {},
			diagnostics = {},
		})
		return callback({
			code = "workspace_conflict",
			message = "The workspace revision changed.",
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

print("DWE workspace reconciliation probe passed")
