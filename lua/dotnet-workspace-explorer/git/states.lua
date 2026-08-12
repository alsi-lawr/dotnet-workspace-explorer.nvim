local M = {}

---@class DweGitPresentation
---@field name DweGitState
---@field glyph string
---@field group string

---@type DweGitPresentation[]
M.presentation = {
	{ name = "staged", glyph = "✓", group = "GitStaged" },
	{ name = "unstaged", glyph = "✗", group = "GitUnstaged" },
	{ name = "renamed", glyph = "➜", group = "GitRenamed" },
	{ name = "deleted", glyph = "", group = "GitDeleted" },
	{ name = "unmerged", glyph = "", group = "GitUnmerged" },
	{ name = "untracked", glyph = "★", group = "GitUntracked" },
	{ name = "ignored", glyph = "◌", group = "GitIgnored" },
}

local positions = {}
for index, state in ipairs(M.presentation) do
	positions[state.name] = index
end

---Validates and preserves the canonical presentation order of Git states.
---@param value unknown
---@param allow_empty boolean
---@return DweGitState[]?
function M.normalize(value, allow_empty)
	if type(value) ~= "table" or not vim.islist(value) or (not allow_empty and #value == 0) then
		return nil
	end
	local previous, normalized = 0, {}
	for index, state in ipairs(value) do
		local position = positions[state]
		if not position or position <= previous then
			return nil
		end
		previous, normalized[index] = position, state
	end
	return normalized
end

return M
