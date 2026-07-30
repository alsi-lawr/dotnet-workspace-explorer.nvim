local config = require("dotnet-workspace-explorer.config")

local M = { rows = {}, owned_mappings = {} }
local ns = vim.api.nvim_create_namespace("dotnet-workspace-explorer")
local function valid(kind, id)
	return id and vim.api["nvim_" .. kind .. "_is_valid"](id)
end

local function write(lines, rows)
	vim.bo[M.buf].modifiable = true
	vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
	vim.bo[M.buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(M.buf, ns, 0, -1)
	for index, row in ipairs(rows) do
		local group = row.depth == 0 and "DotnetWorkspaceExplorerRoot" or "DotnetWorkspaceExplorerNode"
		vim.api.nvim_buf_add_highlight(M.buf, ns, group, index - 1, 0, -1)
	end
end

function M.open()
	if not valid("buf", M.buf) then
		M.buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(M.buf, "dotnet-workspace-explorer://tree")
		vim.bo[M.buf].buftype, vim.bo[M.buf].bufhidden = "nofile", "hide"
		vim.bo[M.buf].swapfile, vim.bo[M.buf].modifiable = false, false
		vim.api.nvim_set_hl(0, "DotnetWorkspaceExplorerRoot", { default = true, link = "Title" })
		vim.api.nvim_set_hl(0, "DotnetWorkspaceExplorerNode", { default = true, link = "Normal" })
	end
	if not valid("win", M.win) then
		local options, current = config.get(), vim.api.nvim_get_current_win()
		vim.cmd(options.position == "left" and "topleft vsplit" or "botright vsplit")
		M.win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(M.win, M.buf)
		vim.api.nvim_win_set_width(M.win, options.width)
		vim.wo[M.win].cursorline = true
		vim.api.nvim_set_current_win(current)
	end
end

function M.close()
	if valid("win", M.win) then
		vim.api.nvim_win_close(M.win, true)
	end
	M.win = nil
end

function M.focus()
	if valid("win", M.win) then
		vim.api.nvim_set_current_win(M.win)
	end
end

function M.is_open()
	return valid("win", M.win)
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
	local kinds = { workspace = "solution", solutionFolder = "folder", project = "project" }
	local function add(id, depth, parents)
		local node, expandable = tree:get_node(id), tree:is_expandable(id)
		local mark = expandable and (tree.expanded[id] and glyphs.open or glyphs.closed) or glyphs.leaf
		lines[#lines + 1] = ("  "):rep(depth)
			.. table.concat({ mark, glyphs[kinds[node.kind] or "file"], node.name }, " ")
		rows[#rows + 1] = { id = id, depth = depth, ancestors = parents }
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
