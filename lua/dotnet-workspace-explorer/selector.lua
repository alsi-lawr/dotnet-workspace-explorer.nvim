local mutations = require("dotnet-workspace-explorer.mutations")
local rpc = require("dotnet-workspace-explorer.rpc")

local M = {}
local Selector = {}
Selector.__index = Selector
local noop = function() end

local function map(value)
	return type(value) == "table" and not vim.islist(value)
end

local function exact_keys(value, allowed)
	if not map(value) then
		return false
	end
	for key in pairs(value) do
		if allowed[key] == nil then
			return false
		end
	end
	for key, required in pairs(allowed) do
		if required and value[key] == nil then
			return false
		end
	end
	return true
end

local function nonempty(value)
	return type(value) == "string" and value ~= ""
end

local function normalize_entry(value, parent_id)
	if
		not exact_keys(value, {
			entryId = true,
			displayName = true,
			kind = true,
			expandable = true,
			selectable = true,
			iconHint = false,
		})
		or not nonempty(value.entryId)
		or not nonempty(value.displayName)
		or (value.kind ~= "directory" and value.kind ~= "file")
		or type(value.expandable) ~= "boolean"
		or type(value.selectable) ~= "boolean"
		or (value.iconHint ~= nil and not nonempty(value.iconHint))
		or (value.kind == "directory" and value.selectable)
		or (value.kind == "file" and value.expandable)
	then
		return nil
	end
	return {
		id = value.entryId,
		parent_id = parent_id,
		kind = value.kind,
		name = value.displayName,
		expandable = value.expandable,
		selectable = value.selectable,
		icon_hint = value.iconHint,
	}
end

local function valid_next_token(value)
	return value == nil or nonempty(value)
end

local function valid_start(result, revision, page_size)
	if
		not exact_keys(result, {
			revision = true,
			selectorId = true,
			expiresAtUtc = true,
			maxSelectionCount = true,
			root = true,
			entries = true,
			nextToken = false,
		})
	then
		return false
	end
	return result.revision == revision
		and nonempty(result.selectorId)
		and nonempty(result.expiresAtUtc)
		and result.maxSelectionCount == 256
		and type(result.entries) == "table"
		and vim.islist(result.entries)
		and #result.entries <= page_size
		and valid_next_token(result.nextToken)
end

local function valid_page(result, selector_id, parent_id, revision, page_size)
	if
		not exact_keys(result, {
			revision = true,
			selectorId = true,
			parentEntryId = true,
			entries = true,
			nextToken = false,
		})
	then
		return false
	end
	return result.revision == revision
		and result.selectorId == selector_id
		and result.parentEntryId == parent_id
		and type(result.entries) == "table"
		and vim.islist(result.entries)
		and #result.entries <= page_size
		and valid_next_token(result.nextToken)
end

local function incompatible(message)
	return rpc.problem("incompatible_selector", message)
end

function Selector.new(options)
	return setmetatable({
		workspace = options.workspace,
		is_live = options.is_live,
		on_enter = options.on_enter,
		on_render = options.on_render,
		on_leave = options.on_leave,
		on_selected = options.on_selected,
		on_suspend = options.on_suspend or noop,
		on_resume = options.on_resume or noop,
		on_error = options.on_error,
		on_success = options.on_success,
		generation = 0,
		valid = true,
	}, Selector)
end

function Selector:_live(captured)
	return self.valid and self.is_live() and self.generation == captured
end

function Selector:is_engaged()
	return self.valid and (self.starting or self.active) == true
end

function Selector:is_active()
	return self.valid and self.active == true
end

function Selector:_page_size()
	return self.workspace.client.limits.maxPageSize
end

local function add_entries(values, parent_id, entries, ids)
	local page_ids = {}
	for index, value in ipairs(values) do
		local entry = normalize_entry(value, parent_id)
		if not entry or ids[entry.id] then
			return nil
		end
		entries[entry.id], ids[entry.id], page_ids[index] = entry, true, entry.id
	end
	return page_ids
end

function Selector:_next_token(token)
	if token == nil then
		return true
	end
	if self.tokens[token] then
		return false
	end
	self.tokens[token] = true
	return true
end

function Selector:_close(selector_id, captured)
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
			if not exact_keys(result, { closed = true }) or result.closed ~= true then
				self.on_error(incompatible("The selector close response is incompatible."))
			end
		end
	)
end

function Selector:_exit(close, problem, revision, resume)
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
	if resume ~= false then
		self.on_resume(revision)
	end
	if problem then
		self.on_error(problem)
	elseif revision then
		self.on_success(revision)
	end
end

function Selector:_fail(problem)
	self:_exit(self.selector_id ~= nil, problem)
end

function Selector:_collect(parent_id, token, entries, ids, collected, captured, complete)
	if token == nil then
		return complete()
	end
	self.workspace:request("workspace/addExisting/children", {
		selectorId = self.selector_id,
		parentEntryId = parent_id,
		pageSize = self:_page_size(),
		continuationToken = token,
	}, function(err, result)
		if not self:_live(captured) then
			return
		end
		if err then
			return self:_fail(err)
		end
		if not valid_page(result, self.selector_id, parent_id, self.revision, self:_page_size()) then
			return self:_fail(incompatible("The selector children response is incompatible."))
		end
		local page_ids = add_entries(result.entries, parent_id, entries, ids)
		if not page_ids or not self:_next_token(result.nextToken) then
			return self:_fail(incompatible("The selector page contains duplicate opaque state."))
		end
		vim.list_extend(collected, page_ids)
		self:_collect(parent_id, result.nextToken, entries, ids, collected, captured, complete)
	end)
end

function Selector:start(options)
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
		if not valid_start(result, options.revision, self:_page_size()) then
			return self:_fail(incompatible("The selector start response is incompatible."))
		end
		local root = normalize_entry(result.root, nil)
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
		self.expires_at_utc, self.max_selection_count = result.expiresAtUtc, 256
		self.entries[root.id] = root
		local ids = { [root.id] = true }
		local collected = add_entries(result.entries, root.id, self.entries, ids)
		if not collected or not self:_next_token(result.nextToken) then
			return self:_fail(incompatible("The selector start page contains duplicate opaque state."))
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

function Selector:select(id)
	if self.entries and self.entries[id] then
		self.selected_id = id
	end
end

function Selector:get_entry(id)
	return self.entries and self.entries[id]
end

function Selector:children_of(id)
	return self.children and self.children[id]
end

function Selector:is_expandable(id)
	local entry = self:get_entry(id)
	return entry and entry.expandable == true
end

function Selector:toggle()
	if not self:is_active() then
		return
	end
	local id = self.on_selected(self)
	local entry = id and self.entries[id]
	if not entry or entry.kind ~= "file" or not entry.selectable then
		return self.on_error(
			rpc.problem("not_selectable", "Select an eligible file before toggling it.")
		)
	end
	if self.marks[id] then
		self.marks[id] = nil
		for index, marked_id in ipairs(self.mark_order) do
			if marked_id == id then
				table.remove(self.mark_order, index)
				break
			end
		end
	elseif #self.mark_order >= self.max_selection_count then
		return self.on_error(rpc.problem("selection_limit", "The selector accepts at most 256 files."))
	else
		self.marks[id], self.mark_order[#self.mark_order + 1] = true, id
	end
	self.on_render(self)
end

function Selector:_load(id, captured)
	self.loading[id] = true
	local entries, ids, collected = {}, {}, {}
	for entry_id in pairs(self.entries) do
		ids[entry_id] = true
	end
	self.workspace:request("workspace/addExisting/children", {
		selectorId = self.selector_id,
		parentEntryId = id,
		pageSize = self:_page_size(),
	}, function(err, result)
		if not self:_live(captured) then
			return
		end
		if err then
			return self:_fail(err)
		end
		if not valid_page(result, self.selector_id, id, self.revision, self:_page_size()) then
			return self:_fail(incompatible("The selector children response is incompatible."))
		end
		local page_ids = add_entries(result.entries, id, entries, ids)
		if not page_ids or not self:_next_token(result.nextToken) then
			return self:_fail(incompatible("The selector page contains duplicate opaque state."))
		end
		vim.list_extend(collected, page_ids)
		self:_collect(id, result.nextToken, entries, ids, collected, captured, function()
			if not self:_live(captured) then
				return
			end
			for entry_id, entry in pairs(entries) do
				self.entries[entry_id] = entry
			end
			self.loading[id] = nil
			self.children[id], self.expanded[id] = collected, true
			self.on_render(self)
		end)
	end)
end

function Selector:expand()
	if not self:is_active() then
		return
	end
	local id = self.on_selected(self)
	if not id or not self:is_expandable(id) then
		return self.on_error(
			rpc.problem("not_expandable", "The selected selector entry is not expandable.")
		)
	end
	if self.children[id] then
		self.expanded[id] = true
		return self.on_render(self)
	end
	if self.loading[id] then
		return
	end
	self:_load(id, self.generation)
end

function Selector:collapse()
	if not self:is_active() then
		return
	end
	local id = self.on_selected(self)
	if not id or not self:is_expandable(id) then
		return self.on_error(
			rpc.problem("not_expandable", "The selected selector entry is not expandable.")
		)
	end
	self.expanded[id] = nil
	self.on_render(self)
end

function Selector:confirm()
	if not self:is_active() or self.confirming or self.executing then
		return
	end
	self.on_selected(self)
	if #self.mark_order == 0 then
		return self.on_error(rpc.problem("empty_selection", "Select at least one file to add."))
	end
	local captured = self.generation
	local request = {
		commandId = "workspace.addExisting",
		targetNodeId = self.target_id,
		arguments = {
			selectorId = self.selector_id,
			entryIds = vim.deepcopy(self.mark_order),
		},
		expectedRevision = self.revision,
	}
	self.confirming = true
	self.workspace:request("workspace/commands/describe", {
		commandId = request.commandId,
		targetNodeId = request.targetNodeId,
	}, function(err, result)
		if not self:_live(captured) then
			return
		end
		if err then
			return self:_fail(err)
		end
		if not mutations.compatible_descriptor(result, request.commandId, self.target_kind) then
			return self:_fail(
				rpc.problem("incompatible_command", "The Add Existing command descriptor is incompatible.")
			)
		end
		self.workspace:request("workspace/commands/preview", request, function(preview_err, preview)
			if not self:_live(captured) then
				return
			end
			if preview_err then
				return self:_fail(preview_err)
			end
			if not mutations.compatible_preview(preview) then
				return self:_fail(
					rpc.problem("incompatible_preview", "The Add Existing command preview is incompatible.")
				)
			end
			vim.ui.select({ "Add Existing", "Cancel" }, {
				prompt = mutations.effects_prompt(preview),
				kind = "confirmation",
			}, function(choice)
				if not self:_live(captured) then
					return
				end
				self.confirming = false
				if choice ~= "Add Existing" then
					return
				end
				local execute = vim.deepcopy(request)
				execute.confirmationToken = preview.confirmationToken
				self.executing = true
				self.workspace:request("workspace/commands/execute", execute, function(execute_err, applied)
					if not self:_live(captured) then
						return
					end
					if execute_err then
						return self:_fail(execute_err)
					end
					if not mutations.compatible_applied(applied) then
						return self:_fail(
							rpc.problem("incompatible_result", "The Add Existing result is incompatible.")
						)
					end
					self:_exit(false, nil, applied.revision)
				end)
			end)
		end)
	end)
end

function Selector:cancel()
	self:_exit(true)
end

function Selector:workspace_changed(revision)
	if self:is_engaged() and not self.executing and revision ~= self.revision then
		self:_fail(rpc.problem("stale_selector", "The workspace changed during Add Existing."))
	end
end

function Selector:notification(method, parameters)
	if not self:is_engaged() or type(parameters) ~= "table" then
		return
	end
	if method == "workspace/delta" then
		self:workspace_changed(parameters.newRevision)
	elseif method == "workspace/reset" then
		self:workspace_changed(parameters.revision)
	end
end

function Selector:invalidate(close)
	if self:is_engaged() then
		self:_exit(close == true, nil, nil, false)
	end
	self.valid = false
	self.generation = self.generation + 1
end

M.Selector = Selector

return M
