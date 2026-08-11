local errors = require("dotnet-workspace-explorer.workspace.errors")

local M = {}

---@param state table
local function ensure(state)
	state.stages = state.stages or {}
	state.next_expansion_token = state.next_expansion_token or 0
end

---@param state table
---@return boolean
function M.has_active(state)
	ensure(state)
	return next(state.stages) ~= nil
end

---@param state table
---@param parent_id DweNodeId
---@return DweExpansionStage?
function M.get(state, parent_id)
	ensure(state)
	return state.stages[parent_id]
end

---@param state table
---@param parent_id DweNodeId
---@param previous_expanded boolean?
---@param waiter fun(error: DweProblem?, ids?: DweNodeId[])
---@return DweExpansionStage
function M.create(state, parent_id, previous_expanded, waiter)
	ensure(state)
	state.next_expansion_token = state.next_expansion_token + 1
	local stage = {
		token = state.next_expansion_token,
		parent_id = parent_id,
		generation = state.client.generation,
		epoch = state.epoch,
		workspace_id = state.workspace_id,
		base_revision = state.revision,
		page_revision = nil,
		next_token = nil,
		seen_tokens = {},
		nodes = {},
		ids = {},
		waiters = { waiter },
		previous_expanded = previous_expanded,
		complete = false,
		awaiting_delta = false,
		settled = false,
	}
	state.stages[parent_id] = stage
	state.loading[parent_id] = stage.waiters
	return stage
end

---@param state table
---@param stage DweExpansionStage
---@return boolean
function M.is_current(state, stage)
	ensure(state)
	return not stage.settled
		and state.stages[stage.parent_id] == stage
		and state.expansion_owner == nil
		and state:_valid(stage.generation, stage.epoch, stage.workspace_id)
		and state.nodes[stage.parent_id] ~= nil
		and state.expanded[stage.parent_id] == true
end

---@param state table
---@param stage DweExpansionStage
---@param problem? DweProblem
---@param ids? DweNodeId[]
---@param restore_expansion? boolean
local function settle(state, stage, problem, ids, restore_expansion)
	if stage.settled then
		return false
	end
	stage.settled = true
	if state.stages and state.stages[stage.parent_id] == stage then
		state.stages[stage.parent_id] = nil
	end
	if state.loading and state.loading[stage.parent_id] == stage.waiters then
		state.loading[stage.parent_id] = nil
	end
	if restore_expansion and state.expanded[stage.parent_id] then
		state.expanded[stage.parent_id] = stage.previous_expanded
	end
	local waiters = stage.waiters
	stage.waiters = {}
	for _, waiter in ipairs(waiters) do
		waiter(problem, ids)
	end
	return true
end

---@param state table
---@param stage DweExpansionStage
---@param problem? DweProblem
---@param notify? boolean
---@return boolean
function M.discard(state, stage, problem, notify)
	local visible = state.stages and state.stages[stage.parent_id] == stage
	local changed = settle(state, stage, problem or errors.stale(), nil, true)
	if changed and visible and notify ~= false then
		state.on_change(state)
	end
	return changed
end

---@param state table
---@param problem? DweProblem
---@param notify? boolean
---@return boolean
function M.discard_all(state, problem, notify)
	ensure(state)
	local already_discarding = state.discarding_stages
	state.discarding_stages = true
	local stages = {}
	for _, stage in pairs(state.stages) do
		stages[#stages + 1] = stage
	end
	local changed = false
	for _, stage in ipairs(stages) do
		changed = settle(state, stage, problem or errors.stale(), nil, true) or changed
	end
	state.discarding_stages = already_discarding
	if changed and notify ~= false then
		state.on_change(state)
	end
	return changed
end

---@param state table
---@param stage DweExpansionStage
---@param notify? boolean
---@return boolean
function M.promote(state, stage, notify)
	if
		not M.is_current(state, stage)
		or not stage.complete
		or stage.awaiting_delta
		or stage.page_revision ~= state.revision
	then
		return false
	end
	for _, id in ipairs(stage.ids) do
		if state.nodes[id] then
			return false
		end
	end
	for _, id in ipairs(stage.ids) do
		state.nodes[id] = stage.nodes[id]
	end
	state.children[stage.parent_id] = vim.deepcopy(stage.ids)
	local ids = state.children[stage.parent_id]
	local changed = settle(state, stage, nil, ids, false)
	if changed and notify ~= false then
		state.on_change(state)
	end
	return changed
end

---@param state table
---@param id DweNodeId
---@return DweNode?
function M.presentation_node(state, id)
	local owner = state.expansion_owner
	if owner and owner.overlay and owner.overlay.nodes[id] then
		return owner.overlay.nodes[id]
	end
	local canonical = state.nodes[id]
	if canonical then
		return canonical
	end
	ensure(state)
	for _, stage in pairs(state.stages) do
		if stage.nodes[id] then
			return stage.nodes[id]
		end
	end
	return nil
end

---@param state table
---@param parent_id DweNodeId
---@return DweNodeId[]?
function M.presentation_children(state, parent_id)
	local owner = state.expansion_owner
	if owner and owner.overlay and owner.overlay.nodes[parent_id] then
		return owner.overlay.children[parent_id]
	end
	local stage = M.get(state, parent_id)
	if stage then
		return stage.ids
	end
	return state.children[parent_id]
end

---@param state table
---@param id DweNodeId
---@return DwePresentationMetadata
function M.presentation_metadata(state, id)
	ensure(state)
	local owner = state.expansion_owner
	if owner and owner.overlay and owner.overlay.nodes[id] then
		return {
			loading = true,
			provisional = true,
			actionable = false,
			parent_id = owner.overlay.nodes[id].parent_id,
		}
	end
	local parent_stage = state.stages[id]
	if parent_stage then
		return { loading = true, provisional = false, actionable = true, parent_id = id }
	end
	for _, stage in pairs(state.stages) do
		if stage.nodes[id] then
			return {
				loading = true,
				provisional = true,
				actionable = false,
				parent_id = stage.parent_id,
			}
		end
	end
	return { loading = false, provisional = false, actionable = state.nodes[id] ~= nil }
end

---@param state table
---@return DweNodeId[]
function M.presentation_roots(state)
	local owner = state.expansion_owner
	return owner and owner.overlay and owner.overlay.roots or state.roots
end

---@param state table
---@return table<DweNodeId, boolean>
function M.presentation_expanded(state)
	local owner = state.expansion_owner
	return owner and owner.overlay and owner.overlay.expanded or state.expanded
end

---@param state table
---@return DweExpansionOwner
function M.claim_owner(state)
	ensure(state)
	M.discard_all(state, errors.stale())
	M.preempt_owner(state, errors.stale())
	state.next_expansion_token = state.next_expansion_token + 1
	local owner = { kind = "whole_tree", token = state.next_expansion_token }
	state.expansion_owner = owner
	return owner
end

---@param state table
---@param owner DweExpansionOwner
---@return boolean
function M.owns(state, owner)
	return state.expansion_owner == owner
end

---@param state table
---@param owner? DweExpansionOwner
---@return boolean
function M.release_owner(state, owner)
	if state.expansion_owner and (owner == nil or state.expansion_owner == owner) then
		state.expansion_owner = nil
		return true
	end
	return false
end

---@param state table
---@param problem? DweProblem
---@return boolean
function M.preempt_owner(state, problem)
	local owner = state.expansion_owner
	if not owner then
		return false
	end
	state.expansion_owner = nil
	local already_preempting = state.preempting_owner
	state.preempting_owner = true
	if owner.cancel then
		owner.cancel(problem or errors.stale())
	end
	state.preempting_owner = already_preempting
	return true
end

---@param change table
---@return unknown
local function added_id(change)
	return type(change.node) == "table" and change.node.id or nil
end

---@param stage DweExpansionStage
---@param change table
---@return boolean
local function conflicts(stage, change)
	local kind = change.kind
	local parent_id = stage.parent_id
	local function staged(id)
		return id ~= nil and stage.nodes[id] ~= nil
	end
	if kind == "add" then
		local id = added_id(change)
		return change.parentNodeId == parent_id or staged(id) or id == parent_id
	elseif kind == "remove" then
		return change.parentNodeId == parent_id or staged(change.id) or change.id == parent_id
	elseif kind == "update" then
		local id = added_id(change)
		if id == parent_id then
			return false
		end
		return staged(id)
	elseif kind == "move" then
		return staged(change.id)
			or change.id == parent_id
			or change.oldParentId == parent_id
			or change.newParentId == parent_id
	elseif kind == "replace" then
		local id = added_id(change)
		return staged(change.oldId)
			or change.oldId == parent_id
			or staged(id)
			or id == parent_id
			or change.parentNodeId == parent_id
	end
	return true
end

---Returns true only for an exact reflected delta disjoint from every active stage, except for
---an update of a staged canonical parent (the hydration case).
---@param state table
---@param delta unknown
---@return boolean
function M.can_retain_reflected(state, delta)
	ensure(state)
	if
		type(delta) ~= "table"
		or delta.workspaceId ~= state.workspace_id
		or delta.newRevision ~= state.revision
		or delta.baseRevision ~= state.reflected_base_revision
		or type(delta.changes) ~= "table"
		or not vim.islist(delta.changes)
	then
		return false
	end
	for _, stage in pairs(state.stages) do
		if stage.page_revision ~= delta.newRevision then
			return false
		end
		for _, change in ipairs(delta.changes) do
			if type(change) ~= "table" or conflicts(stage, change) then
				return false
			end
		end
	end
	return true
end

---@param state table
---@return boolean
function M.reflected_applied(state)
	ensure(state)
	local stages = {}
	for _, stage in pairs(state.stages) do
		stages[#stages + 1] = stage
	end
	for _, stage in ipairs(stages) do
		stage.awaiting_delta = false
		if stage.complete and not M.promote(state, stage, false) then
			return false
		end
	end
	return true
end

return M
