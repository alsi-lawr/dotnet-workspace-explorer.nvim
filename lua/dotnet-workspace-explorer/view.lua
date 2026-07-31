local config = require("dotnet-workspace-explorer.config")

local M = { rows = {}, owned_mappings = {} }
local ns = vim.api.nvim_create_namespace("dotnet-workspace-explorer")
local links = {
	Disclosure = "NonText",
	Solution = "Title",
	Project = "Identifier",
	Folder = "Directory",
	DependencyContainer = "Special",
	Dependency = "Constant",
	DependencyProperty = "Comment",
	File = "Normal",
}
local kinds = {
	workspace = { glyph = "solution", group = "Solution", devicon = "workspace.slnx" },
	solutionFolder = { glyph = "folder", group = "Folder" },
	project = { glyph = "project", group = "Project", devicon = "project.csproj" },
	projectFolder = { glyph = "folder", group = "Folder" },
	dependencyContainer = { glyph = "folder", group = "DependencyContainer" },
	dependency = { glyph = "file", group = "Dependency", devicon = "dependency.dll" },
	dependencyProperty = { icon = "", group = "DependencyProperty" },
	solutionItem = { glyph = "file", group = "File" },
	projectFile = { glyph = "file", group = "File" },
}
local function valid(kind, id)
	return id and vim.api["nvim_" .. kind .. "_is_valid"](id)
end

local function normal_editor(win)
	return valid("win", win) and win ~= M.win and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ""
end

local function remember_editor(win)
	if normal_editor(win) then
		M.editor_win = win
	end
end

local function start_editor_tracking()
	M.editor_group =
		vim.api.nvim_create_augroup("DotnetWorkspaceExplorerEditorWindow", { clear = true })
	vim.api.nvim_create_autocmd("WinEnter", {
		group = M.editor_group,
		callback = function()
			remember_editor(vim.api.nvim_get_current_win())
		end,
	})
end

local function stop_editor_tracking()
	if M.editor_group then
		pcall(vim.api.nvim_del_augroup_by_id, M.editor_group)
	end
	M.editor_group, M.editor_win = nil, nil
end

local function span(group, start, finish)
	return { group = group, start = start, finish = finish }
end

local function write(lines, rows)
	vim.bo[M.buf].modifiable = true
	vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
	vim.bo[M.buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(M.buf, ns, 0, -1)
	for index, row in ipairs(rows) do
		for _, highlight in ipairs(row.highlights) do
			vim.api.nvim_buf_add_highlight(
				M.buf,
				ns,
				highlight.group,
				index - 1,
				highlight.start,
				highlight.finish
			)
		end
	end
end

local function presentation_icon(node, kind, fallback, expanded)
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
	local fixed = (node.kind:find("Folder$") and (expanded and "" or ""))
		or (node.kind == "dependencyContainer" and "")
		or (node.kind == "dependency" and node.name:match(" %([^()]+%)$") and "")
	if fixed then
		return fixed
	end
	local found, icon, group =
		pcall(devicons.get_icon, kind.devicon or node.name, nil, { default = false })
	if found and type(icon) == "string" and icon ~= "" and type(group) == "string" then
		return icon, group
	end
	return fallback
end

function M.open()
	local current = vim.api.nvim_get_current_win()
	remember_editor(current)
	if not valid("buf", M.buf) then
		M.buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(M.buf, "dotnet-workspace-explorer://tree")
		vim.bo[M.buf].buftype, vim.bo[M.buf].bufhidden = "nofile", "hide"
		vim.bo[M.buf].swapfile, vim.bo[M.buf].modifiable = false, false
		for name, link in pairs(links) do
			vim.api.nvim_set_hl(0, "DotnetWorkspaceExplorer" .. name, {
				default = true,
				link = link,
			})
		end
	end
	if not valid("win", M.win) then
		local options = config.get()
		vim.cmd(options.position == "left" and "topleft vsplit" or "botright vsplit")
		M.win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(M.win, M.buf)
		vim.api.nvim_win_set_width(M.win, options.width)
		vim.wo[M.win].cursorline, vim.wo[M.win].wrap = true, false
		vim.api.nvim_set_current_win(current)
		start_editor_tracking()
	end
end

function M.close()
	if valid("win", M.win) then
		vim.api.nvim_win_close(M.win, true)
	end
	M.win = nil
	stop_editor_tracking()
end

function M.focus()
	if valid("win", M.win) then
		remember_editor(vim.api.nvim_get_current_win())
		vim.api.nvim_set_current_win(M.win)
	end
end

function M.is_open()
	return valid("win", M.win)
end

function M.open_file(path)
	remember_editor(vim.api.nvim_get_current_win())
	local target = normal_editor(M.editor_win) and M.editor_win or nil
	if not target then
		local alternate = vim.fn.win_getid(vim.fn.winnr("#"))
		target = normal_editor(alternate) and alternate or nil
	end
	if not target then
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			if normal_editor(win) then
				target = win
				break
			end
		end
	end
	local opened, open_error = pcall(function()
		if not target then
			if not valid("win", M.win) then
				error("The workspace explorer is not open.")
			end
			vim.api.nvim_set_current_win(M.win)
			vim.cmd(config.get().position == "left" and "rightbelow vsplit" or "leftabove vsplit")
			target = vim.api.nvim_get_current_win()
		else
			vim.api.nvim_set_current_win(target)
		end
		vim.cmd({ cmd = "edit", args = { path } })
		M.editor_win = target
	end)
	if not opened then
		return nil, tostring(open_error)
	end
	return true
end

local function local_mapping(lhs)
	local raw = vim.keycode(lhs)
	for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(M.buf, "n")) do
		if mapping.lhsraw == raw then
			return mapping
		end
	end
end

function M.mappings(actions)
	if not valid("buf", M.buf) then
		return
	end
	local blocked = {}
	for lhs, callback in pairs(M.owned_mappings) do
		local mapping = local_mapping(lhs)
		if mapping and mapping.callback == callback then
			vim.keymap.del("n", lhs, { buffer = M.buf })
		elseif mapping then
			blocked[lhs] = true
		end
	end
	M.owned_mappings = {}
	local configured = config.get().mappings
	if configured == false then
		return
	end
	for action, lhs in pairs(configured) do
		if lhs ~= false and not blocked[lhs] and not local_mapping(lhs) then
			local callback = function()
				actions[action]()
			end
			vim.keymap.set("n", lhs, callback, {
				buffer = M.buf,
				desc = "Workspace explorer: " .. action:gsub("_", " "),
				nowait = true,
				silent = true,
			})
			M.owned_mappings[lhs] = callback
		end
	end
end

function M.selected(tree)
	if valid("win", M.win) then
		local row = M.rows[vim.api.nvim_win_get_cursor(M.win)[1]]
		if row then
			tree:select(row.id)
		end
	end
	return tree.selected_id
end

function M.render(tree)
	if not valid("buf", M.buf) then
		return
	end
	local selected, ancestors, saved, anchor, width = tree.selected_id, {}
	if valid("win", M.win) then
		local old = M.rows[vim.api.nvim_win_get_cursor(M.win)[1]]
		selected, ancestors = old and old.id or selected, old and old.ancestors or ancestors
		saved = vim.api.nvim_win_call(M.win, vim.fn.winsaveview)
		local top = M.rows[saved.topline]
		anchor = top and { id = top.id, offset = 0 }
		width = vim.api.nvim_win_get_width(M.win)
	end
	local lines, rows, by_id, glyphs = {}, {}, {}, config.get().glyphs
	local function add(id, depth, parents)
		local node, expandable = tree:get_node(id), tree:is_expandable(id)
		local mark = expandable and (tree.expanded[id] and glyphs.open or glyphs.closed) or glyphs.leaf
		local kind = kinds[node.kind] or kinds.projectFile
		local fallback = kind.icon ~= nil and kind.icon or glyphs[kind.glyph]
		local icon, icon_group = presentation_icon(node, kind, fallback, tree.expanded[id])
		local indent, name = ("  "):rep(depth), node.name:gsub("[\r\n]+[ \t]*", "\t")
		local prefix, highlights = indent, {}
		if mark ~= "" then
			local disclosure_start = #prefix
			prefix = prefix .. mark .. " "
			highlights[#highlights + 1] =
				span("DotnetWorkspaceExplorerDisclosure", disclosure_start, disclosure_start + #mark)
		end
		local icon_start = #prefix
		local separator = icon ~= "" and " " or ""
		local name_start = icon_start + #icon + #separator
		lines[#lines + 1] = prefix .. icon .. separator .. name
		if icon ~= "" then
			highlights[#highlights + 1] =
				span(icon_group or "DotnetWorkspaceExplorer" .. kind.group, icon_start, icon_start + #icon)
		end
		highlights[#highlights + 1] =
			span("DotnetWorkspaceExplorer" .. kind.group, name_start, name_start + #name)
		rows[#rows + 1] = {
			id = id,
			depth = depth,
			ancestors = parents,
			highlights = highlights,
		}
		by_id[id] = #rows
		if tree.expanded[id] then
			parents = vim.list_extend(vim.deepcopy(parents), { id })
			for _, child in ipairs(tree:children_of(id) or {}) do
				add(child, depth + 1, parents)
			end
		end
	end
	for _, id in ipairs(tree.roots) do
		add(id, 0, {})
	end
	if #lines == 0 then
		lines = { tree.phase == "loading" and "Loading workspace..." or "(empty workspace)" }
	end
	write(lines, rows)
	M.rows, M.good = rows, tree.phase == "ready"
	local row = by_id[selected]
	for index = #ancestors, 1, -1 do
		row = row or by_id[ancestors[index]]
	end
	row = row or by_id[tree.roots[1]] or 1
	if valid("win", M.win) then
		vim.api.nvim_win_set_cursor(M.win, { math.min(row, #lines), 0 })
		if anchor and by_id[anchor.id] then
			saved.topline = by_id[anchor.id] + anchor.offset
			vim.api.nvim_win_call(M.win, function()
				vim.fn.winrestview(saved)
			end)
		end
		if vim.api.nvim_win_get_width(M.win) ~= width then
			vim.api.nvim_win_set_width(M.win, width)
		end
	end
	if rows[row] then
		tree:select(rows[row].id)
	end
end

function M.loading()
	M.good = false
	write({ "Loading workspace..." }, {})
end

function M.failure(problem)
	local text = type(problem) == "table" and problem.message or problem
	text = tostring(text or "Workspace operation failed."):gsub("[\r\n]+", " "):sub(1, 100)
	text = text .. " — :DotnetWorkspaceExplorerRefresh"
	if M.good or not valid("buf", M.buf) then
		vim.notify(text, vim.log.levels.ERROR, { title = "Workspace Explorer" })
	else
		write({ "! " .. text }, {})
	end
end

return M
