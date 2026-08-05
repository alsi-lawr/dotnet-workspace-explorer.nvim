local errors = require("dotnet-workspace-explorer.workspace.errors")
local node_model = require("dotnet-workspace-explorer.workspace.node")
local rpc = require("dotnet-workspace-explorer.rpc")
local value = require("dotnet-workspace-explorer.protocol.value")

local M = {}
local noop = function() end

---Expands one node, loading all child pages if necessary.
---@param self table
---@param id DweNodeId
---@param callback? fun(error: DweProblem?, ids?: DweNodeId[])
---@param retried? boolean
function M.expand(self, id, callback, retried)
	callback = callback or noop
	if not self.nodes[id] then
		return callback(rpc.problem("unknown_node", "The node no longer exists."))
	end
	local previous_expanded = self.expanded[id]
	self.expanded[id] = true
	if self.children[id] then
		self.on_change(self)
		return callback(nil, self.children[id])
	end
	if self.loading[id] then
		self.loading[id][#self.loading[id] + 1] = callback
		return
	end

	local waiters = { callback }
	self.loading[id] = waiters
	local function deliver(err, result)
		for _, waiter in ipairs(waiters) do
			waiter(err, result)
		end
	end
	local function restore_expansion()
		if self.expanded[id] then
			self.expanded[id] = previous_expanded
		end
	end
	local function finish(err, result)
		if self.loading[id] == waiters then
			self.loading[id] = nil
		end
		deliver(err, result)
	end
	local function retry_after_reconcile()
		local function resume(err)
			if err then
				restore_expansion()
				return finish(err)
			end
			if not self.nodes[id] then
				restore_expansion()
				return finish(rpc.problem("unknown_node", "The node no longer exists."))
			end
			if not self.expanded[id] or self.children[id] then
				return finish(nil, self.children[id])
			end
			if self.loading[id] == waiters then
				self.loading[id] = nil
			end
			self:expand(id, function(retry_error, result)
				if retry_error then
					restore_expansion()
				end
				deliver(retry_error, result)
			end, true)
		end
		if self.reconciling or self.reconcile_queued then
			self.reconcile_waiters[#self.reconcile_waiters + 1] = resume
		else
			resume()
		end
	end

	local captured_generation, captured_epoch = self.client.generation, self.epoch
	local captured_workspace, expected_revision = self.workspace_id, self.revision
	local collected, token, seen_tokens, response_revision = {}, nil, {}, nil
	local awaiting_delta = false
	local function page()
		local parameters = { parentNodeId = id, pageSize = self.client.limits.maxPageSize }
		if token then
			parameters.continuationToken = token
		end
		self.client:request("workspace/children", parameters, function(request_error, result)
			if not self:_valid(captured_generation, captured_epoch, captured_workspace) then
				if
					not retried
					and self.client.generation == captured_generation
					and not self.client.inert
					and self.workspace_id == captured_workspace
					and self.nodes[id]
					and self.expanded[id]
				then
					return retry_after_reconcile()
				end
				return finish(errors.stale())
			end
			if request_error then
				if request_error.code == "workspace_conflict" and not retried then
					self:_invalidate()
					return retry_after_reconcile()
				end
				restore_expansion()
				if request_error.code == "workspace_conflict" then
					self:_invalidate()
				end
				return finish(request_error)
			end
			if
				type(result) ~= "table"
				or not value.is_integer(result.revision)
				or result.revision < expected_revision
				or response_revision and result.revision ~= response_revision
				or result.parentNodeId ~= id
				or type(result.nodes) ~= "table"
				or not vim.islist(result.nodes)
			then
				self:_invalidate()
				if not retried then
					return retry_after_reconcile()
				end
				restore_expansion()
				return finish(errors.stale())
			end
			response_revision = response_revision or result.revision
			if response_revision > self.revision then
				self.reflected_base_revision = self.revision
				self.revision = response_revision
				awaiting_delta = true
			end
			for _, child in ipairs(result.nodes) do
				collected[#collected + 1] = child
			end
			token = result.nextToken
			if token ~= nil then
				if type(token) ~= "string" or token == "" or seen_tokens[token] then
					local reason =
						rpc.problem("invalid_tree", "The children continuation is invalid.")
					restore_expansion()
					finish(reason)
					return self.client:_terminate(reason)
				end
				seen_tokens[token] = true
				return page()
			end
			local nodes, ids = self:_normalize_nodes(collected, id, response_revision, self.nodes)
			if not nodes then
				local reason =
					rpc.problem("invalid_tree", "The workspace children response is invalid.")
				restore_expansion()
				finish(reason)
				return self.client:_terminate(reason)
			end
			for _, child in ipairs(nodes) do
				self.nodes[child.id] = child
			end
			self.children[id] = ids
			if not awaiting_delta then
				self.on_change(self)
			end
			finish(nil, ids)
		end)
	end
	page()
end

---@param self table
---@param id DweNodeId
function M.collapse(self, id)
	self.expanded[id] = nil
	self.on_change(self)
end

---Builds a fully expanded tree from a consistent root revision.
---@param self table
---@param callback? DweWorkspaceCallback
function M.expand_all(self, callback)
	callback = callback or noop
	if self.phase ~= "ready" then
		return callback(rpc.problem("not_ready", "The workspace tree is not ready."))
	end
	local captured = {
		generation = self.client.generation,
		epoch = self.epoch,
		workspace = self.workspace_id,
	}
	local expected_revision = self.revision
	local function retry_after_reconcile()
		if
			self.client.generation ~= captured.generation
			or self.client.inert
			or self.workspace_id ~= captured.workspace
		then
			return callback(errors.stale())
		end
		local function resume(err)
			if err then
				return callback(err)
			end
			if self.revision <= expected_revision then
				return callback(errors.stale())
			end
			self:expand_all(callback)
		end
		if self.reconciling or self.reconcile_queued then
			self.reconcile_waiters[#self.reconcile_waiters + 1] = resume
		else
			resume()
		end
	end

	self.client:request("workspace/root", {}, function(request_error, result)
		if not self:_valid(captured.generation, captured.epoch, captured.workspace) then
			return callback(errors.stale())
		end
		if request_error then
			return callback(request_error)
		end
		if type(result) ~= "table" or result.revision ~= expected_revision then
			self:_invalidate()
			return retry_after_reconcile()
		end
		local snapshot = self:_root_snapshot(result, expected_revision)
		if not snapshot or snapshot.revision ~= expected_revision then
			return callback(errors.stale())
		end
		snapshot.desired_expanded, snapshot.previous_nodes = nil, nil
		local pending, position = vim.deepcopy(snapshot.roots), 1
		local function next_node()
			local id = pending[position]
			position = position + 1
			if not id then
				local selected = self.selected_id
				while selected and not snapshot.nodes[selected] do
					local previous = self.nodes[selected]
					selected = previous and previous.parent_id or nil
				end
				snapshot.selected_id = selected or snapshot.roots[1]
				self.nodes, self.children, self.roots, self.expanded =
					snapshot.nodes, snapshot.children, snapshot.roots, snapshot.expanded
				self.selected_id = snapshot.selected_id
				self.on_change(self)
				return callback(nil, self)
			end
			if not node_model.is_expandable(snapshot.nodes[id]) then
				return next_node()
			end
			snapshot.expanded[id] = true
			self:_snapshot_children(snapshot, id, captured, function(err, ids, invalidated)
				if err then
					if invalidated then
						return retry_after_reconcile()
					end
					return callback(err)
				end
				for _, child_id in ipairs(ids) do
					if node_model.is_expandable(snapshot.nodes[child_id]) then
						pending[#pending + 1] = child_id
					end
				end
				next_node()
			end)
		end
		next_node()
	end)
end

---@param self table
function M.collapse_all(self)
	self.expanded = {}
	self.on_change(self)
end

return M
