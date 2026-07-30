local config = require("dotnet-workspace-explorer.config")
local view = require("dotnet-workspace-explorer.view")
local Workspace = require("dotnet-workspace-explorer.workspace").Workspace

local M = {}
local tree, target, initial_failed, terminal_failed, has_good
local function fail(err)
	if err then
		view.failure(err)
	end
end

local function start(resolved, retain_tree)
	if tree then
		tree:stop("session_replaced", true)
	end
	target, initial_failed, terminal_failed = resolved, false, false
	if not retain_tree then
		has_good = false
		view.loading()
	end
	local current, loaded
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
	})
	tree = current
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
	if tree then
		tree:stop("explorer_closed")
	end
	tree, target, initial_failed, terminal_failed, has_good = nil, nil, nil, nil, nil
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

local command_id = "project.item.new"
local function compatible_descriptor(result)
	local descriptor = type(result) == "table" and result.command
	if
		type(descriptor) ~= "table"
		or descriptor.id ~= command_id
		or descriptor.access ~= "write"
		or type(descriptor.parameters) ~= "table"
		or not vim.islist(descriptor.parameters)
		or type(descriptor.targetKinds) ~= "table"
		or not vim.islist(descriptor.targetKinds)
	then
		return
	end
	local required, targets = {}, {}
	for _, parameter in ipairs(descriptor.parameters) do
		if
			type(parameter) ~= "table"
			or type(parameter.id) ~= "string"
			or type(parameter.type) ~= "string"
			or type(parameter.required) ~= "boolean"
		then
			return
		end
		if parameter.required then
			required[parameter.id] = parameter.type
		end
	end
	for _, kind in ipairs(descriptor.targetKinds) do
		targets[kind] = true
	end
	return targets.project
		and required.path == "path"
		and required.itemType == "choice"
		and vim.tbl_count(required) == 2
		and descriptor
end

local function project_for(id)
	while id do
		local node = tree:get_node(id)
		if node and node.kind == "project" then
			return id
		end
		id = tree:parent(id)
	end
end

local function create_file(path)
	if type(path) ~= "string" or path == "" then
		return
	end
	if not tree then
		return fail({ message = "Open the workspace explorer before adding a file." })
	end
	local session, project = tree, project_for(view.selected(tree))
	if not project then
		return fail({ message = "Select a project before adding a file." })
	end
	for _, capability in ipairs({
		"workspace.commands.describe",
		"workspace.commands.preview",
		"workspace.commands.execute",
	}) do
		if not session:has_capability(capability) then
			return fail({ message = "The workspace does not support adding project items." })
		end
	end
	session:request("workspace/commands/describe", {
		commandId = command_id,
		targetNodeId = project,
	}, function(describe_error, result)
		if describe_error then
			return fail(describe_error)
		end
		local descriptor = compatible_descriptor(result)
		if not descriptor then
			return fail({ message = "The add-file command descriptor is incompatible." })
		end
		local captured = {
			descriptor = descriptor,
			request = {
				commandId = command_id,
				targetNodeId = project,
				arguments = {
					path = path,
					itemType = config.get().actions.add_file.item_type,
				},
				expectedRevision = session.revision,
			},
		}
		session:request("workspace/commands/preview", captured.request, function(preview_error, preview)
			if preview_error then
				return fail(preview_error)
			end
			local token = type(preview) == "table" and preview.confirmationToken
			if type(token) ~= "string" or token == "" then
				return fail({ message = "The add-file preview is incompatible." })
			end
			vim.ui.select({ "Create", "Cancel" }, { prompt = "Create " .. path .. "?" }, function(choice)
				if choice ~= "Create" then
					return
				end
				local execute = vim.deepcopy(captured.request)
				execute.confirmationToken = token
				session:request("workspace/commands/execute", execute, function(execute_error, applied)
					if execute_error then
						return fail(execute_error)
					end
					if
						type(applied) ~= "table"
						or applied.applied ~= true
						or type(applied.revision) ~= "number"
						or applied.revision < 0
						or applied.revision % 1 ~= 0
					then
						return fail({ message = "The add-file result is incompatible." })
					end
					if session == tree then
						M.refresh()
					end
				end)
			end)
		end)
	end)
end

function M.add_file(path)
	if not tree then
		return fail({ message = "Open the workspace explorer before adding a file." })
	end
	if path ~= nil then
		return create_file(path)
	end
	vim.ui.input({ prompt = "Solution-relative or absolute path: " }, function(value)
		create_file(value)
	end)
end

function M._register_commands()
	require("dotnet-workspace-explorer.commands").register()
end

return M
