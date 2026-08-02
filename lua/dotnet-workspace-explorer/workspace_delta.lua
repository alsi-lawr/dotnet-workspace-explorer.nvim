local M = {}

local function copy_table(values)
	local result = {}
	for key, value in pairs(values) do
		result[key] = value
	end
	return result
end

local function copy_list(values)
	local result = {}
	for index, value in ipairs(values or {}) do
		result[index] = value
	end
	return result
end

local function valid_revision(value)
	return type(value) == "number" and value % 1 == 0 and value >= 0
end

local function valid_index(value)
	return type(value) == "number" and value % 1 == 0 and value >= 0
end

local function same_parent(left, right)
	return left == right
end

function M.apply(state, delta, normalize_node)
	if
		type(delta) ~= "table"
		or delta.workspaceId ~= state.workspace_id
		or not valid_revision(delta.baseRevision)
		or not valid_revision(delta.newRevision)
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

	local nodes = copy_table(state.nodes)
	local children = {}
	for id, values in pairs(state.children) do
		children[id] = copy_list(values)
	end
	local roots = copy_list(state.roots)
	local expanded = copy_table(state.expanded)
	local selected = state.selected_id

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

	local function remove(list, id)
		for index, value in ipairs(list) do
			if value == id then
				table.remove(list, index)
				return true
			end
		end
		return false
	end

	local function insert(list, index, id)
		if not valid_index(index) or index > #list then
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
			local node =
				normalize_node(change.node, state.workspace_id, delta.newRevision, change.parentNodeId)
			local list = siblings(change.parentNodeId)
			if not node or nodes[node.id] or not list or not insert(list, change.index, node.id) then
				return false
			end
			nodes[node.id] = node
		elseif change.kind == "remove" then
			local node = nodes[change.id]
			local list = siblings(change.parentNodeId)
			if
				not node
				or not valid_index(change.index)
				or not same_parent(node.parent_id, change.parentNodeId)
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
			local node =
				normalize_node(change.node, state.workspace_id, delta.newRevision, change.parentNodeId)
			local current = node and nodes[node.id]
			local list = siblings(change.parentNodeId)
			if
				not current
				or not valid_index(change.index)
				or not same_parent(current.parent_id, change.parentNodeId)
				or not list
				or list[change.index + 1] ~= node.id
			then
				return false
			end
			nodes[node.id] = node
		elseif change.kind == "move" then
			local node = nodes[change.id]
			local old_list = siblings(change.oldParentId)
			if
				not node
				or not valid_index(change.oldIndex)
				or not same_parent(node.parent_id, change.oldParentId)
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
			local moved = copy_table(node)
			moved.parent_id, moved.revision = change.newParentId, delta.newRevision
			nodes[change.id] = moved
		elseif change.kind == "replace" then
			local current = nodes[change.oldId]
			local node =
				normalize_node(change.node, state.workspace_id, delta.newRevision, change.parentNodeId)
			local old_list = current and siblings(current.parent_id)
			if
				not current
				or not node
				or nodes[node.id]
				or not old_list
				or not remove(old_list, change.oldId)
			then
				return false
			end
			local new_list = siblings(change.parentNodeId)
			if not new_list or not insert(new_list, change.index, node.id) then
				return false
			end
			nodes[change.oldId], nodes[node.id] = nil, node
			children[node.id], children[change.oldId] = children[change.oldId], nil
			for _, child_id in ipairs(children[node.id] or {}) do
				local child = copy_table(nodes[child_id])
				child.parent_id, child.revision = node.id, delta.newRevision
				nodes[child_id] = child
			end
			expanded[node.id], expanded[change.oldId] = expanded[change.oldId], nil
			if selected == change.oldId then
				selected = node.id
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
