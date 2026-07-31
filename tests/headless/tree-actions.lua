vim.opt.runtimepath:prepend(vim.fn.getcwd())

local Workspace = require("dotnet-workspace-explorer.workspace").Workspace

local function assert_equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(
			("%s\nexpected: %s\nactual: %s"):format(message, vim.inspect(expected), vim.inspect(actual))
		)
	end
end

local function node(id, kind, name, parent)
	return {
		id = id,
		parent_id = parent,
		kind = kind,
		name = name,
		load_state = "loaded",
		capabilities = {},
		revision = 7,
	}
end

local function wire_node(value)
	return {
		workspaceId = "workspace-id",
		revision = 7,
		id = value.id,
		kind = value.kind,
		name = value.name,
		loadState = value.load_state,
		capabilities = {},
	}
end

local function tree_harness(fail_during_children)
	local changes, calls = 0, {}
	local workspace_node = node("workspace", "workspace", "Example.slnx")
	local project = node("project", "project", "Example.fsproj", "workspace")
	local file = node("file", "projectFile", "Program.fs", "project")
	local dependencies = node("dependencies", "dependencyContainer", "Dependencies", "project")
	local dependency = node("dependency", "dependency", "FSharp.Core", "dependencies")
	local property = node("property", "dependencyProperty", "Version: 10.0.0", "dependency")
	local tree = setmetatable({
		nodes = { workspace = vim.deepcopy(workspace_node) },
		children = {},
		loading = {},
		roots = { "workspace" },
		expanded = {},
		epoch = 0,
		phase = "ready",
		reconcile_waiters = {},
		revision = 7,
		workspace_id = "workspace-id",
		selected_id = "workspace",
		on_change = function()
			changes = changes + 1
		end,
		on_error = function() end,
	}, { __index = Workspace })
	tree.client = {
		generation = 3,
		inert = false,
		limits = { maxPageSize = 1 },
		request = function(_, method, parameters, callback)
			calls[#calls + 1] = { method, vim.deepcopy(parameters) }
			if method == "workspace/root" then
				return callback(nil, { revision = 7, nodes = { wire_node(workspace_node) } })
			end
			if fail_during_children then
				tree.epoch = tree.epoch + 1
				return callback(nil, {
					revision = 7,
					parentNodeId = parameters.parentNodeId,
					nodes = {},
				})
			end
			local pages = {
				workspace = {
					[""] = { nodes = { project } },
				},
				project = {
					[""] = { nodes = { file }, nextToken = "project-page-2" },
					["project-page-2"] = { nodes = { dependencies } },
				},
				dependencies = {
					[""] = { nodes = { dependency } },
				},
				dependency = {
					[""] = { nodes = { property } },
				},
			}
			local page = pages[parameters.parentNodeId][parameters.continuationToken or ""]
			local result = {
				revision = 7,
				parentNodeId = parameters.parentNodeId,
				nodes = {},
				nextToken = page.nextToken,
			}
			for _, child in ipairs(page.nodes) do
				result.nodes[#result.nodes + 1] = wire_node(child)
			end
			callback(nil, result)
		end,
		_terminate = function(_, reason)
			error(reason.message)
		end,
	}
	return tree, function()
		return changes
	end, calls
end

do
	local tree, changes, calls = tree_harness(false)
	local problem
	tree:expand_all(function(err)
		problem = err
	end)
	assert_equal(nil, problem, "ExpandAll succeeds")
	assert_equal(1, changes(), "ExpandAll swaps the tree once")
	assert_equal({
		workspace = true,
		project = true,
		dependencies = true,
		dependency = true,
	}, tree.expanded, "ExpandAll includes dependency property ancestry")
	assert_equal({ "file", "dependencies" }, tree.children.project, "ExpandAll collects every page")
	assert_equal("property", tree.children.dependency[1], "ExpandAll hydrates dependency properties")
	assert_equal("project-page-2", calls[4][2].continuationToken, "continuation is requested")

	tree:collapse_all()
	assert_equal({}, tree.expanded, "CollapseAll clears every expansion")
	assert_equal(2, changes(), "CollapseAll renders once")
end

do
	local tree, changes = tree_harness(true)
	local original = vim.deepcopy(tree.nodes)
	local problem
	tree:expand_all(function(err)
		problem = err
	end)
	assert_equal("stale_tree", problem.code, "generation change rejects ExpandAll")
	assert_equal(original, tree.nodes, "failed ExpandAll preserves last-good nodes")
	assert_equal(0, changes(), "failed ExpandAll does not render")
end

for _, extension in ipairs({ "csproj", "fsproj", "vbproj" }) do
	local project_path = vim.fs.abspath(vim.fn.tempname() .. "." .. extension)
	local project = node("project", "project", "Example." .. extension)
	local tree = setmetatable({
		nodes = { project = project },
		epoch = 0,
		revision = 7,
		workspace_id = "workspace-id",
	}, { __index = Workspace })
	local request
	tree.client = {
		generation = 1,
		inert = false,
		request = function(_, method, parameters, callback)
			request = { method, vim.deepcopy(parameters) }
			callback(nil, { revision = 7, targetNodeId = "project", path = project_path })
		end,
		_terminate = function(_, reason)
			error(reason.message)
		end,
	}
	local resolved
	tree:resolve_project("project", function(err, path)
		assert_equal(nil, err, extension .. " project resolution")
		resolved = path
	end)
	assert_equal({
		"workspace/file/resolve",
		{ targetNodeId = "project", expectedRevision = 7 },
	}, request, extension .. " exact project resolve request")
	assert_equal(project_path, resolved, extension .. " authoritative project path")
end

print("DWE whole-tree action probe passed")
