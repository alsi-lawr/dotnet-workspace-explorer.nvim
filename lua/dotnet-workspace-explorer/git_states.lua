local M = {}

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

function M.legacy(state)
	if state == "added" then
		return { "untracked" }
	elseif state == "changed" then
		return { "unstaged" }
	end
end

return M
