local rpc = require("dotnet-workspace-explorer.rpc")

local M = {}
local Workspace = {}
Workspace.__index = Workspace
local noop = function() end

local function stale()
	return rpc.problem("stale_tree", "The workspace tree changed while the request was running.")
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

function Workspace.new(options)
	local self = setmetatable({
		nodes = {},
		children = {},
		loading = {},
		roots = {},
		expanded = {},
		epoch = 0,
		phase = "idle",
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

function Workspace:_apply_root(result, expected_revision)
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
		return false
	end
	local previous_expanded, previous_selected = self.expanded, self.selected_id
	self.nodes, self.children, self.roots, self.expanded = {}, {}, roots, {}
	for _, node in ipairs(nodes) do
		self.nodes[node.id] = node
		if previous_expanded[node.id] then
			self.expanded[node.id] = true
		end
	end
	self.revision = result.revision
	self.selected_id = self.nodes[previous_selected] and previous_selected or roots[1]
	return true
end

function Workspace:_reconcile(callback, retry)
	if self.reconciling then
		self.reconcile_queued = true
		return
	end
	self.reconciling, self.reconcile_queued = true, false
	local captured_generation, captured_epoch = self.client.generation, self.epoch
	local captured_workspace, expected_revision = self.workspace_id, self.revision
	self.client:request("workspace/root", {}, function(request_error, result)
		if not self:_valid(captured_generation, captured_epoch, captured_workspace) then
			self.reconciling = false
			if self.reconcile_queued and not self.client.inert then
				self:_reconcile()
			end
			return
		end
		self.reconciling = false
		if request_error then
			self.phase = "failed"
			self.on_error(request_error)
			if callback then
				callback(request_error)
			end
			return
		end
		if not self:_apply_root(result, expected_revision) then
			if not retry then
				self.epoch = self.epoch + 1
				return self:_reconcile(callback, true)
			end
			return self.client:_terminate(
				rpc.problem("invalid_tree", "The workspace root response is incompatible.")
			)
		end
		self.phase = "ready"
		self.on_change(self)
		if callback then
			callback(nil, self)
		end
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

function Workspace:expand(id, callback)
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
	local function restore_expansion()
		if self.expanded[id] then
			self.expanded[id] = previous_expanded
		end
	end
	local function finish(err, result)
		if self.loading[id] == waiters then
			self.loading[id] = nil
		end
		for _, waiter in ipairs(waiters) do
			waiter(err, result)
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
				return finish(stale())
			end
			if request_error then
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
				restore_expansion()
				self:_invalidate()
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
	local node = self.nodes[id]
	return node
		and (
			node.kind == "workspace"
			or node.kind == "solutionFolder"
			or node.kind == "project"
			or node.kind == "projectFolder"
			or node.kind == "dependencyContainer"
		)
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
