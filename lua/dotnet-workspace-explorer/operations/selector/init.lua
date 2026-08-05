local command = require("dotnet-workspace-explorer.operations.selector.command")
local entries = require("dotnet-workspace-explorer.operations.selector.entries")
local paging = require("dotnet-workspace-explorer.operations.selector.paging")
local session = require("dotnet-workspace-explorer.operations.selector.session")
local rpc = require("dotnet-workspace-explorer.rpc")

local M = {}
local Selector = {}
Selector.__index = Selector
local noop = function() end

---@class DweSelectorOptions
---@field workspace DweWorkspaceTree
---@field is_live fun(): boolean
---@field on_enter fun(selector: table)
---@field on_render fun(selector: table)
---@field on_leave fun()
---@field on_selected fun(selector: table): string?
---@field on_suspend? fun()
---@field on_resume? fun(revision?: integer)
---@field on_error fun(problem: DweProblem)
---@field on_success fun(revision: integer)

---Creates an Add Existing selector coordinator for one workspace session.
---@param options DweSelectorOptions
---@return table
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

---@param captured integer
---@return boolean
function Selector:_live(captured)
	return self.valid and self.is_live() and self.generation == captured
end

---@return boolean
function Selector:is_engaged()
	return self.valid and (self.starting or self.active) == true
end

---@return boolean
function Selector:is_active()
	return self.valid and self.active == true
end

---@param id string
function Selector:select(id)
	if self.entries and self.entries[id] then
		self.selected_id = id
	end
end

---@param id string
---@return DweSelectorEntry?
function Selector:get_entry(id)
	return self.entries and self.entries[id]
end

---@param id string
---@return string[]?
function Selector:children_of(id)
	return self.children and self.children[id]
end

---@param id string
---@return boolean
function Selector:is_expandable(id)
	local entry = self:get_entry(id)
	return entry and entry.expandable == true or false
end

---@param id string
---@param ancestor_id string
---@return boolean
function Selector:_is_descendant(id, ancestor_id)
	return entries.is_descendant(self.entries, id, ancestor_id)
end

---Toggles the selected file or directory in the Add Existing mark set.
function Selector:toggle()
	if not self:is_active() then
		return
	end
	local id = self.on_selected(self)
	local entry = id and self.entries[id]
	if not entry then
		return self.on_error(
			rpc.problem(
				"missing_selector_entry",
				"Select a file or directory before marking it for Add Existing."
			)
		)
	end
	if entry.availability == "alreadyPresent" then
		return
	end
	if entry.kind == "directory" and not self.directory_selection_version_one then
		return
	end
	local problem = entries.selection_problem(self, entry)
	if problem then
		return self.on_error(problem)
	end

	if self.marks[id] then
		self.marks[id] = nil
		for index, marked_id in ipairs(self.mark_order) do
			if marked_id == id then
				table.remove(self.mark_order, index)
				break
			end
		end
	else
		local retained = {}
		for _, marked_id in ipairs(self.mark_order) do
			local marked = self.entries[marked_id]
			local overlaps = (entry.kind == "directory" and self:_is_descendant(marked_id, id))
				or (marked and marked.kind == "directory" and self:_is_descendant(id, marked_id))
			if overlaps then
				self.marks[marked_id] = nil
			else
				retained[#retained + 1] = marked_id
			end
		end
		self.mark_order = retained
		if #self.mark_order >= self.max_selection_count then
			return self.on_error(
				rpc.problem("selection_limit", "The selector accepts at most 256 items.")
			)
		end
		self.marks[id], self.mark_order[#self.mark_order + 1] = true, id
	end
	self.on_render(self)
end

---Expands/collapses a directory or confirms when a file is activated.
function Selector:activate()
	if not self:is_active() then
		return
	end
	local id = self.on_selected(self)
	local entry = id and self.entries[id]
	if not entry then
		return self.on_error(
			rpc.problem("missing_selector_entry", "Select a selector entry before activating it.")
		)
	end
	if entry.kind == "directory" then
		if self.expanded[id] then
			return self:collapse()
		end
		return self:expand()
	end
	self:confirm()
end

---Expands the selected selector directory, loading it on first use.
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

---Collapses the selected selector directory.
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

Selector._page_size = paging.page_size
Selector._next_token = paging.next_token
Selector._collect = paging.collect
Selector._load = paging.load

Selector._close = session.close_remote
Selector._exit = session.exit
Selector._fail = session.fail
Selector.start = session.start
Selector.cancel = session.cancel
Selector.workspace_changed = session.workspace_changed
Selector.notification = session.notification
Selector.invalidate = session.invalidate

Selector.confirm = command.confirm

M.Selector = Selector
return M
