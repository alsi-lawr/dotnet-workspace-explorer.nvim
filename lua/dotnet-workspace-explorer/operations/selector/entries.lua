local git_states = require("dotnet-workspace-explorer.git.states")
local rpc = require("dotnet-workspace-explorer.rpc")
local value = require("dotnet-workspace-explorer.protocol.value")

local M = {}

local availability_values = {
	available = true,
	alreadyPresent = true,
	ineligible = true,
}

local git_state_values = {}
for _, state in ipairs(git_states.presentation) do
	git_state_values[state.name] = true
end

---@param candidate unknown
---@return DweGitState[]?
local function normalize_git_states(candidate)
	if type(candidate) ~= "table" or not vim.islist(candidate) then
		return nil
	end
	local present = {}
	for _, state in ipairs(candidate) do
		if type(state) ~= "string" then
			return nil
		end
		if git_state_values[state] then
			present[state] = true
		end
	end
	local normalized = {}
	for _, state in ipairs(git_states.presentation) do
		if present[state.name] then
			normalized[#normalized + 1] = state.name
		end
	end
	return normalized
end

---Normalizes one selector entry according to negotiated presentation features.
---@param candidate unknown
---@param parent_id? string
---@param presentation_v2 boolean
---@param directory_selection_v1 boolean
---@return DweSelectorEntry?
function M.normalize(candidate, parent_id, presentation_v2, directory_selection_v1)
	if
		not value.is_map(candidate)
		or not value.is_nonempty_string(candidate.entryId)
		or not value.is_nonempty_string(candidate.displayName)
		or (candidate.kind ~= "directory" and candidate.kind ~= "file")
		or type(candidate.expandable) ~= "boolean"
		or type(candidate.selectable) ~= "boolean"
		or (candidate.iconHint ~= nil and not value.is_nonempty_string(candidate.iconHint))
		or (candidate.kind == "directory" and candidate.selectable and not directory_selection_v1)
		or (candidate.kind == "file" and candidate.expandable)
	then
		return nil
	end

	local availability = candidate.selectable and "available" or "ineligible"
	local states = nil
	if presentation_v2 then
		states = normalize_git_states(candidate.gitStates)
		if
			not states
			or not availability_values[candidate.availability]
			or (candidate.kind == "directory" and candidate.availability == "alreadyPresent")
			or (candidate.selectable ~= (candidate.availability == "available"))
			or (candidate.availability == "alreadyPresent" and candidate.kind ~= "file")
		then
			return nil
		end
		availability = candidate.availability
	end
	return {
		id = candidate.entryId,
		parent_id = parent_id,
		kind = candidate.kind,
		name = candidate.displayName,
		expandable = candidate.expandable,
		selectable = candidate.selectable,
		icon_hint = candidate.iconHint,
		availability = availability,
		git_states = states,
	}
end

---Adds one protocol page into an entry map while rejecting duplicate opaque IDs.
---@param values unknown[]
---@param parent_id string
---@param entries table<string, DweSelectorEntry>
---@param ids table<string, boolean>
---@param presentation_v2 boolean
---@param directory_selection_v1 boolean
---@return string[]?
function M.add_page(values, parent_id, entries, ids, presentation_v2, directory_selection_v1)
	local page_ids = {}
	for index, candidate in ipairs(values) do
		local entry = M.normalize(candidate, parent_id, presentation_v2, directory_selection_v1)
		if not entry or ids[entry.id] then
			return nil
		end
		entries[entry.id], ids[entry.id], page_ids[index] = entry, true, entry.id
	end
	return page_ids
end

---@param entries table<string, DweSelectorEntry>
---@param id string
---@param ancestor_id string
---@return boolean
function M.is_descendant(entries, id, ancestor_id)
	local entry = entries[id]
	while entry and entry.parent_id do
		if entry.parent_id == ancestor_id then
			return true
		end
		entry = entries[entry.parent_id]
	end
	return false
end

local file_messages = {
	workspace = "Only .csproj, .fsproj, or .vbproj project files can be added to the solution.",
	solutionFolder = "Only projects or solution items can be added to a Solution Folder.",
	project = "Only non-project files can be added to a project.",
	projectFolder = "Only non-project files can be added to a project folder.",
}
local directory_messages = {
	workspace = "Only .NET project files or non-symbolic directories containing them can be added.",
	solutionFolder = "Only projects, solution items, or non-symbolic directories can be added.",
	project = "Only non-project files or non-symbolic directories can be added to a project.",
	projectFolder = "Only non-project files or non-symbolic directories can be added here.",
}

---@param selector table
---@param entry DweSelectorEntry
---@return DweProblem?
function M.selection_problem(selector, entry)
	if entry.availability == "alreadyPresent" then
		return nil
	end
	if entry.kind == "directory" and not selector.directory_selection_version_one then
		return nil
	end
	if
		(entry.kind ~= "file" and entry.kind ~= "directory")
		or entry.availability ~= "available"
		or not entry.selectable
	then
		local messages = selector.directory_selection_version_one and directory_messages
			or file_messages
		return rpc.problem(
			"not_selectable",
			messages[selector.target_kind]
				or "The selected entry cannot be added to this workspace node."
		)
	end
end

return M
