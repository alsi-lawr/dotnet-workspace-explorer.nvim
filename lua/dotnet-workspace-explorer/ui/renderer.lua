local config = require("dotnet-workspace-explorer.config")
local presentation = require("dotnet-workspace-explorer.ui.presentation")
local window = require("dotnet-workspace-explorer.ui.window")

local M = {}

---@param state DweViewState
---@param lines string[]
---@param rows DweRenderRow[]
local function write(state, lines, rows)
	vim.bo[state.buf].modifiable = true
	vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
	vim.bo[state.buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(state.buf, state.ns, 0, -1)
	for index, row in ipairs(rows) do
		for _, highlight in ipairs(row.highlights) do
			vim.api.nvim_buf_add_highlight(
				state.buf,
				state.ns,
				highlight.group,
				index - 1,
				highlight.start,
				highlight.finish
			)
		end
		if row.sign then
			vim.api.nvim_buf_set_extmark(state.buf, state.ns, index - 1, 0, {
				sign_text = row.sign.text,
				sign_hl_group = row.sign.group,
				priority = 20,
			})
		end
	end
end

---Captures semantic selection and viewport state independently of row numbers.
---@param state DweViewState
---@param selected? string
---@return DweViewSnapshot
function M.capture(state, selected)
	local snapshot = {
		selected = selected,
		ancestors = {},
		focus = vim.api.nvim_get_current_win(),
	}
	if window.valid("win", state.win) then
		local old = state.rows[vim.api.nvim_win_get_cursor(state.win)[1]]
		snapshot.selected = old and old.id or snapshot.selected
		snapshot.ancestors = old and old.ancestors or {}
		snapshot.saved = vim.api.nvim_win_call(state.win, vim.fn.winsaveview)
		local top = state.rows[snapshot.saved.topline]
		snapshot.anchor = top and { id = top.id, offset = 0 }
		snapshot.width = vim.api.nvim_win_get_width(state.win)
	end
	return snapshot
end

---@class DweRenderSource
---@field roots string[]
---@field selected_id? string
---@field get fun(id: string): DweNode?|DweSelectorEntry?
---@field is_expandable fun(id: string): boolean
---@field children_of fun(id: string): string[]?
---@field expanded table<string, boolean>
---@field git_states fun(item: DweNode|DweSelectorEntry, id: string): DweGitState[]?
---@field sign fun(item: DweNode|DweSelectorEntry, id: string): DweSign?
---@field select fun(id: string)
---@field empty_line? string
---@field good? boolean

---@param state DweViewState
---@param source DweRenderSource
---@param restoration? DweViewSnapshot
local function render(state, source, restoration)
	if not window.valid("buf", state.buf) then
		return
	end
	local snapshot = restoration or M.capture(state, source.selected_id)
	local selected, ancestors = snapshot.selected, snapshot.ancestors
	local lines, rows, by_id, glyphs = {}, {}, {}, config.get().glyphs

	---@param id string
	---@param depth integer
	---@param parents string[]
	local function add(id, depth, parents)
		local item = source.get(id)
		if not item then
			return
		end
		local expandable = source.is_expandable(id)
		local disclosure = expandable and (source.expanded[id] and glyphs.open or glyphs.closed)
			or glyphs.leaf
		local kind = presentation.kinds[item.kind] or presentation.kinds.projectFile
		local fallback = kind.icon ~= nil and kind.icon or glyphs[kind.glyph]
		local icon, icon_group = presentation.icon(item, kind, fallback, source.expanded[id])
		local indent, name = ("  "):rep(depth), item.name:gsub("[\r\n]+[ \t]*", "\t")
		local prefix, highlights = indent, {}
		if disclosure ~= "" then
			local disclosure_start = #prefix
			prefix = prefix .. disclosure .. " "
			highlights[#highlights + 1] = presentation.span(
				"DotnetWorkspaceExplorerDisclosure",
				disclosure_start,
				disclosure_start + #disclosure
			)
		end
		local icon_start = #prefix
		prefix = prefix .. icon
		if icon ~= "" then
			highlights[#highlights + 1] = presentation.span(
				icon_group or ("DotnetWorkspaceExplorer" .. kind.group),
				icon_start,
				icon_start + #icon
			)
		end
		prefix =
			presentation.append_git(prefix, highlights, source.git_states(item, id), icon ~= "")
		local name_start = #prefix
		lines[#lines + 1] = prefix .. name
		highlights[#highlights + 1] = presentation.span(
			"DotnetWorkspaceExplorer" .. kind.group,
			name_start,
			name_start + #name
		)
		rows[#rows + 1] = {
			id = id,
			depth = depth,
			ancestors = parents,
			highlights = highlights,
			sign = source.sign(item, id),
		}
		by_id[id] = #rows
		if source.expanded[id] then
			local child_parents = vim.list_extend(vim.deepcopy(parents), { id })
			for _, child in ipairs(source.children_of(id) or {}) do
				add(child, depth + 1, child_parents)
			end
		end
	end

	for _, id in ipairs(source.roots) do
		add(id, 0, {})
	end
	if #lines == 0 then
		lines = { source.empty_line or "(empty workspace)" }
	end
	write(state, lines, rows)
	state.rows = rows
	if source.good ~= nil then
		state.good = source.good
	end

	local row = by_id[selected]
	for index = #ancestors, 1, -1 do
		row = row or by_id[ancestors[index]]
	end
	row = row or by_id[source.roots[1]] or 1
	if window.valid("win", state.win) then
		vim.api.nvim_win_set_cursor(state.win, { math.min(row, #lines), 0 })
		if snapshot.anchor and by_id[snapshot.anchor.id] and snapshot.saved then
			snapshot.saved.topline = by_id[snapshot.anchor.id] + snapshot.anchor.offset
			vim.api.nvim_win_call(state.win, function()
				vim.fn.winrestview(snapshot.saved)
			end)
		end
		if snapshot.width and vim.api.nvim_win_get_width(state.win) ~= snapshot.width then
			vim.api.nvim_win_set_width(state.win, snapshot.width)
		end
	end
	if rows[row] then
		source.select(rows[row].id)
	end
	if restoration and window.valid("win", restoration.focus) then
		vim.api.nvim_set_current_win(restoration.focus)
	end
end

---Renders the normal workspace tree.
---@param state DweViewState
---@param tree DweWorkspaceTree
---@param restoration? DweViewSnapshot
function M.tree(state, tree, restoration)
	render(state, {
		roots = tree.roots,
		selected_id = tree.selected_id,
		get = function(id)
			return tree:get_node(id)
		end,
		is_expandable = function(id)
			return tree:is_expandable(id)
		end,
		children_of = function(id)
			return tree:children_of(id)
		end,
		expanded = tree.expanded,
		git_states = function(_, id)
			return tree.decorations and tree.decorations[id]
		end,
		sign = function(_, id)
			return tree.marks
					and tree.marks[id]
					and {
						text = "󰆤",
						group = "DotnetWorkspaceExplorerMark",
					}
				or nil
		end,
		select = function(id)
			tree:select(id)
		end,
		empty_line = tree.phase == "loading" and "Loading workspace..." or "(empty workspace)",
		good = tree.phase == "ready",
	}, restoration)
end

---Renders the Add Existing selector tree.
---@param state DweViewState
---@param selector table
function M.selector(state, selector)
	render(state, {
		roots = { selector.root_id },
		selected_id = selector.selected_id,
		get = function(id)
			return selector:get_entry(id)
		end,
		is_expandable = function(id)
			return selector:is_expandable(id)
		end,
		children_of = function(id)
			return selector:children_of(id)
		end,
		expanded = selector.expanded,
		git_states = function(item)
			return item.git_states
		end,
		sign = function(item, id)
			if selector.marks[id] then
				return { text = "󰆤", group = "DotnetWorkspaceExplorerSelectorTarget" }
			elseif item.availability == "alreadyPresent" then
				return { text = "✓", group = "DotnetWorkspaceExplorerSelectorExisting" }
			end
		end,
		select = function(id)
			selector:select(id)
		end,
	})
end

---Writes a transient loading line.
---@param state DweViewState
function M.loading(state)
	state.good = false
	write(state, { "Loading workspace..." }, {})
	state.rows = {}
end

---Writes or notifies a normalized workspace error.
---@param state DweViewState
---@param problem DweProblem|string|unknown
function M.failure(state, problem)
	local text = type(problem) == "table" and problem.message or problem
	text = tostring(text or "Workspace operation failed."):gsub("[\r\n]+", " "):sub(1, 100)
	if state.good or not window.valid("buf", state.buf) then
		vim.notify(text, vim.log.levels.ERROR)
	else
		write(state, { "! " .. text }, {})
		state.rows = {}
	end
end

return M
