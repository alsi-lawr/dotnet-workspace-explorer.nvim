local config = require("dotnet-workspace-explorer.config")
local Editing = require("dotnet-workspace-explorer.editing").Editing
local Git = require("dotnet-workspace-explorer.git").Git
local Mutations = require("dotnet-workspace-explorer.mutations").Mutations
local view = require("dotnet-workspace-explorer.view")
local Workspace = require("dotnet-workspace-explorer.workspace").Workspace

local M = {}
local tree, mutations, editing, git_status, target, initial_failed, terminal_failed, has_good
local function fail(err)
	if err then
		view.failure(err)
	end
end

local function start(resolved, retain_tree)
	local clear_retained_marks = retain_tree
		and tree
		and (
			(tree.marks and next(tree.marks) ~= nil)
			or (tree.decorations and next(tree.decorations) ~= nil)
		)
	if mutations then
		mutations:invalidate()
	end
	if editing then
		editing:invalidate()
	end
	if git_status then
		git_status:invalidate()
	end
	if clear_retained_marks then
		view.render(tree)
	end
	if tree then
		tree:stop("session_replaced", true)
	end
	target, initial_failed, terminal_failed = resolved, false, false
	if not retain_tree then
		has_good = false
		view.loading()
	end
	local current, current_mutations, current_editing, current_git, loaded, git_after_revision
	current = Workspace.new({
		command = config.get().command,
		target = target,
		git_enabled = config.get().git.enable,
		on_change = function(state)
			if current == tree then
				current_editing:reconcile()
				loaded, initial_failed, terminal_failed, has_good = true, false, false, true
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
			if current == tree then
				initial_failed, terminal_failed = not loaded, current:is_terminal()
				fail(err)
			end
		end,
		on_notification = function(method, parameters)
			if current == tree and current_mutations == mutations then
				current_mutations:notification(method, parameters)
			end
		end,
	})
	current_mutations = Mutations.new({
		workspace = current,
		is_live = function()
			return current == tree and current_mutations == mutations
		end,
		selected = function()
			return view.selected(current)
		end,
		on_error = fail,
		on_refresh = function(revision)
			if current == tree and current_mutations == mutations then
				git_after_revision = revision
				current:mutation_completed(revision)
			end
		end,
	})
	current_editing = Editing.new({
		workspace = current,
		is_live = function()
			return current == tree and current_editing == editing
		end,
		selected = function()
			return view.selected(current)
		end,
		on_error = fail,
		on_render = function()
			if current == tree then
				view.render(current)
			end
		end,
		on_success = function(revision)
			if current == tree and current_editing == editing then
				git_after_revision = revision
				current:mutation_completed(revision)
			end
		end,
	})
	if current.git_enabled then
		current_git = Git.new({
			workspace = current,
			is_live = function()
				return current == tree and current_git == git_status
			end,
			on_error = fail,
			on_render = function()
				if current == tree then
					view.render(current)
				end
			end,
		})
	end
	tree, mutations, editing, git_status = current, current_mutations, current_editing, current_git
	tree:start(function(err)
		if err and current == tree then
			initial_failed, terminal_failed = not loaded, current:is_terminal()
			fail(err)
		end
	end)
end

function M.setup(options)
	config.setup(options)
	if git_status and not config.get().git.enable then
		git_status:disable(true)
	end
	view.mappings(M)
end

function M.open(requested)
	local ok, resolved = pcall(function()
		return requested or config.get().target()
	end)
	if not ok or type(resolved) ~= "string" or resolved == "" then
		return view.failure({ message = ok and "The workspace target is invalid." or resolved })
	end
	view.open()
	view.mappings(M)
	if tree and target == resolved then
		if not initial_failed and not terminal_failed then
			view.render(tree)
		end
		return
	end
	start(resolved)
end

function M.close()
	view.close()
	if mutations then
		mutations:invalidate()
	end
	if editing then
		editing:invalidate()
	end
	if git_status then
		git_status:invalidate()
	end
	if tree then
		tree:stop("explorer_closed")
	end
	tree, mutations, editing, git_status, target, initial_failed, terminal_failed, has_good =
		nil, nil, nil, nil, nil, nil, nil, nil
end

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

function M.refresh()
	if not tree then
		return view.failure({ message = "Open the workspace explorer before refreshing." })
	end
	if initial_failed or terminal_failed then
		return start(target, has_good)
	end
	if
		tree.git_enabled ~= config.get().git.enable
		or (config.get().git.enable and (not git_status or not git_status:is_enabled()))
	then
		return start(target, true)
	end
	view.selected(tree)
	tree:refresh(fail)
end

local function with_container(action)
	local id = tree and view.selected(tree)
	if not id or not tree:is_expandable(id) then
		return view.failure({ message = "The selected node is not expandable." })
	end
	action(id)
end

function M.expand()
	with_container(function(id)
		tree:expand(id, fail)
	end)
end

function M.collapse()
	with_container(function(id)
		tree:collapse(id)
	end)
end

function M.expand_all()
	if not tree then
		return fail({ message = "Open the workspace explorer before expanding it." })
	end
	view.selected(tree)
	tree:expand_all(fail)
end

function M.collapse_all()
	if not tree then
		return fail({ message = "Open the workspace explorer before collapsing it." })
	end
	view.selected(tree)
	tree:collapse_all()
end

function M.activate()
	local id = tree and view.selected(tree)
	local node = id and tree:get_node(id)
	if not node then
		return fail({ message = "Select a workspace node before activating it." })
	end
	if tree:is_expandable(id) then
		if tree.expanded[id] then
			tree:collapse(id)
		else
			tree:expand(id, fail)
		end
	elseif node.kind == "projectFile" or node.kind == "solutionItem" then
		tree:resolve_file(id, function(err, path)
			if err then
				return fail(err)
			end
			local opened, open_error = view.open_file(path)
			if not opened then
				fail({ message = open_error })
			end
		end)
	else
		fail({ message = "The selected node cannot be opened." })
	end
end

function M.edit()
	local id = tree and view.selected(tree)
	local node = id and tree:get_node(id)
	if not node or node.kind ~= "project" then
		return fail({ message = "Select a project before editing its project file." })
	end
	tree:resolve_project(id, function(err, path)
		if err then
			return fail(err)
		end
		local opened, open_error = view.open_file(path)
		if not opened then
			fail({ message = open_error })
		end
	end)
end

function M.new()
	if not mutations then
		return fail({ message = "Open the workspace explorer before creating an item." })
	end
	mutations:create()
end

function M.delete()
	if not mutations then
		return fail({ message = "Open the workspace explorer before deleting an item." })
	end
	mutations:delete()
end

function M.rename()
	if not editing then
		return fail({ message = "Open the workspace explorer before renaming an item." })
	end
	editing:rename()
end

function M.mark_move()
	if not editing then
		return fail({ message = "Open the workspace explorer before marking an item." })
	end
	editing:toggle("move")
end

function M.mark_copy()
	if not editing then
		return fail({ message = "Open the workspace explorer before marking an item." })
	end
	editing:toggle("copy")
end

function M.place()
	if not editing then
		return fail({ message = "Open the workspace explorer before placing marked items." })
	end
	editing:place()
end

function M.clear_marks()
	if editing then
		editing:clear()
	end
end

function M.git_refresh()
	if not config.get().git.enable then
		return fail({
			message = "Enable git.enable and refresh the workspace before requesting Git status.",
		})
	end
	if not git_status or not git_status:is_enabled() then
		return fail({ message = "Refresh the workspace to enable Git status for this session." })
	end
	git_status:request()
end

function M._register_commands()
	require("dotnet-workspace-explorer.commands").register()
end

return M
