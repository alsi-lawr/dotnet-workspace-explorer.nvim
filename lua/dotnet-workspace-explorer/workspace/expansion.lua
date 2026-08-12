local errors = require("dotnet-workspace-explorer.workspace.errors")
local node_model = require("dotnet-workspace-explorer.workspace.node")
local rpc = require("dotnet-workspace-explorer.rpc")
local staging = require("dotnet-workspace-explorer.workspace.staging")
local value = require("dotnet-workspace-explorer.protocol.value")

local M = {}
local noop = function() end

---Expands one node, loading all child pages if necessary.
---@param self table
---@param id DweNodeId
---@param callback? fun(error: DweProblem?, ids?: DweNodeId[])
function M.expand(self, id, callback)
	callback = callback or noop
	if self.expansion_owner or self.discarding_stages or self.preempting_owner then
		return callback(errors.stale())
	end
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

	local stage = staging.create(self, id, previous_expanded, callback)
	self.on_change(self)
	local function page()
		if not staging.is_current(self, stage) then
			return
		end
		local parameters = { parentNodeId = id, pageSize = self.client.limits.maxPageSize }
		if stage.next_token then
			parameters.continuationToken = stage.next_token
		end
		self.client:request("workspace/children", parameters, function(request_error, result)
			if not staging.is_current(self, stage) then
				return staging.discard(self, stage, errors.stale())
			end
			if request_error then
				staging.discard(self, stage, request_error)
				if request_error.code == "workspace_conflict" then
					self:_invalidate()
				end
				return
			end
			if
				type(result) ~= "table"
				or not value.is_integer(result.revision)
				or result.revision < stage.base_revision
				or stage.page_revision and result.revision ~= stage.page_revision
				or result.parentNodeId ~= id
				or type(result.nodes) ~= "table"
				or not vim.islist(result.nodes)
			then
				self:_invalidate()
				return
			end

			local existing = {}
			for node_id, node in pairs(self.nodes) do
				existing[node_id] = node
			end
			for node_id, node in pairs(stage.nodes) do
				existing[node_id] = node
			end
			for _, other_stage in pairs(self.stages) do
				if other_stage ~= stage then
					for node_id, node in pairs(other_stage.nodes) do
						existing[node_id] = node
					end
				end
			end
			local nodes, ids = self:_normalize_nodes(result.nodes, id, result.revision, existing)
			if not nodes then
				local reason =
					rpc.problem("invalid_tree", "The workspace children response is invalid.")
				staging.discard(self, stage, reason)
				return self.client:_terminate(reason)
			end
			local next_token = result.nextToken
			if
				next_token ~= nil
				and (
					type(next_token) ~= "string"
					or next_token == ""
					or stage.seen_tokens[next_token]
				)
			then
				local reason = rpc.problem("invalid_tree", "The children continuation is invalid.")
				staging.discard(self, stage, reason)
				return self.client:_terminate(reason)
			end

			stage.page_revision = stage.page_revision or result.revision
			if stage.page_revision < self.revision then
				return self:_invalidate()
			elseif stage.page_revision > self.revision then
				if self.reflected_base_revision ~= nil then
					return self:_invalidate()
				end
				self.reflected_base_revision = self.revision
				self.revision = stage.page_revision
				stage.awaiting_delta = true
			elseif self.reflected_base_revision ~= nil then
				stage.awaiting_delta = true
			end
			for index, child in ipairs(nodes) do
				stage.nodes[child.id] = child
				stage.ids[#stage.ids + 1] = ids[index]
			end
			stage.next_token = next_token
			if next_token ~= nil then
				stage.seen_tokens[next_token] = true
			end
			self.on_change(self)
			if not staging.is_current(self, stage) then
				return
			end
			if next_token ~= nil then
				return page()
			end
			stage.complete = true
			if not stage.awaiting_delta and not staging.promote(self, stage) then
				self:_invalidate()
			end
		end)
	end
	page()
end

---@param self table
---@param id DweNodeId
function M.collapse(self, id)
	local stage = staging.get(self, id)
	if stage then
		staging.discard(self, stage, errors.stale(), false)
	end
	self.expanded[id] = nil
	self.on_change(self)
end

---Builds a fully expanded tree from a consistent root revision.
---@param self table
---@param callback? DweWorkspaceCallback
function M.expand_all(self, callback)
	callback = callback or noop
	if self.phase ~= "ready" or self.discarding_stages or self.preempting_owner then
		return callback(rpc.problem("not_ready", "The workspace tree is not ready."))
	end
	local owner = staging.claim_owner(self)
	local settled = false
	local function finish(problem, result)
		if settled then
			return
		end
		settled = true
		local had_overlay = owner.overlay ~= nil
		staging.release_owner(self, owner)
		owner.overlay = nil
		if had_overlay and not result then
			self.on_change(self)
		end
		callback(problem, result)
	end
	local function owns_snapshot()
		return staging.owns(self, owner)
	end
	owner.cancel = function(problem)
		finish(problem or errors.stale())
	end
	local captured = {
		generation = self.client.generation,
		epoch = self.epoch,
		workspace = self.workspace_id,
		owner = owner,
	}
	captured.on_page = function(snapshot)
		if
			owns_snapshot()
			and self:_valid(captured.generation, captured.epoch, captured.workspace)
			and owner.overlay == snapshot
		then
			self.on_change(self)
		end
	end
	local expected_revision = self.revision
	local retrying = false
	local function retry_after_reconcile()
		if settled or retrying then
			return
		end
		retrying = true
		if
			self.client.generation ~= captured.generation
			or self.client.inert
			or self.workspace_id ~= captured.workspace
			or not owns_snapshot()
		then
			return finish(errors.stale())
		end
		local function resume(err)
			if settled then
				return
			end
			if err then
				return finish(err)
			end
			if self.revision <= expected_revision or not owns_snapshot() then
				return finish(errors.stale())
			end
			staging.release_owner(self, owner)
			self:expand_all(function(problem, result)
				finish(problem, result)
			end)
		end
		if self.reconciling or self.reconcile_queued then
			self.reconcile_waiters[#self.reconcile_waiters + 1] = resume
		else
			resume()
		end
	end
	owner.retry = retry_after_reconcile

	self.client:request("workspace/root", {}, function(request_error, result)
		if settled then
			return
		end
		if not owns_snapshot() then
			if retrying then
				return
			end
			return finish(errors.stale())
		end
		if
			self.client.generation ~= captured.generation
			or self.client.inert
			or self.workspace_id ~= captured.workspace
		then
			return finish(errors.stale())
		end
		if self.epoch ~= captured.epoch then
			return retry_after_reconcile()
		end
		if request_error then
			return finish(request_error)
		end
		if type(result) ~= "table" or result.revision ~= expected_revision then
			self:_invalidate(owner)
			return retry_after_reconcile()
		end
		local snapshot = self:_root_snapshot(result, expected_revision)
		if not snapshot or snapshot.revision ~= expected_revision then
			return finish(errors.stale())
		end
		snapshot.desired_expanded, snapshot.previous_nodes = nil, nil
		owner.overlay = snapshot
		self.on_change(self)
		local pending, position = vim.deepcopy(snapshot.roots), 1
		local function next_node()
			if not owns_snapshot() then
				return finish(errors.stale())
			end
			local id = pending[position]
			position = position + 1
			if not id then
				local selected = self.selected_id
				while selected and not snapshot.nodes[selected] do
					local previous = self.nodes[selected]
					selected = previous and previous.parent_id or nil
				end
				snapshot.selected_id = selected or snapshot.roots[1]
				if
					not owns_snapshot()
					or not self:_valid(captured.generation, captured.epoch, captured.workspace)
				then
					return finish(errors.stale())
				end
				self.nodes, self.children, self.roots, self.expanded =
					snapshot.nodes, snapshot.children, snapshot.roots, snapshot.expanded
				self.revision, self.selected_id = snapshot.revision, snapshot.selected_id
				staging.release_owner(self, owner)
				owner.overlay = nil
				self.on_change(self)
				return finish(nil, self)
			end
			if not node_model.is_expandable(snapshot.nodes[id]) then
				return next_node()
			end
			snapshot.expanded[id] = true
			self:_snapshot_children(snapshot, id, captured, function(err, ids, invalidated)
				if settled or retrying then
					return
				end
				if not owns_snapshot() then
					return finish(errors.stale())
				end
				if err then
					if invalidated then
						owner.overlay = nil
						self.on_change(self)
						return retry_after_reconcile()
					end
					return finish(err)
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
	staging.discard_all(self, errors.stale(), false)
	staging.preempt_owner(self, errors.stale())
	self.expanded = {}
	self.on_change(self)
end

return M
