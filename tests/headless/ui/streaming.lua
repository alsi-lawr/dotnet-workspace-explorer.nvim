vim.opt.runtimepath:prepend(vim.fn.getcwd())

local config = require("dotnet-workspace-explorer.config")
local actions = require("dotnet-workspace-explorer.controller.actions")
local context = require("dotnet-workspace-explorer.controller.context")
local session = require("dotnet-workspace-explorer.controller.session")
local Editing = require("dotnet-workspace-explorer.operations.editing").Editing
local Mutations = require("dotnet-workspace-explorer.operations.mutations").Mutations
local view_state = require("dotnet-workspace-explorer.ui.state")
local view = require("dotnet-workspace-explorer.ui.view")
local Workspace = require("dotnet-workspace-explorer.workspace.init").Workspace

local function assert_equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(
			("%s\nexpected: %s\nactual: %s"):format(
				message,
				vim.inspect(expected),
				vim.inspect(actual)
			)
		)
	end
end

local function assert_contains(value, expected, message)
	if not value:find(expected, 1, true) then
		error(("%s\nexpected substring: %s\nactual: %s"):format(message, expected, value))
	end
end

local now, scheduled = 0, {}
local function fake_scheduler(delay, callback)
	local item = { at = now + delay, callback = callback, cancelled = false }
	scheduled[#scheduled + 1] = item
	return function()
		item.cancelled = true
	end
end

local function pending_count()
	local count = 0
	for _, item in ipairs(scheduled) do
		if not item.cancelled then
			count = count + 1
		end
	end
	return count
end

local function advance(milliseconds)
	now = now + milliseconds
	local remaining = {}
	for _, item in ipairs(scheduled) do
		if not item.cancelled then
			if item.at <= now then
				item.cancelled = true
				item.callback()
			else
				remaining[#remaining + 1] = item
			end
		end
	end
	scheduled = remaining
end

local nodes = {
	workspace = { id = "workspace", kind = "workspace", name = "Example.slnx" },
	project = {
		id = "project",
		parent_id = "workspace",
		kind = "project",
		name = "Example.fsproj",
	},
}
local provisional = {
	id = "partial",
	parent_id = "project",
	kind = "projectFile",
	name = "First.cs",
}
local staged = true
local selected_id = "project"
local calls = {
	expand = 0,
	collapse = 0,
	expand_all = 0,
	collapse_all = 0,
	refresh = 0,
	request = 0,
	resolve = 0,
	stop = 0,
}
local tree = {
	nodes = nodes,
	children = { workspace = { "project" }, project = {} },
	roots = { "workspace" },
	expanded = { workspace = true, project = true },
	decorations = { partial = { "unstaged" } },
	marks = { partial = true },
	phase = "ready",
	revision = 7,
	workspace_id = "workspace-id",
	git_enabled = false,
}
function tree:get_node(id)
	return self.nodes[id]
end
function tree:presentation_node(id)
	return self.nodes[id] or (staged and id == "partial" and provisional or nil)
end
function tree:children_of(id)
	return self.children[id]
end
function tree:presentation_children_of(id)
	if staged and id == "project" then
		return { "partial" }
	end
	return self.children[id]
end
function tree:presentation_metadata(id)
	if staged and id == "project" then
		return { loading = true, provisional = false, actionable = true, parent_id = id }
	end
	if staged and id == "partial" then
		return { loading = true, provisional = true, actionable = false, parent_id = "project" }
	end
	return { loading = false, provisional = false, actionable = self.nodes[id] ~= nil }
end
function tree.is_expandable(_, id)
	return id == "workspace" or id == "project"
end
function tree:select(id)
	if self.nodes[id] then
		selected_id = id
	end
end
function tree.has_capability(_)
	return true
end
function tree.request(_)
	calls.request = calls.request + 1
end
function tree.expand(_, id)
	calls.expand = calls.expand + 1
	calls.last_id = id
end
function tree.collapse(_, id)
	calls.collapse = calls.collapse + 1
	calls.last_id = id
end
function tree.expand_all(_)
	calls.expand_all = calls.expand_all + 1
end
function tree.collapse_all(_)
	calls.collapse_all = calls.collapse_all + 1
end
function tree.refresh(_, callback)
	calls.refresh = calls.refresh + 1
	if callback then
		callback()
	end
end
function tree.resolve_file(_)
	calls.resolve = calls.resolve + 1
end
function tree.resolve_project(_)
	calls.resolve = calls.resolve + 1
end
function tree.is_terminal(_)
	return false
end
function tree.stop(_)
	calls.stop = calls.stop + 1
	view.schedule(tree)
end
setmetatable(tree, {
	__index = function(_, key)
		if key == "selected_id" then
			return selected_id
		end
	end,
})

local original_set_lines = vim.api.nvim_buf_set_lines
local original_notify = vim.notify
local original_workspace_new = Workspace.new
local original_view_schedule = view.schedule
local writes = 0
local notifications = 0

local function lines()
	return vim.api.nvim_buf_get_lines(view.buf, 0, -1, false)
end

local function row_index(id)
	for index, row in ipairs(view.rows) do
		if row.id == id then
			return index
		end
	end
	error("missing rendered row " .. id)
end

local function cleanup()
	Workspace.new = original_workspace_new
	view.schedule = original_view_schedule
	vim.api.nvim_buf_set_lines = original_set_lines
	vim.notify = original_notify
	view.configure_scheduler(nil)
	pcall(session.close)
	context.tree, context.mutations, context.selector, context.editing, context.git_status =
		nil, nil, nil, nil, nil
	context.target, context.initial_failed, context.terminal_failed, context.has_good =
		nil, nil, nil, nil
	config.setup()
end

local ok, err = xpcall(function()
	config.setup({ presentation = { devicons = false }, git = { enable = false } })
	vim.notify = function()
		notifications = notifications + 1
	end
	view.configure_scheduler(fake_scheduler)
	view.open()
	view.loading()
	vim.api.nvim_buf_set_lines = function(buf, first, last, strict, replacement)
		if buf == view.buf then
			writes = writes + 1
		end
		return original_set_lines(buf, first, last, strict, replacement)
	end

	view.schedule(tree)
	provisional.name = "Latest.cs"
	view.schedule(tree)
	view.schedule(tree)
	assert_equal(1, pending_count(), "a burst retains exactly one scheduled normal render")
	advance(49)
	assert_equal(
		{ "Loading workspace..." },
		lines(),
		"first partial waits only for its coalesced window"
	)
	assert_equal(0, writes, "no redraw occurs before the first window")
	advance(1)
	assert_equal(1, writes, "the first partial redraw occurs at 50 ms")
	assert_contains(lines()[2], "(loading)", "the canonical loading parent is explicit")
	assert_contains(lines()[3], "Latest.cs", "the latest replacement state wins")
	assert_contains(lines()[3], "(provisional, read-only)", "provisional rows are explicit")
	assert_equal(true, view.rows[2].loading, "loading metadata reaches the parent row")
	assert_equal(false, view.rows[2].provisional, "the loading parent stays canonical")
	assert_equal(false, view.rows[3].actionable, "provisional row metadata is non-actionable")
	assert_equal(nil, view.rows[3].sign, "provisional rows suppress canonical marks")

	vim.api.nvim_win_set_cursor(view.win, { row_index("partial"), 0 })
	assert_equal(nil, view.selected(tree), "a provisional cursor returns no canonical target")
	assert_equal(
		"project",
		selected_id,
		"a provisional cursor cannot reuse or replace prior selection"
	)

	local failures = {}
	context.tree = tree
	context.selector = nil
	context.initial_failed, context.terminal_failed = false, false
	context.target, context.has_good = "/workspace/Example.slnx", true
	context.mutations = Mutations.new({
		workspace = tree,
		is_live = function()
			return true
		end,
		selected = function()
			return view.selected(tree)
		end,
		on_error = function(problem)
			failures[#failures + 1] = problem
		end,
		on_refresh = function() end,
	})
	context.editing = Editing.new({
		workspace = tree,
		is_live = function()
			return true
		end,
		selected = function()
			return view.selected(tree)
		end,
		on_error = function(problem)
			failures[#failures + 1] = problem
		end,
		on_render = function()
			error("a provisional row changed canonical marks")
		end,
		on_success = function() end,
	})

	actions.expand()
	actions.collapse()
	actions.activate()
	actions.edit()
	actions.new()
	actions.delete()
	actions.rename()
	actions.mark_move()
	actions.mark_copy()
	context.editing.order = { "project" }
	tree.mark_mode, tree.marks = "move", { project = true }
	actions.place()
	actions.packages()
	assert_equal(0, calls.expand, "provisional Expand is gated")
	assert_equal(0, calls.collapse, "provisional Collapse is gated")
	assert_equal(0, calls.resolve, "provisional open/edit/package resolution is gated")
	assert_equal(0, calls.request, "provisional create/delete/edit routes send no request")
	assert_equal("project", selected_id, "all provisional action routes preserve prior selection")
	assert(#failures >= 5, "target-based operation routes should report no selected target")

	actions.expand_all()
	actions.collapse_all()
	assert_equal(1, calls.expand_all, "Expand All remains available")
	assert_equal(1, calls.collapse_all, "Collapse All remains available")
	session.refresh()
	assert_equal(1, calls.refresh, "Refresh remains available from a provisional cursor")
	vim.api.nvim_win_set_cursor(view.win, { row_index("project"), 0 })
	view.schedule(tree)
	actions.collapse()
	assert_equal(1, calls.collapse, "the canonical loading parent remains collapsible")
	assert_equal("project", calls.last_id, "collapse targets the canonical parent")
	assert_equal(0, pending_count(), "parent collapse invalidates its staged render timer")
	advance(50)
	assert_equal(1, writes, "a cancelled stage timer cannot repaint after parent collapse")

	vim.api.nvim_win_set_cursor(view.win, { row_index("partial"), 0 })
	provisional.name = "Window two latest.cs"
	view.schedule(tree)
	view.schedule(tree)
	assert_equal(1, pending_count(), "the second burst also owns one pending slot")
	advance(49)
	assert_equal(1, writes, "a second redraw cannot occur inside the same window")
	advance(1)
	assert_equal(2, writes, "the next window permits one redraw")
	assert_contains(lines()[3], "Window two latest.cs", "second-window latest state is rendered")

	staged = false
	nodes.partial = provisional
	tree.children.project = { "partial" }
	tree.marks.partial = true
	tree.decorations.partial = { "unstaged" }
	view.schedule(tree)
	local notifications_before_final = notifications
	actions.expand()
	assert_equal(
		notifications_before_final + 1,
		notifications,
		"a provisional target action reports its notification-only failure"
	)
	assert_equal(1, pending_count(), "notification-only failure preserves the final render")
	advance(50)
	assert_equal(3, writes, "completion flushes the latest canonical state")
	assert(not lines()[2]:find("(loading)", 1, true), "completion removes the loading parent style")
	assert(not lines()[3]:find("provisional", 1, true), "completion removes provisional styling")
	assert_equal(true, view.rows[3].actionable, "the promoted row becomes actionable")
	assert_equal("󰆤", view.rows[3].sign.text, "canonical marks survive completed-tree rendering")
	local canonical_git
	for _, highlight in ipairs(view.rows[3].highlights) do
		canonical_git = canonical_git or highlight.group == "DotnetWorkspaceExplorerGitUnstaged"
	end
	assert_equal(true, canonical_git, "canonical Git decoration survives completed-tree rendering")

	staged = true
	nodes.partial = nil
	tree.children.project = {}
	selected_id = "project"
	view.render(tree)
	local selector = {
		root_id = "selector-root",
		selected_id = "selector-root",
		entries = {
			["selector-root"] = {
				id = "selector-root",
				kind = "directory",
				name = "Selector",
				expandable = false,
				git_states = {},
			},
		},
		expanded = {},
		marks = {},
	}
	function selector:get_entry(id)
		return self.entries[id]
	end
	function selector.is_expandable(_)
		return false
	end
	function selector.children_of(_)
		return nil
	end
	function selector:select(id)
		self.selected_id = id
	end
	vim.api.nvim_win_set_cursor(view.win, { row_index("partial"), 0 })
	view.schedule(tree)
	local before_selector_entry = view_state.render_token
	view.enter_selector(selector, { activate = function() end, close = function() end }, tree)
	assert_equal(
		before_selector_entry + 1,
		view_state.render_token,
		"selector entry advances normal-render invalidation"
	)
	local selector_lines = lines()
	advance(50)
	assert_equal(selector_lines, lines(), "selector entry invalidates a stale normal render")
	local before_selector_exit = view_state.render_token
	view.leave_selector(tree)
	assert_equal(
		before_selector_exit + 1,
		view_state.render_token,
		"selector exit advances normal-render invalidation"
	)
	assert_equal(
		"partial",
		view.rows[vim.api.nvim_win_get_cursor(view.win)[1]].id,
		"provisional cursor identity is restored"
	)
	assert_equal(
		"project",
		selected_id,
		"restoring a provisional cursor does not change canonical selection"
	)

	view.schedule(tree)
	view.loading()
	advance(50)
	assert_equal({ "Loading workspace..." }, lines(), "loading mode invalidates a stale render")
	view.schedule(tree)
	view.failure("stream failed")
	advance(50)
	assert_equal({ "! stream failed" }, lines(), "failure mode invalidates a stale render")

	view.render(tree)
	view.schedule(tree)
	local synchronous = lines()
	view.render(tree)
	advance(50)
	assert_equal(synchronous, lines(), "a synchronous normal render invalidates its pending timer")

	local replacement_options
	Workspace.new = function(options)
		replacement_options = options
		local replacement_node = {
			id = "replacement",
			kind = "workspace",
			name = "Replacement.slnx",
		}
		local replacement = {
			nodes = { replacement = replacement_node },
			children = {},
			loading = {},
			stages = {},
			roots = { "replacement" },
			expanded = {},
			marks = {},
			decorations = {},
			phase = "ready",
			revision = 1,
			workspace_id = "replacement",
			git_enabled = false,
		}
		function replacement:start(callback)
			replacement_options.on_change(self)
			callback()
		end
		function replacement.stop(_) end
		function replacement.is_terminal(_)
			return false
		end
		function replacement.has_capability(_)
			return false
		end
		function replacement.defer_reconciliation(_) end
		function replacement.resume_reconciliation(_) end
		function replacement:get_node(id)
			return self.nodes[id]
		end
		function replacement:presentation_node(id)
			return self.nodes[id]
		end
		function replacement:children_of(id)
			return self.children[id]
		end
		function replacement:presentation_children_of(id)
			return self.children[id]
		end
		function replacement:presentation_metadata(id)
			return { loading = false, provisional = false, actionable = self.nodes[id] ~= nil }
		end
		function replacement.is_expandable(_, id)
			return id == "replacement"
		end
		function replacement:select(id)
			self.selected_id = id
		end
		return replacement
	end
	view.schedule(tree)
	local before_replacement = lines()
	local scheduled_replacement
	view.schedule = function(current)
		scheduled_replacement = current
	end
	session.start("/workspace/Replacement.slnx", true)
	assert_equal(
		context.tree,
		scheduled_replacement,
		"workspace on_change routes through coalescing"
	)
	view.schedule = original_view_schedule
	assert_equal(0, pending_count(), "session replacement cancels the preceding timer")
	advance(50)
	assert_equal(before_replacement, lines(), "session replacement invalidates the old tree timer")
	assert_equal(1, calls.stop, "session replacement stops the preceding tree")

	view.open()
	view.schedule(tree)
	local before_close = lines()
	view.close()
	advance(50)
	assert_equal(before_close, lines(), "close invalidates a timer for the hidden buffer")
end, debug.traceback)

cleanup()

if not ok then
	error(err)
end

print("DWE staged rendering and coalescer tests passed")
