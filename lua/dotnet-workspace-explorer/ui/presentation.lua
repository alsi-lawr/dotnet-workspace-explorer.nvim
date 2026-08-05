local config = require("dotnet-workspace-explorer.config")
local git_states = require("dotnet-workspace-explorer.git.states")

local M = {}

M.links = {
	Disclosure = "NonText",
	Solution = "Title",
	Project = "Identifier",
	Folder = "Directory",
	DependencyContainer = "Special",
	Dependency = "Constant",
	DependencyProperty = "Comment",
	File = "Normal",
	Mark = "Special",
	SelectorTarget = "Special",
	SelectorExisting = "DiffAdd",
	GitStaged = "DiffAdd",
	GitUnstaged = "DiffChange",
	GitRenamed = "DiffChange",
	GitDeleted = "DiffDelete",
	GitUnmerged = "DiffText",
	GitUntracked = "DiffAdd",
	GitIgnored = "Comment",
}

---@class DwePresentationKind
---@field glyph? string
---@field icon? string
---@field group string
---@field devicon? string

---@type table<DweNodeKind, DwePresentationKind>
M.kinds = {
	workspace = { glyph = "solution", group = "Solution", devicon = "workspace.slnx" },
	solutionFolder = { glyph = "folder", group = "Folder" },
	project = { glyph = "project", group = "Project", devicon = "project.csproj" },
	projectFolder = { glyph = "folder", group = "Folder" },
	dependencyContainer = { glyph = "folder", group = "DependencyContainer" },
	dependency = { glyph = "file", group = "Dependency", devicon = "dependency.dll" },
	dependencyProperty = { icon = "", group = "DependencyProperty" },
	solutionItem = { glyph = "file", group = "File" },
	projectFile = { glyph = "file", group = "File" },
	directory = { glyph = "folder", group = "Folder" },
	file = { glyph = "file", group = "File" },
}

---@param group string
---@param start integer
---@param finish integer
---@return DweHighlightSpan
function M.span(group, start, finish)
	return { group = group, start = start, finish = finish }
end

---Resolves a configured, fixed, or nvim-web-devicons icon.
---@param item DweNode|DweSelectorEntry
---@param kind DwePresentationKind
---@param fallback string
---@param expanded? boolean
---@return string, string?
function M.icon(item, kind, fallback, expanded)
	if kind.icon ~= nil then
		return kind.icon
	end
	if not config.get().presentation.devicons then
		return fallback
	end
	local loaded, devicons = pcall(require, "nvim-web-devicons")
	if not loaded or type(devicons.get_icon) ~= "function" then
		return fallback
	end
	local fixed = (
		(item.kind:find("Folder$") or item.kind == "directory") and (expanded and "" or "")
	)
		or (item.kind == "dependencyContainer" and "")
		or (item.kind == "dependency" and item.name:match(" %([^()]+%)$") and "")
	if fixed then
		return fixed
	end
	local file = item.kind == "file" or item.kind == "projectFile" or item.kind == "solutionItem"
	local extension = item.kind == "file" and item.icon_hint or nil
	local found, icon, group =
		pcall(devicons.get_icon, kind.devicon or item.name, extension, { default = file })
	if found and type(icon) == "string" and icon ~= "" and type(group) == "string" then
		return icon, group
	end
	return fallback
end

---Appends canonical Git glyphs and corresponding highlight spans.
---@param prefix string
---@param highlights DweHighlightSpan[]
---@param states? DweGitState[]
---@param icon_present boolean
---@return string
function M.append_git(prefix, highlights, states, icon_present)
	if not states or #states == 0 then
		return prefix .. (icon_present and " " or "")
	end
	if prefix ~= "" and not prefix:match("%s$") then
		prefix = prefix .. " "
	end
	for _, presentation in ipairs(git_states.presentation) do
		if vim.tbl_contains(states, presentation.name) then
			local start = #prefix
			prefix = prefix .. presentation.glyph
			highlights[#highlights + 1] = M.span(
				"DotnetWorkspaceExplorer" .. presentation.group,
				start,
				start + #presentation.glyph
			)
		end
	end
	return prefix .. " "
end

return M
