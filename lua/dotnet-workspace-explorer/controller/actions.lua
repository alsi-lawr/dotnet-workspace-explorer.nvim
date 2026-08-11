local config = require("dotnet-workspace-explorer.config")
local context = require("dotnet-workspace-explorer.controller.context")
local session = require("dotnet-workspace-explorer.controller.session")
local view = require("dotnet-workspace-explorer.ui.view")

local M = {}

---@param target unknown
---@return true?, string?
local function launch_packages(target)
	if type(target) ~= "string" or not target:find("%S") then
		return session.fail({ message = "Choose a nonblank Package Explorer target." })
	end
	local package_command = config.get().package_command
	return require("dotnet-workspace-explorer.package_terminal").open(
		{ package_command, target },
		target
	)
end

---@param tree DweWorkspaceTree
---@param project_id DweNodeId
local function launch_project_packages(tree, project_id)
	tree:resolve_project(project_id, function(err, path)
		if context.tree ~= tree or tree.phase ~= "ready" then
			return session.fail({
				code = "stale_tree",
				message = "The workspace changed before Package Explorer could open. Try again.",
			})
		end
		if err then
			return session.fail(err)
		end
		launch_packages(path)
	end)
end

---@param tree DweWorkspaceTree
---@param id DweNodeId
---@return DweNodeId?
local function owning_project(tree, id)
	local seen = {}
	local parent_id = tree:parent(id)
	while parent_id and not seen[parent_id] do
		seen[parent_id] = true
		local parent = tree:get_node(parent_id)
		if not parent then
			return nil
		end
		if parent.kind == "project" then
			return parent_id
		end
		parent_id = tree:parent(parent_id)
	end
end

---@param action fun(id: DweNodeId)
local function with_container(action)
	local id = context.tree and view.selected(context.tree)
	if not id or not context.tree:is_expandable(id) then
		return view.failure({ message = "The selected node is not expandable." })
	end
	action(id)
end

function M.expand()
	if context.selector and context.selector:is_engaged() then
		return context.selector:expand()
	end
	with_container(function(id)
		context.tree:expand(id, session.fail)
	end)
end

function M.collapse()
	if context.selector and context.selector:is_engaged() then
		return context.selector:collapse()
	end
	with_container(function(id)
		context.tree:collapse(id)
	end)
end

function M.expand_all()
	if not context.tree then
		return session.fail({ message = "Open the workspace explorer before expanding it." })
	end
	view.selected(context.tree)
	context.tree:expand_all(session.fail)
end

function M.collapse_all()
	if not context.tree then
		return session.fail({ message = "Open the workspace explorer before collapsing it." })
	end
	view.selected(context.tree)
	context.tree:collapse_all()
end

---Activates the selected tree or selector entry.
function M.activate()
	if context.selector and context.selector:is_engaged() then
		return context.selector:activate()
	end
	local id = context.tree and view.selected(context.tree)
	local node = id and context.tree:get_node(id)
	if not id or not node then
		return session.fail({ message = "Select a workspace node before activating it." })
	end
	if context.tree:is_expandable(id) then
		if context.tree.expanded[id] then
			context.tree:collapse(id)
		else
			context.tree:expand(id, session.fail)
		end
	elseif node.kind == "projectFile" or node.kind == "solutionItem" then
		context.tree:resolve_file(id, function(err, path)
			if err then
				return session.fail(err)
			end
			local opened, open_error = view.open_file(path)
			if not opened and open_error then
				session.fail({ message = open_error })
			end
		end)
	else
		session.fail({ message = "The selected node cannot be opened." })
	end
end

---Opens the selected project's project file.
function M.edit()
	local id = context.tree and view.selected(context.tree)
	local node = id and context.tree:get_node(id)
	if not id or not node or node.kind ~= "project" then
		return session.fail({ message = "Select a project before editing its project file." })
	end
	context.tree:resolve_project(id, function(err, path)
		if err then
			return session.fail(err)
		end
		local opened, open_error = view.open_file(path)
		if not opened and open_error then
			session.fail({ message = open_error })
		end
	end)
end

function M.new()
	if context.selector and context.selector:is_engaged() then
		return
	end
	if not context.mutations then
		return session.fail({ message = "Open the workspace explorer before creating an item." })
	end
	context.mutations:create()
end

function M.delete()
	if not context.mutations then
		return session.fail({ message = "Open the workspace explorer before deleting an item." })
	end
	context.mutations:delete()
end

function M.rename()
	if not context.editing then
		return session.fail({ message = "Open the workspace explorer before renaming an item." })
	end
	context.editing:rename()
end

function M.mark_move()
	if not context.editing then
		return session.fail({ message = "Open the workspace explorer before marking an item." })
	end
	context.editing:toggle("move")
end

function M.mark_copy()
	if not context.editing then
		return session.fail({ message = "Open the workspace explorer before marking an item." })
	end
	context.editing:toggle("copy")
end

function M.place()
	if not context.editing then
		return session.fail({ message = "Open the workspace explorer before placing marked items." })
	end
	context.editing:place()
end

function M.clear_marks()
	if context.editing then
		context.editing:clear()
	end
end

function M.git_refresh()
	if not config.get().git.enable then
		return session.fail({
			message = "Enable git.enable and refresh the workspace before requesting Git status.",
		})
	end
	if not context.git_status or not context.git_status:is_enabled() then
		return session.fail({
			message = "Refresh the workspace to enable Git status for this session.",
		})
	end
	context.git_status:request()
end

---Opens Package Explorer for an explicit target or the supported selected workspace context.
---@param requested? string
function M.packages(requested)
	if requested ~= nil then
		return launch_packages(requested)
	end
	if context.selector and context.selector:is_engaged() then
		return session.fail({ message = "Close Add Existing before opening Package Explorer." })
	end

	local tree = context.tree
	if not tree or tree.phase ~= "ready" then
		return session.fail({
			message = "Open a ready workspace explorer before opening Package Explorer.",
		})
	end
	local id = view.selected(tree)
	local node = id and tree:get_node(id)
	if not id or not node then
		return session.fail({
			message = "Select a workspace, project, or Dependencies node for Package Explorer.",
		})
	end

	if node.kind == "workspace" and not node.parent_id then
		return launch_packages(context.target)
	end
	if node.kind == "project" then
		return launch_project_packages(tree, id)
	end
	if node.kind == "dependencyContainer" then
		local project_id = owning_project(tree, id)
		if not project_id then
			return session.fail({
				message = "The selected Dependencies node has no owning project.",
			})
		end
		return launch_project_packages(tree, project_id)
	end
	return session.fail({
		message = "Select a workspace root, project, or Dependencies node for Package Explorer.",
	})
end

---Terminates the active Package Explorer session, if one exists.
function M.packages_kill()
	return require("dotnet-workspace-explorer.package_terminal").kill()
end

return M
