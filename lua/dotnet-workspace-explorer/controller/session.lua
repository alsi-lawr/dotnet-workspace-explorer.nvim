local config = require("dotnet-workspace-explorer.config")
local context = require("dotnet-workspace-explorer.controller.context")
local Editing = require("dotnet-workspace-explorer.operations.editing").Editing
local Git = require("dotnet-workspace-explorer.git.status").Git
local Mutations = require("dotnet-workspace-explorer.operations.mutations").Mutations
local Selector = require("dotnet-workspace-explorer.operations.selector.init").Selector
local view = require("dotnet-workspace-explorer.ui.view")
local Workspace = require("dotnet-workspace-explorer.workspace.init").Workspace

local M = {}

---@param err? DweProblem
local function fail(err)
	if err then
		view.failure(err)
	end
end
M.fail = fail

---Replaces the current workspace session while optionally retaining the visible tree.
---@param resolved string
---@param retain_tree? boolean
function M.start(resolved, retain_tree)
	if context.selector then
		context.selector:invalidate(true)
	end
	local clear_retained_marks = retain_tree
		and context.tree
		and (
			(context.tree.marks and next(context.tree.marks) ~= nil)
			or (context.tree.decorations and next(context.tree.decorations) ~= nil)
		)
	if context.mutations then
		context.mutations:invalidate()
	end
	if context.editing then
		context.editing:invalidate()
	end
	if context.git_status then
		context.git_status:invalidate()
	end
	if clear_retained_marks then
		view.render(context.tree)
	end
	if context.tree then
		context.tree:stop("session_replaced", true)
	end
	context.target, context.initial_failed, context.terminal_failed = resolved, false, false
	if not retain_tree then
		context.has_good = false
		view.loading()
	end

	local current, current_mutations, current_selector, current_editing, current_git
	local loaded, git_after_revision
	current = Workspace.new({
		command = config.get().command,
		target = context.target,
		git_enabled = config.get().git.enable,
		on_change = function(state)
			if current == context.tree then
				current_editing:reconcile()
				loaded, context.initial_failed, context.terminal_failed, context.has_good =
					true, false, false, true
				if current_selector and current_selector:is_engaged() then
					current_selector:workspace_changed(state.revision)
					return
				end
				view.render(state)
				if current_git then
					current_git:start()
					if git_after_revision and state.revision >= git_after_revision then
						git_after_revision = nil
						current_git:request()
					end
				end
			end
		end,
		on_error = function(err)
			if current == context.tree then
				context.initial_failed, context.terminal_failed = not loaded, current:is_terminal()
				fail(err)
			end
		end,
		on_notification = function(method, parameters)
			if current == context.tree and current_selector == context.selector then
				current_selector:notification(method, parameters)
			end
			if current == context.tree and current_mutations == context.mutations then
				current_mutations:notification(method, parameters)
			end
		end,
	})

	current_selector = Selector.new({
		workspace = current,
		is_live = function()
			return current == context.tree and current_selector == context.selector
		end,
		on_enter = function(active_selector)
			if current == context.tree and current_selector == context.selector then
				view.enter_selector(active_selector, context.actions, current)
			end
		end,
		on_render = function(active_selector)
			if current == context.tree and current_selector == context.selector then
				view.render_selector(active_selector)
			end
		end,
		on_leave = function()
			if current == context.tree and current_selector == context.selector then
				view.leave_selector(current)
			end
		end,
		on_selected = view.selected_selector,
		on_suspend = function()
			current:defer_reconciliation()
		end,
		on_resume = function(revision)
			if revision then
				git_after_revision = revision
			end
			current:resume_reconciliation(revision)
		end,
		on_error = fail,
		on_success = function() end,
	})

	current_mutations = Mutations.new({
		workspace = current,
		is_live = function()
			return current == context.tree and current_mutations == context.mutations
		end,
		selected = function()
			return view.selected(current)
		end,
		on_error = fail,
		on_refresh = function(revision)
			if current == context.tree and current_mutations == context.mutations then
				git_after_revision = revision
				current:mutation_completed(revision)
			end
		end,
		on_add_existing = function(options)
			if current == context.tree and current_selector == context.selector then
				current_selector:start(options)
			end
		end,
	})

	current_editing = Editing.new({
		workspace = current,
		is_live = function()
			return current == context.tree and current_editing == context.editing
		end,
		selected = function()
			return view.selected(current)
		end,
		on_error = fail,
		on_render = function()
			if current == context.tree then
				view.render(current)
			end
		end,
		on_success = function(revision)
			if current == context.tree and current_editing == context.editing then
				git_after_revision = revision
				current:mutation_completed(revision)
			end
		end,
	})

	if current.git_enabled then
		current_git = Git.new({
			workspace = current,
			is_live = function()
				return current == context.tree and current_git == context.git_status
			end,
			on_error = fail,
			on_render = function()
				if current == context.tree then
					view.render(current)
				end
			end,
		})
	end

	context.tree, context.mutations, context.selector, context.editing, context.git_status =
		current, current_mutations, current_selector, current_editing, current_git
	context.tree:start(function(err)
		if err and current == context.tree then
			context.initial_failed, context.terminal_failed = not loaded, current:is_terminal()
			fail(err)
		end
	end)
end

---Validates and applies plugin configuration.
---@param options? DweConfigInput
function M.setup(options)
	config.setup(options)
	if context.git_status and not config.get().git.enable then
		context.git_status:disable(true)
	end
	view.mappings(context.actions)
end

---Opens or switches the explorer to a target workspace path.
---@param requested? string
function M.open(requested)
	local ok, resolved = pcall(function()
		return requested or config.get().target()
	end)
	if not ok or type(resolved) ~= "string" or resolved == "" then
		return view.failure({ message = ok and "The workspace target is invalid." or resolved })
	end
	view.open()
	view.mappings(context.actions)
	if context.tree and context.target == resolved then
		if not context.initial_failed and not context.terminal_failed then
			view.render(context.tree)
		end
		return
	end
	M.start(resolved)
end

---Closes selector mode first, otherwise tears down the explorer session and window.
function M.close()
	if context.selector and context.selector:is_engaged() then
		return context.selector:cancel()
	end
	view.close()
	if context.mutations then
		context.mutations:invalidate()
	end
	if context.selector then
		context.selector:invalidate(true)
	end
	if context.editing then
		context.editing:invalidate()
	end
	if context.git_status then
		context.git_status:invalidate()
	end
	if context.tree then
		context.tree:stop("explorer_closed")
	end
	context.tree, context.mutations, context.selector, context.editing, context.git_status =
		nil, nil, nil, nil, nil
	context.target, context.initial_failed, context.terminal_failed, context.has_good =
		nil, nil, nil, nil
end

---@param requested? string
function M.toggle(requested)
	if view.is_open() then
		return M.close()
	end
	M.open(requested)
	view.focus()
end

function M.focus()
	view.focus()
end

---Refreshes the active workspace, recreating the session after terminal/configuration changes.
function M.refresh()
	if not context.tree then
		return view.failure({ message = "Open the workspace explorer before refreshing." })
	end
	if context.selector and context.selector:is_engaged() then
		context.selector:cancel()
	end
	if context.initial_failed or context.terminal_failed then
		return M.start(context.target, context.has_good)
	end
	if
		context.tree.git_enabled ~= config.get().git.enable
		or (
			config.get().git.enable
			and (not context.git_status or not context.git_status:is_enabled())
		)
	then
		return M.start(context.target, true)
	end
	view.selected(context.tree)
	context.tree:refresh(fail)
end

return M
