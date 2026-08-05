local entries = require("dotnet-workspace-explorer.operations.selector.entries")
local protocol = require("dotnet-workspace-explorer.protocol.selector")
local rpc = require("dotnet-workspace-explorer.rpc")

local M = {}

---@param message string
---@return DweProblem
local function incompatible(message)
	return rpc.problem("incompatible_selector", message)
end

---@param self table
---@return integer
function M.page_size(self)
	return self.workspace.client.limits.maxPageSize
end

---Records a continuation token and rejects opaque-state reuse.
---@param self table
---@param token? string
---@return boolean
function M.next_token(self, token)
	if token == nil then
		return true
	end
	if self.tokens[token] then
		return false
	end
	self.tokens[token] = true
	return true
end

---Collects every continuation page for one selector parent.
---@param self table
---@param parent_id string
---@param token? string
---@param target_entries table<string, DweSelectorEntry>
---@param ids table<string, boolean>
---@param collected string[]
---@param captured integer
---@param complete fun()
function M.collect(self, parent_id, token, target_entries, ids, collected, captured, complete)
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
		if
			not protocol.valid_page(
				result,
				self.selector_id,
				parent_id,
				self.revision,
				self:_page_size()
			)
		then
			return self:_fail(incompatible("The selector children response is incompatible."))
		end
		local page_ids = entries.add_page(
			result.entries,
			parent_id,
			target_entries,
			ids,
			self.presentation_version_two,
			self.directory_selection_version_one
		)
		if not page_ids or not self:_next_token(result.nextToken) then
			return self:_fail(incompatible("The selector page contains duplicate opaque state."))
		end
		vim.list_extend(collected, page_ids)
		self:_collect(
			parent_id,
			result.nextToken,
			target_entries,
			ids,
			collected,
			captured,
			complete
		)
	end)
end

---Loads and installs all children of an expanded selector directory.
---@param self table
---@param id string
---@param captured integer
function M.load(self, id, captured)
	self.loading[id] = true
	local loaded_entries, ids, collected = {}, {}, {}
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
		if
			not protocol.valid_page(result, self.selector_id, id, self.revision, self:_page_size())
		then
			return self:_fail(incompatible("The selector children response is incompatible."))
		end
		local page_ids = entries.add_page(
			result.entries,
			id,
			loaded_entries,
			ids,
			self.presentation_version_two,
			self.directory_selection_version_one
		)
		if not page_ids or not self:_next_token(result.nextToken) then
			return self:_fail(incompatible("The selector page contains duplicate opaque state."))
		end
		vim.list_extend(collected, page_ids)
		self:_collect(id, result.nextToken, loaded_entries, ids, collected, captured, function()
			if not self:_live(captured) then
				return
			end
			for entry_id, entry in pairs(loaded_entries) do
				self.entries[entry_id] = entry
			end
			self.loading[id] = nil
			self.children[id], self.expanded[id] = collected, true
			self.on_render(self)
		end)
	end)
end

return M
