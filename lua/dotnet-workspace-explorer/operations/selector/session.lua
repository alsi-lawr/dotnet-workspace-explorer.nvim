local entries = require("dotnet-workspace-explorer.operations.selector.entries")
local protocol = require("dotnet-workspace-explorer.protocol.selector")
local rpc = require("dotnet-workspace-explorer.rpc")
local value = require("dotnet-workspace-explorer.protocol.value")

local M = {}

---@param message string
---@return DweProblem
local function incompatible(message)
	return rpc.problem("incompatible_selector", message)
end

---@param self table
---@param selector_id? string
---@param captured integer
function M.close_remote(self, selector_id, captured)
	if not selector_id or not self.workspace:has_capability("workspace.addExisting.selector") then
		return
	end
	self.closing_generation = captured
	self.workspace:request(
		"workspace/addExisting/close",
		{ selectorId = selector_id },
		function(err, result)
			if
				not self.valid
				or not self.is_live()
				or self.closing_generation ~= captured
				or self.generation ~= captured
			then
				return
			end
			if err then
				return
			end
			if not value.is_map(result) or result.closed ~= true then
				self.on_error(incompatible("The selector close response is incompatible."))
			end
		end
	)
end

---Leaves the selector, optionally closing server state and reporting a result.
---@param self table
---@param close boolean
---@param problem? DweProblem
---@param revision? integer
---@param resume? boolean
function M.exit(self, close, problem, revision, resume)
	if not self:is_engaged() then
		return
	end
	local selector_id, visible = self.selector_id, self.active
	self.generation = self.generation + 1
	local captured = self.generation
	self.starting, self.active, self.confirming, self.executing = false, false, false, false
	if close then
		self:_close(selector_id, captured)
	end
	if visible then
		self.on_leave()
	end
	self.closing_generation = nil
	self.selector_id, self.entries, self.children, self.expanded = nil, nil, nil, nil
	self.marks, self.mark_order, self.tokens, self.loading = nil, nil, nil, nil
	self.presentation_version_two, self.directory_selection_version_one = nil, nil
	if resume ~= false then
		self.on_resume(revision)
	end
	if problem then
		self.on_error(problem)
	elseif revision then
		self.on_success(revision)
	end
end

---@param self table
---@param problem DweProblem
function M.fail(self, problem)
	self:_exit(self.selector_id ~= nil, problem)
end

---Starts a server-backed Add Existing selector and loads its complete root page.
---@param self table
---@param options DweSelectorStartOptions
function M.start(self, options)
	if not self.valid or not self.is_live() then
		return
	end
	if not self.workspace:has_capability("workspace.addExisting.selector") then
		return self.on_error(
			rpc.problem(
				"unsupported_capability",
				"The workspace does not support the Add Existing selector."
			)
		)
	end
	if self:is_engaged() then
		self:_exit(self.selector_id ~= nil)
	end
	self.generation = self.generation + 1
	local captured = self.generation
	self.starting, self.active = true, false
	self.on_suspend()
	self.target_id, self.target_kind, self.revision =
		options.target_id, options.target_kind, options.revision
	self.presentation_version_two =
		self.workspace:has_capability("workspace.addExisting.presentation.v2")
	self.directory_selection_version_one =
		self.workspace:has_capability("workspace.addExisting.directories.v1")
	self.entries, self.children, self.expanded, self.marks, self.loading = {}, {}, {}, {}, {}
	self.mark_order, self.tokens = {}, {}
	self.workspace:request("workspace/addExisting/start", {
		targetNodeId = options.target_id,
		selectionId = options.selection_id,
		expectedRevision = options.revision,
		pageSize = self:_page_size(),
	}, function(err, result)
		if not self:_live(captured) then
			return
		end
		if err then
			return self:_fail(err)
		end
		if not protocol.valid_start(result, options.revision, self:_page_size()) then
			return self:_fail(incompatible("The selector start response is incompatible."))
		end
		local root = entries.normalize(
			result.root,
			nil,
			self.presentation_version_two,
			self.directory_selection_version_one
		)
		if
			not root
			or root.kind ~= "directory"
			or not root.expandable
			or root.selectable
			or self.entries[root.id]
		then
			return self:_fail(incompatible("The selector root is incompatible."))
		end
		self.selector_id, self.root_id = result.selectorId, root.id
		self.max_selection_count = 256
		self.entries[root.id] = root
		local ids = { [root.id] = true }
		local collected = entries.add_page(
			result.entries,
			root.id,
			self.entries,
			ids,
			self.presentation_version_two,
			self.directory_selection_version_one
		)
		if not collected or not self:_next_token(result.nextToken) then
			return self:_fail(
				incompatible("The selector start page contains duplicate opaque state.")
			)
		end
		self:_collect(root.id, result.nextToken, self.entries, ids, collected, captured, function()
			if not self:_live(captured) then
				return
			end
			self.children[root.id], self.expanded[root.id] = collected, true
			self.starting, self.active = false, true
			self.on_enter(self)
		end)
	end)
end

---@param self table
function M.cancel(self)
	self:_exit(true)
end

---@param self table
---@param revision integer
function M.workspace_changed(self, revision)
	if self:is_engaged() and not self.executing and revision ~= self.revision then
		self:_fail(rpc.problem("stale_selector", "The workspace changed during Add Existing."))
	end
end

---@param self table
---@param method string
---@param parameters unknown
function M.notification(self, method, parameters)
	if not self:is_engaged() or type(parameters) ~= "table" then
		return
	end
	if method == "workspace/delta" then
		self:workspace_changed(parameters.newRevision)
	elseif method == "workspace/reset" then
		self:workspace_changed(parameters.revision)
	end
end

---@param self table
---@param close? boolean
function M.invalidate(self, close)
	if self:is_engaged() then
		self:_exit(close == true, nil, nil, false)
	end
	self.valid = false
	self.generation = self.generation + 1
end

return M
