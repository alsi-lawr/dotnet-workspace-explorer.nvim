local tables = require("dotnet-workspace-explorer.util.table")
local value = require("dotnet-workspace-explorer.protocol.value")

local M = {}

---@param left DweNodeId?
---@param right DweNodeId?
---@return boolean
local function same_parent(left, right)
	return left == right
end

---Applies an ordered workspace delta atomically. The state is mutated only after every change validates.
---@param state DweWorkspaceTree
---@param delta unknown
---@param normalize_node fun(value: unknown, workspace_id: string, revision: integer, parent_id?: DweNodeId): DweNode?
---@return boolean
function M.apply(state, delta, normalize_node)
	if
		type(delta) ~= "table"
		or delta.workspaceId ~= state.workspace_id
		or not value.is_integer(delta.baseRevision)
		or not value.is_integer(delta.newRevision)
		or delta.newRevision <= delta.baseRevision
		or type(delta.changes) ~= "table"
		or not vim.islist(delta.changes)
		or type(delta.diagnostics) ~= "table"
		or not vim.islist(delta.diagnostics)
	then
		return false
	end

	local reflected = delta.newRevision == state.revision
		and state.reflected_base_revision == delta.baseRevision
	if delta.baseRevision ~= state.revision and not reflected then
		return false
	end

	local nodes = tables.copy_map(state.nodes)
	local children = {}
	for id, child_ids in pairs(state.children) do
		children[id] = tables.copy_list(child_ids)
	end
	local roots = tables.copy_list(state.roots)
	local expanded = tables.copy_map(state.expanded)
	local selected = state.selected_id

	---@param parent_id? DweNodeId
	---@return DweNodeId[]?
	local function siblings(parent_id)
		if parent_id == nil then
			return roots
		end
		if not nodes[parent_id] then
			return nil
		end
		children[parent_id] = children[parent_id] or {}
		return children[parent_id]
	end

	---@param list DweNodeId[]
	---@param id DweNodeId
	---@return boolean
	local function remove(list, id)
		for index, value_id in ipairs(list) do
			if value_id == id then
				table.remove(list, index)
				return true
			end
		end
		return false
	end

	---@param list DweNodeId[]
	---@param index integer
	---@param id DweNodeId
	---@return boolean
	local function insert(list, index, id)
		if not value.is_integer(index) or index > #list then
			return false
		end
		table.insert(list, index + 1, id)
		return true
	end

	for _, change in ipairs(delta.changes) do
		if type(change) ~= "table" or type(change.kind) ~= "string" then
			return false
		end

		if change.kind == "add" then
			local added = normalize_node(
				change.node,
				state.workspace_id,
				delta.newRevision,
				change.parentNodeId
			)
			local list = siblings(change.parentNodeId)
			if
				not added
				or nodes[added.id]
				or not list
				or not insert(list, change.index, added.id)
			then
				return false
			end
			nodes[added.id] = added
		elseif change.kind == "remove" then
			local removed = nodes[change.id]
			local list = siblings(change.parentNodeId)
			if
				not removed
				or not value.is_integer(change.index)
				or not same_parent(removed.parent_id, change.parentNodeId)
				or children[change.id] and #children[change.id] > 0
				or not list
				or list[change.index + 1] ~= change.id
				or not remove(list, change.id)
			then
				return false
			end
			nodes[change.id], children[change.id], expanded[change.id] = nil, nil, nil
			if selected == change.id then
				selected = change.parentNodeId
			end
		elseif change.kind == "update" then
			local updated = normalize_node(
				change.node,
				state.workspace_id,
				delta.newRevision,
				change.parentNodeId
			)
			local current = updated and nodes[updated.id]
			local list = siblings(change.parentNodeId)
			if
				not current
				or not value.is_integer(change.index)
				or not same_parent(current.parent_id, change.parentNodeId)
				or not list
				or updated == nil
				or list[change.index + 1] ~= updated.id
			then
				return false
			end
			nodes[updated.id] = updated
		elseif change.kind == "move" then
			local moved = nodes[change.id]
			local old_list = siblings(change.oldParentId)
			if
				not moved
				or not value.is_integer(change.oldIndex)
				or not same_parent(moved.parent_id, change.oldParentId)
				or not old_list
				or old_list[change.oldIndex + 1] ~= change.id
				or not remove(old_list, change.id)
			then
				return false
			end
			local new_list = siblings(change.newParentId)
			if not new_list or not insert(new_list, change.newIndex, change.id) then
				return false
			end
			local replacement = tables.copy_map(moved) ---@cast replacement DweNode
			replacement.parent_id, replacement.revision = change.newParentId, delta.newRevision
			nodes[change.id] = replacement
		elseif change.kind == "replace" then
			local current = nodes[change.oldId]
			local replacement = normalize_node(
				change.node,
				state.workspace_id,
				delta.newRevision,
				change.parentNodeId
			)
			local old_list = current and siblings(current.parent_id)
			if
				not current
				or not replacement
				or nodes[replacement.id]
				or not old_list
				or not remove(old_list, change.oldId)
			then
				return false
			end
			local new_list = siblings(change.parentNodeId)
			if not new_list or not insert(new_list, change.index, replacement.id) then
				return false
			end
			nodes[change.oldId], nodes[replacement.id] = nil, replacement
			children[replacement.id], children[change.oldId] = children[change.oldId], nil
			for _, child_id in ipairs(children[replacement.id] or {}) do
				local child = tables.copy_map(nodes[child_id]) ---@cast child DweNode
				child.parent_id, child.revision = replacement.id, delta.newRevision
				nodes[child_id] = child
			end
			expanded[replacement.id], expanded[change.oldId] = expanded[change.oldId], nil
			if selected == change.oldId then
				selected = replacement.id
			end
		else
			return false
		end
	end

	state.nodes, state.children, state.roots = nodes, children, roots
	state.expanded, state.selected_id = expanded, selected
	state.revision, state.reflected_base_revision = delta.newRevision, nil
	return true
end

return M
