local config = require("dotnet-workspace-explorer.config")
local Mutations = require("dotnet-workspace-explorer.mutations").Mutations
local view = require("dotnet-workspace-explorer.view")
local Workspace = require("dotnet-workspace-explorer.workspace").Workspace

local M = {}
local tree, mutations, target, initial_failed, terminal_failed, has_good
local function fail(err)
	if err then
		view.failure(err)
	end
end

local function start(resolved, retain_tree)
	if mutations then
		mutations:invalidate()
	end
	if tree then
		tree:stop("session_replaced", true)
	end
	target, initial_failed, terminal_failed = resolved, false, false
	if not retain_tree then
		has_good = false
		view.loading()
	end
	local current, current_mutations, loaded
	current = Workspace.new({
		command = config.get().command,
		target = target,
		on_change = function(state)
			if current == tree then
				loaded, initial_failed, terminal_failed, has_good = true, false, false, true
				view.render(state)
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
				current:mutation_completed(revision)
			end
		end,
	})
	tree, mutations = current, current_mutations
	tree:start(function(err)
		if err and current == tree then
			initial_failed, terminal_failed = not loaded, current:is_terminal()
			fail(err)
		end
	end)
end

function M.setup(options)
	config.setup(options)
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
	if tree then
		tree:stop("explorer_closed")
	end
	tree, mutations, target, initial_failed, terminal_failed, has_good = nil, nil, nil, nil, nil, nil
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
	view.selected(tree)
	tree:refresh(fail)
end

local function with_container(action)
	local id = tree and view.selected(tree)
	if not id or not tree:is_expandable(id) then
		return view.failure({ message = "Core path resolution is unavailable for this node." })
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

function M.activate()
	with_container(function(id)
		if tree.expanded[id] then
			tree:collapse(id)
		else
			tree:expand(id, fail)
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

function M._register_commands()
	require("dotnet-workspace-explorer.commands").register()
end

return M
