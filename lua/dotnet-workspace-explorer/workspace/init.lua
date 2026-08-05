local delta = require("dotnet-workspace-explorer.workspace.delta")
local expansion = require("dotnet-workspace-explorer.workspace.expansion")
local files = require("dotnet-workspace-explorer.workspace.files")
local node_model = require("dotnet-workspace-explorer.workspace.node")
local reconcile = require("dotnet-workspace-explorer.workspace.reconcile")
local refresh = require("dotnet-workspace-explorer.workspace.refresh")
local rpc = require("dotnet-workspace-explorer.rpc")

local M = {}

---@class DweWorkspaceTree
local Workspace = {}

Workspace.__index = Workspace

local noop = function() end

---Creates an idle workspace tree and its RPC client.
---@param options DweWorkspaceOptions
---@return DweWorkspaceTree
function Workspace.new(options)
	---@type DweWorkspaceTree
	local self

	local client = rpc.Client.new({
		command = options.command,
		target = options.target,
		spawn = options.spawn,
		max_page_size = options.max_page_size,
		on_notification = function(method, parameters)
			self:_notification(method, parameters)
		end,
		on_error = function(reason)
			self.phase = "failed"
			self.on_error(reason)
		end,
		git_enabled = options.git_enabled == true,
	})

	self = setmetatable({
		nodes = {},
		children = {},
		loading = {},
		roots = {},
		expanded = {},
		selected_id = nil,
		revision = 0,
		reflected_base_revision = nil,
		workspace_id = "",
		phase = "idle",
		decorations = {},
		marks = {},
		mark_mode = nil,
		epoch = 0,
		reconcile_waiters = {},
		reconciling = false,
		reconcile_queued = false,
		reconciliation_deferred = false,
		deferred_reconciliation = false,
		git_enabled = options.git_enabled == true,
		client = client,
		on_change = options.on_change or noop,
		on_error = options.on_error or noop,
		on_notification = options.on_notification or noop,
		_delta = delta,
	}, Workspace)

	return self
end

---@param captured_generation integer
---@param captured_epoch integer
---@param captured_workspace string
---@return boolean
function Workspace:_valid(captured_generation, captured_epoch, captured_workspace)
	return self.client.generation == captured_generation
		and not self.client.inert
		and self.epoch == captured_epoch
		and self.workspace_id == captured_workspace
end

---@param values unknown[]
---@param parent_id? DweNodeId
---@param revision integer
---@param existing table<DweNodeId, DweNode>
---@return DweNode[]?, DweNodeId[]?
function Workspace:_normalize_nodes(values, parent_id, revision, existing)
	local nodes = {}
	local ids = {}
	local unique = {}

	for index, candidate in ipairs(values) do
		local node = node_model.normalize(candidate, self.workspace_id, revision, parent_id)

		if not node or unique[node.id] or existing[node.id] then
			return nil
		end

		nodes[index] = node
		ids[index] = node.id
		unique[node.id] = true
	end

	return nodes, ids
end

---Starts the RPC session and performs the initial reconciliation.
---@param callback? DweWorkspaceCallback
function Workspace:start(callback)
	callback = callback or noop

	if self.phase ~= "idle" then
		return callback(rpc.problem("already_started", "The workspace tree was already started."))
	end

	self.phase = "loading"

	self.client:start(function(request_error, result)
		if request_error then
			self.phase = "failed"
			return callback(request_error)
		end

		self.workspace_id = result.workspace.id
		self.revision = result.workspace.revision
		self:_reconcile(callback)
	end)
end

---@param id DweNodeId
function Workspace:select(id)
	if self.nodes[id] then
		self.selected_id = id
	end
end

---@param id DweNodeId
---@return DweNode?
function Workspace:get_node(id)
	return self.nodes[id]
end

---@param id DweNodeId
---@return DweNodeId?
function Workspace:parent(id)
	local node = self.nodes[id]
	return node and node.parent_id or nil
end

---@param id DweNodeId
---@return DweNodeId[]?
function Workspace:children_of(id)
	return self.children[id]
end

---@param id DweNodeId
---@return boolean
function Workspace:is_expandable(id)
	return node_model.is_expandable(self.nodes[id])
end

---@return boolean
function Workspace:is_terminal()
	return self.client.inert or self.client.state == "failed"
end

---@param method string
---@param parameters? table
---@param callback? DweErrorFirstCallback
---@return integer?
function Workspace:request(method, parameters, callback)
	return self.client:request(method, parameters, callback)
end

---@param name string
---@return boolean
function Workspace:has_capability(name)
	return self.client:has_capability(name)
end

---@param reason? string
---@param force? boolean
function Workspace:stop(reason, force)
	self.epoch = self.epoch + 1
	self.phase = "stopped"
	self.client:stop(reason, force)
end

---@param result table
---@param expected_revision integer
---@return DweWorkspaceSnapshot|false|nil
function Workspace:_root_snapshot(result, expected_revision)
	return reconcile.root_snapshot(self, result, expected_revision)
end

---@param snapshot DweWorkspaceSnapshot
---@param id DweNodeId
---@param captured DweWorkspaceCapture
---@param callback fun(problem?: DweProblem, children?: DweNodeId[], invalidated?: boolean)
function Workspace:_snapshot_children(snapshot, id, captured, callback)
	return reconcile.snapshot_children(self, snapshot, id, captured, callback)
end

---@param snapshot DweWorkspaceSnapshot
---@param captured DweWorkspaceCapture
---@param callback fun(problem?: DweProblem, snapshot?: DweWorkspaceSnapshot, invalidated?: boolean)
function Workspace:_restore_snapshot(snapshot, captured, callback)
	return reconcile.restore_snapshot(self, snapshot, captured, callback)
end

---@param problem? DweProblem
function Workspace:_finish_reconcile(problem)
	return reconcile.finish_reconcile(self, problem)
end

function Workspace:_restart_reconcile()
	return reconcile.restart_reconcile(self)
end

---@param callback? DweWorkspaceCallback
---@param retry? boolean
function Workspace:_reconcile(callback, retry)
	return reconcile.reconcile(self, callback, retry)
end

function Workspace:_invalidate()
	return reconcile.invalidate(self)
end

---@param method string
---@param parameters table
function Workspace:_notification(method, parameters)
	return reconcile.notification(self, method, parameters)
end

function Workspace:defer_reconciliation()
	return reconcile.defer(self)
end

---@param revision? integer
function Workspace:resume_reconciliation(revision)
	return reconcile.resume(self, revision)
end

---@param id DweNodeId
---@param callback? DweWorkspaceCallback
---@param retried? boolean
function Workspace:expand(id, callback, retried)
	return expansion.expand(self, id, callback, retried)
end

---@param id DweNodeId
function Workspace:collapse(id)
	return expansion.collapse(self, id)
end

---@param callback? DweWorkspaceCallback
function Workspace:expand_all(callback)
	return expansion.expand_all(self, callback)
end

function Workspace:collapse_all()
	return expansion.collapse_all(self)
end

---@param id DweNodeId
---@param kinds table<string, boolean>
---@param callback? fun(problem?: DweProblem, path?: string)
function Workspace:_resolve_file(id, kinds, callback)
	return files.resolve(self, id, kinds, callback)
end

---@param id DweNodeId
---@param callback? fun(problem?: DweProblem, path?: string)
function Workspace:resolve_file(id, callback)
	return files.resolve_file(self, id, callback)
end

---@param id DweNodeId
---@param callback? fun(problem?: DweProblem, path?: string)
function Workspace:resolve_project(id, callback)
	return files.resolve_project(self, id, callback)
end

---@param callback? DweWorkspaceCallback
---@param retried? boolean
function Workspace:refresh(callback, retried)
	return refresh.refresh(self, callback, retried)
end

---@param revision integer
function Workspace:mutation_completed(revision)
	return refresh.mutation_completed(self, revision)
end

M.Workspace = Workspace

return M
