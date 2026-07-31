local rpc = require("dotnet-workspace-explorer.rpc")

local M = {}
local Workspace = {}
Workspace.__index = Workspace
local noop = function() end

local function stale()
	return rpc.problem("stale_tree", "The workspace tree changed while the request was running.")
end

local function is_absolute(path)
	local absolute = vim.fs.abspath(path)
	return absolute == path or vim.fs.normalize(absolute) == vim.fs.normalize(path)
end

local function valid_file_resolution(result, id, revision)
	if
		type(result) ~= "table"
		or result.revision ~= revision
		or result.targetNodeId ~= id
		or type(result.path) ~= "string"
		or result.path == ""
		or not is_absolute(result.path)
	then
		return false
	end
	local keys = { path = true, revision = true, targetNodeId = true }
	local count = 0
	for key in pairs(result) do
		if not keys[key] then
			return false
		end
		count = count + 1
	end
	return count == 3
end

local function normalize_node(value, workspace_id, revision, parent_id)
	if
		type(value) ~= "table"
		or value.workspaceId ~= workspace_id
		or value.revision ~= revision
		or type(value.id) ~= "string"
		or value.id == ""
		or type(value.kind) ~= "string"
		or type(value.name) ~= "string"
		or type(value.loadState) ~= "string"
		or type(value.capabilities) ~= "table"
		or not vim.islist(value.capabilities)
	then
		return nil
	end
	local capabilities, unique = {}, {}
	for index, capability in ipairs(value.capabilities) do
		if type(capability) ~= "string" or capability == "" or unique[capability] then
			return nil
		end
		capabilities[index], unique[capability] = capability, true
	end
	return {
		id = value.id,
		parent_id = parent_id,
		kind = value.kind,
		name = value.name,
		load_state = value.loadState,
		capabilities = capabilities,
		revision = revision,
	}
end

local function expandable(node)
	return node
		and (
			node.kind == "workspace"
			or node.kind == "solutionFolder"
			or node.kind == "project"
			or node.kind == "projectFolder"
			or node.kind == "dependencyContainer"
			or node.kind == "dependency"
		)
end

function Workspace.new(options)
	local self = setmetatable({
		nodes = {},
		children = {},
		loading = {},
		roots = {},
		expanded = {},
		epoch = 0,
		phase = "idle",
		reconcile_waiters = {},
		on_change = options.on_change or noop,
		on_error = options.on_error or noop,
		on_notification = options.on_notification or noop,
	}, Workspace)
	self.client = rpc.Client.new({
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
	})
	return self
end

function Workspace:_valid(captured_generation, captured_epoch, captured_workspace)
	return self.client.generation == captured_generation
		and not self.client.inert
		and self.epoch == captured_epoch
		and self.workspace_id == captured_workspace
end

function Workspace:_normalize_nodes(values, parent_id, revision, existing)
	local nodes, ids, unique = {}, {}, {}
	for index, value in ipairs(values) do
		local node = normalize_node(value, self.workspace_id, revision, parent_id)
		if not node or unique[node.id] or existing[node.id] then
			return nil
		end
		nodes[index], ids[index], unique[node.id] = node, node.id, true
	end
	return nodes, ids
end

function Workspace:_root_snapshot(result, expected_revision)
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

function Workspace:_snapshot_children(snapshot, id, captured, callback)
	local collected, token, seen_tokens = {}, nil, {}
	local function page()
		local parameters = { parentNodeId = id, pageSize = self.client.limits.maxPageSize }
		if token then
			parameters.continuationToken = token
		end
		self.client:request("workspace/children", parameters, function(request_error, result)
			if not self:_valid(captured.generation, captured.epoch, captured.workspace) then
				return callback(stale(), nil, true)
			end
			if request_error then
				if request_error.code == "workspace_conflict" then
					self:_invalidate()
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
				self:_invalidate()
				return callback(stale(), nil, true)
			end
			for _, child in ipairs(result.nodes) do
				collected[#collected + 1] = child
			end
			token = result.nextToken
			if token ~= nil then
				if type(token) ~= "string" or token == "" or seen_tokens[token] then
					local reason = rpc.problem("invalid_tree", "The children continuation is invalid.")
					self.client:_terminate(reason)
					return callback(reason)
				end
				seen_tokens[token] = true
				return page()
			end
			local nodes, ids = self:_normalize_nodes(collected, id, snapshot.revision, snapshot.nodes)
			if not nodes then
				local reason = rpc.problem("invalid_tree", "The workspace children response is invalid.")
				self.client:_terminate(reason)
				return callback(reason)
			end
			for _, node in ipairs(nodes) do
				snapshot.nodes[node.id] = node
			end
			snapshot.children[id] = ids
			callback(nil, ids)
		end)
	end
	page()
end

function Workspace:_restore_snapshot(snapshot, captured, callback)
	local pending, position = {}, 1
	for _, id in ipairs(snapshot.roots) do
		if snapshot.desired_expanded[id] and expandable(snapshot.nodes[id]) then
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
				if snapshot.desired_expanded[child_id] and expandable(snapshot.nodes[child_id]) then
					pending[#pending + 1] = child_id
				end
			end
			restore_next()
		end)
	end
	restore_next()
end

function Workspace:_finish_reconcile(err)
	local waiters = self.reconcile_waiters
	self.reconcile_waiters = {}
	for _, waiter in ipairs(waiters) do
		waiter(err, err and nil or self)
	end
end

function Workspace:_restart_reconcile()
	self.reconciling = false
	if self.reconcile_queued and not self.client.inert then
		self:_reconcile()
	end
end

function Workspace:_reconcile(callback, retry)
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
			local reason = rpc.problem("invalid_tree", "The workspace root response is incompatible.")
			self.client:_terminate(reason)
			return self:_finish_reconcile(reason)
		end
		self:_restore_snapshot(snapshot, captured, function(restore_error, restored, invalidated)
			if invalidated then
				return self:_restart_reconcile()
			end
			self.reconciling = false
			if restore_error then
				self.phase = "failed"
				if not self.client.inert then
					self.on_error(restore_error)
				end
				return self:_finish_reconcile(restore_error)
			end
			self.nodes, self.children, self.roots, self.expanded =
				restored.nodes, restored.children, restored.roots, restored.expanded
			self.revision, self.selected_id = restored.revision, restored.selected_id
			self.phase = "ready"
			self.on_change(self)
			self:_finish_reconcile()
		end)
	end)
end

function Workspace:_invalidate()
	self.epoch, self.reconcile_queued = self.epoch + 1, true
	if not self.reconciling then
		self:_reconcile()
	end
end

function Workspace:_notification(method, parameters)
	if method == "workspace/delta" or method == "workspace/reset" then
		self:_invalidate()
	else
		self.on_notification(method, parameters)
	end
end

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
		self.workspace_id, self.revision = result.workspace.id, result.workspace.revision
		self:_reconcile(callback)
	end)
end

function Workspace:expand(id, callback, retried)
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
	local collected, token, seen_tokens = {}, nil, {}
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
				return finish(stale())
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
				or result.revision ~= expected_revision
				or result.parentNodeId ~= id
				or type(result.nodes) ~= "table"
				or not vim.islist(result.nodes)
			then
				self:_invalidate()
				if not retried then
					return retry_after_reconcile()
				end
				restore_expansion()
				return finish(stale())
			end
			for _, child in ipairs(result.nodes) do
				collected[#collected + 1] = child
			end
			token = result.nextToken
			if token ~= nil then
				if type(token) ~= "string" or token == "" or seen_tokens[token] then
					local reason = rpc.problem("invalid_tree", "The children continuation is invalid.")
					restore_expansion()
					finish(reason)
					return self.client:_terminate(reason)
				end
				seen_tokens[token] = true
				return page()
			end
			local nodes, ids = self:_normalize_nodes(collected, id, expected_revision, self.nodes)
			if not nodes then
				local reason = rpc.problem("invalid_tree", "The workspace children response is invalid.")
				restore_expansion()
				finish(reason)
				return self.client:_terminate(reason)
			end
			for _, node in ipairs(nodes) do
				self.nodes[node.id] = node
			end
			self.children[id] = ids
			self.on_change(self)
			finish(nil, ids)
		end)
	end
	page()
end

function Workspace:collapse(id)
	self.expanded[id] = nil
	self.on_change(self)
end

function Workspace:select(id)
	if self.nodes[id] then
		self.selected_id = id
	end
end

function Workspace:get_node(id)
	return self.nodes[id]
end

function Workspace:parent(id)
	local node = self.nodes[id]
	return node and node.parent_id or nil
end

function Workspace:children_of(id)
	return self.children[id]
end

function Workspace:is_expandable(id)
	return expandable(self.nodes[id])
end

function Workspace:is_terminal()
	return self.client.inert or self.client.state == "failed"
end

function Workspace:request(method, parameters, callback)
	return self.client:request(method, parameters, callback)
end

function Workspace:has_capability(name)
	return self.client:has_capability(name)
end

function Workspace:resolve_file(id, callback)
	callback = callback or noop
	local node = self.nodes[id]
	if not node or (node.kind ~= "projectFile" and node.kind ~= "solutionItem") then
		return callback(rpc.problem("not_openable", "The selected node is not an openable file."))
	end
	local generation, epoch, workspace_id = self.client.generation, self.epoch, self.workspace_id
	local revision = self.revision
	self.client:request(
		"workspace/file/resolve",
		{ targetNodeId = id, expectedRevision = revision },
		function(err, result)
			if not self:_valid(generation, epoch, workspace_id) then
				return callback(stale())
			end
			if err then
				if err.code == "workspace_conflict" then
					self:_invalidate()
				end
				return callback(err)
			end
			if not valid_file_resolution(result, id, revision) then
				return self.client:_terminate(
					rpc.problem("invalid_file_resolution", "The workspace file response is incompatible.")
				)
			end
			callback(nil, result.path)
		end
	)
end

function Workspace:refresh(callback)
	callback = callback or noop
	local generation, epoch, workspace_id = self.client.generation, self.epoch, self.workspace_id
	local expected_revision = self.revision
	self.client:request(
		"workspace/refresh",
		{ expectedRevision = expected_revision },
		function(err, result)
			if not self:_valid(generation, epoch, workspace_id) then
				return callback(stale())
			end
			if err then
				if err.code == "workspace_conflict" then
					self:_invalidate()
				end
				return callback(err)
			end
			if
				type(result) ~= "table"
				or type(result.revision) ~= "number"
				or result.revision < expected_revision
				or type(result.reset) ~= "boolean"
			then
				self:_invalidate()
				return callback(stale())
			end
			self:_invalidate()
			callback(nil, result)
		end
	)
end

function Workspace:mutation_completed(revision)
	local generation, workspace_id = self.client.generation, self.workspace_id
	vim.schedule(function()
		if
			self.client.generation == generation
			and not self.client.inert
			and self.workspace_id == workspace_id
			and self.revision < revision
			and not self.reconciling
		then
			self:_invalidate()
		end
	end)
end

function Workspace:stop(reason, force)
	self.epoch, self.phase = self.epoch + 1, "stopped"
	self.client:stop(reason, force)
end

M.Workspace = Workspace

return M
