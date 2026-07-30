local config = require("dotnet-workspace-explorer.config")
local view = require("dotnet-workspace-explorer.view")
local Workspace = require("dotnet-workspace-explorer.workspace").Workspace

local M = {}
local tree, target
local function fail(err)
	if err then
		view.failure(err)
	end
end

function M.setup(options)
	config.setup(options)
end

function M.open(requested)
	local ok, resolved = pcall(function()
		return requested or config.get().target()
	end)
	if not ok or type(resolved) ~= "string" or resolved == "" then
		return view.failure({ message = ok and "The workspace target is invalid." or resolved })
	end
	view.open()
	if tree and target == resolved then
		return view.render(tree)
	end
	if tree then
		tree:stop("target_replaced", true)
	end
	target = resolved
	view.loading()
	tree = Workspace.new({
		command = config.get().command,
		target = target,
		on_change = view.render,
		on_error = fail,
	})
	tree:start(fail)
end

function M.close()
	view.close()
	if tree then
		tree:stop("explorer_closed")
	end
	tree, target = nil, nil
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

function M._register_commands()
	require("dotnet-workspace-explorer.commands").register()
end

return M
