local errors = require("dotnet-workspace-explorer.workspace.errors")
local node_model = require("dotnet-workspace-explorer.workspace.node")
local rpc = require("dotnet-workspace-explorer.rpc")
local staging = require("dotnet-workspace-explorer.workspace.staging")

local M = {}

---Builds an isolated root snapshot from a `workspace/root` response.
---@param self table
---@param result unknown
---@param expected_revision integer
---@return table|false|nil
function M.root_snapshot(self, result, expected_revision)
	if
		type(result) ~= "table"
		or type(result.revision) ~= "number"
		or result.revision % 1 ~= 0
		or result.revision < expected_revision
		or type(result.nodes) ~= "table"
		or not vim.islist(result.nodes)
	then
		return false
	end
	local nodes, roots = self:_normalize_nodes(result.nodes, nil, result.revision, {})
	if not nodes then
		return nil
	end
	local snapshot = {
		nodes = {},
		children = {},
		roots = roots,
		expanded = {},
		desired_expanded = self.expanded,
		previous_nodes = self.nodes,
		revision = result.revision,
		selected_id = self.selected_id,
	}
	for _, node in ipairs(nodes) do
		snapshot.nodes[node.id] = node
	end
	return snapshot
end

---Loads every page of one node's children into a detached snapshot.
---@param self table
---@param snapshot table
---@param id DweNodeId
---@param captured DweWorkspaceCapture
---@param callback fun(error: DweProblem?, ids?: DweNodeId[], invalidated?: boolean)
function M.snapshot_children(self, snapshot, id, captured, callback)
	local collected, token, seen_tokens = {}, nil, {}
	local function owner_is_current()
		return captured.owner == nil or self.expansion_owner == captured.owner
	end
	local function page()
		if not owner_is_current() then
			return
		end
		local parameters = { parentNodeId = id, pageSize = self.client.limits.maxPageSize }
		if token then
			parameters.continuationToken = token
		end
		self.client:request("workspace/children", parameters, function(request_error, result)
			if not owner_is_current() then
				return
			end
			if not self:_valid(captured.generation, captured.epoch, captured.workspace) then
				return callback(errors.stale(), nil, true)
			end
			if request_error then
				if request_error.code == "workspace_conflict" then
					if not owner_is_current() then
						return
					end
					self:_invalidate(captured.owner)
					return callback(request_error, nil, true)
				end
				return callback(request_error)
			end
			if
				type(result) ~= "table"
				or result.revision ~= snapshot.revision
				or result.parentNodeId ~= id
				or type(result.nodes) ~= "table"
				or not vim.islist(result.nodes)
			then
				if not owner_is_current() then
					return
				end
				self:_invalidate(captured.owner)
				return callback(errors.stale(), nil, true)
			end
			for _, child in ipairs(result.nodes) do
				collected[#collected + 1] = child
			end
			token = result.nextToken
			if token ~= nil then
				if type(token) ~= "string" or token == "" or seen_tokens[token] then
					local reason =
						rpc.problem("invalid_tree", "The children continuation is invalid.")
					self.client:_terminate(reason)
					return callback(reason)
				end
				seen_tokens[token] = true
				return page()
			end
			local nodes, ids =
				self:_normalize_nodes(collected, id, snapshot.revision, snapshot.nodes)
			if not nodes then
				local reason =
					rpc.problem("invalid_tree", "The workspace children response is invalid.")
				self.client:_terminate(reason)
				return callback(reason)
			end
			for _, child in ipairs(nodes) do
				snapshot.nodes[child.id] = child
			end
			snapshot.children[id] = ids
			callback(nil, ids)
		end)
	end
	page()
end

---Reloads the previously expanded portion of a detached snapshot.
---@param self table
---@param snapshot table
---@param captured { generation: integer, epoch: integer, workspace: string }
---@param callback fun(error: DweProblem?, snapshot?: table, invalidated?: boolean)
function M.restore_snapshot(self, snapshot, captured, callback)
	local pending, position = {}, 1
	for _, id in ipairs(snapshot.roots) do
		if snapshot.desired_expanded[id] and node_model.is_expandable(snapshot.nodes[id]) then
			pending[#pending + 1] = id
		end
	end
	local function complete()
		local selected = snapshot.selected_id
		while selected and not snapshot.nodes[selected] do
			local previous = snapshot.previous_nodes[selected]
			selected = previous and previous.parent_id or nil
		end
		snapshot.selected_id = selected or snapshot.roots[1]
		snapshot.desired_expanded, snapshot.previous_nodes = nil, nil
		callback(nil, snapshot)
	end
	local function restore_next()
		local id = pending[position]
		position = position + 1
		if not id then
			return complete()
		end
		snapshot.expanded[id] = true
		self:_snapshot_children(snapshot, id, captured, function(err, ids, invalidated)
			if err then
				return callback(err, nil, invalidated)
			end
			for _, child_id in ipairs(ids) do
				if
					snapshot.desired_expanded[child_id]
					and node_model.is_expandable(snapshot.nodes[child_id])
				then
					pending[#pending + 1] = child_id
				end
			end
			restore_next()
		end)
	end
	restore_next()
end

---@param self table
---@param err? DweProblem
function M.finish_reconcile(self, err)
	local waiters = self.reconcile_waiters
	self.reconcile_waiters = {}
	for _, waiter in ipairs(waiters) do
		waiter(err, err and nil or self)
	end
end

---@param self table
function M.restart_reconcile(self)
	self.reconciling = false
	if self.reconcile_queued and not self.reconciliation_deferred and not self.client.inert then
		self:_reconcile()
	end
end

---Reconciles the in-memory tree against a consistent root snapshot.
---@param self table
---@param callback? DweWorkspaceCallback
---@param retry? boolean
function M.reconcile(self, callback, retry)
	if callback then
		self.reconcile_waiters[#self.reconcile_waiters + 1] = callback
	end
	if self.reconciling then
		return
	end
	self.reconciling, self.reconcile_queued = true, false
	local captured = {
		generation = self.client.generation,
		epoch = self.epoch,
		workspace = self.workspace_id,
		owner = self.expansion_owner,
	}
	local expected_revision = self.revision
	self.client:request("workspace/root", {}, function(request_error, result)
		if not self:_valid(captured.generation, captured.epoch, captured.workspace) then
			return self:_restart_reconcile()
		end
		if request_error then
			self.reconciling = false
			self.phase = "failed"
			self.on_error(request_error)
			self:_finish_reconcile(request_error)
			return
		end
		local snapshot = self:_root_snapshot(result, expected_revision)
		if not snapshot then
			self.reconciling = false
			if not retry then
				self.epoch = self.epoch + 1
				return self:_reconcile(nil, true)
			end
			local reason =
				rpc.problem("invalid_tree", "The workspace root response is incompatible.")
			self.client:_terminate(reason)
			return self:_finish_reconcile(reason)
		end
		self:_restore_snapshot(snapshot, captured, function(restore_error, restored, invalidated)
			if invalidated then
				return self:_restart_reconcile()
			end
			self.reconciling = false
			if restore_error then
				staging.discard_all(self, restore_error)
				staging.preempt_owner(self, restore_error)
				self.phase = "failed"
				if not self.client.inert then
					self.on_error(restore_error)
				end
				return self:_finish_reconcile(restore_error)
			end
			self.nodes, self.children, self.roots, self.expanded =
				restored.nodes, restored.children, restored.roots, restored.expanded
			self.revision, self.selected_id = restored.revision, restored.selected_id
			self.reflected_base_revision = nil
			self.phase = "ready"
			self.on_change(self)
			self:_finish_reconcile()
		end)
	end)
end

---Marks the current snapshot stale and schedules reconciliation.
---@param self table
---@param retained_owner? DweExpansionOwner
function M.invalidate(self, retained_owner)
	staging.discard_all(self, errors.stale())
	if self.expansion_owner ~= retained_owner then
		staging.preempt_owner(self, errors.stale())
	end
	self.reflected_base_revision = nil
	self.epoch, self.reconcile_queued = self.epoch + 1, true
	if not self.reconciling and not self.reconciliation_deferred then
		self:_reconcile()
	end
end

---@param self table
---@param method string
---@param parameters table
function M.notification(self, method, parameters)
	if method == "workspace/delta" then
		if self.reconciliation_deferred then
			staging.discard_all(self, errors.stale())
			staging.preempt_owner(self, errors.stale())
			self.deferred_reconciliation = true
			self.on_notification(method, parameters)
		elseif self.expansion_owner then
			self:_invalidate()
		elseif staging.has_active(self) then
			if
				staging.can_retain_reflected(self, parameters)
				and self._delta.apply(self, parameters, node_model.normalize)
				and staging.reflected_applied(self)
			then
				self.on_change(self)
			else
				self:_invalidate()
			end
		elseif self._delta.apply(self, parameters, node_model.normalize) then
			self.on_change(self)
		else
			self:_invalidate()
		end
	elseif method == "workspace/reset" then
		if self.reconciliation_deferred then
			staging.discard_all(self, errors.stale())
			staging.preempt_owner(self, errors.stale())
			self.deferred_reconciliation = true
			self.on_notification(method, parameters)
		else
			self:_invalidate()
		end
	else
		self.on_notification(method, parameters)
	end
end

---@param self table
function M.defer(self)
	self.reconciliation_deferred = true
	if self.reconciling then
		self.epoch, self.reconcile_queued = self.epoch + 1, true
	end
end

---@param self table
---@param revision? integer
function M.resume(self, revision)
	self.reconciliation_deferred = false
	local required = self.deferred_reconciliation
		or (type(revision) == "number" and self.revision < revision)
	self.deferred_reconciliation = false
	if required then
		self:_invalidate()
	elseif self.reconcile_queued and not self.reconciling then
		self:_reconcile()
	end
end

return M
