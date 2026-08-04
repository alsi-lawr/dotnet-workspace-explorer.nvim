vim.opt.runtimepath:prepend(vim.fn.getcwd())

local Workspace = require("dotnet-workspace-explorer.workspace").Workspace
local view = require("dotnet-workspace-explorer.view")

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
		on_change = function(current)
			view.render(current)
		end,
		on_error = function() end,
	}, { __index = Workspace })
	tree.client = {
		generation = 3,
		inert = false,
		limits = { maxPageSize = 1 },
		request = function(_, method, parameters, callback)
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
	return tree
end

local function rendered()
	return table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), "\n")
end

view.open()

do
	local tree = tree_harness(false)
	local problem
	tree:expand_all(function(err)
		problem = err
	end)
	assert_equal(nil, problem, "Expand All succeeds")
	local expanded = rendered()
	for _, name in ipairs({
		"Example.slnx",
		"Example.fsproj",
		"Program.fs",
		"Dependencies",
		"FSharp.Core",
		"Version: 10.0.0",
	}) do
		assert(expanded:find(name, 1, true), "Expand All omitted " .. name)
	end

	tree:collapse_all()
	local collapsed = rendered()
	assert(collapsed:find("Example.slnx", 1, true), "Collapse All removed the root")
	assert(not collapsed:find("Example.fsproj", 1, true), "Collapse All left descendants visible")
end

do
	local tree = tree_harness(true)
	view.render(tree)
	local before = rendered()
	local problem
	tree:expand_all(function(err)
		problem = err
	end)
	assert_equal("stale_tree", problem.code, "stale tree rejects Expand All")
	assert_equal(before, rendered(), "failed Expand All changes the visible tree")
end

do
	local resolved_path = vim.fs.abspath(vim.fn.tempname() .. ".fs")
	local file = node("file", "projectFile", "Program.fs", "project")
	local tree = setmetatable({
		nodes = { file = file },
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
			callback(nil, { revision = 7, targetNodeId = "file", path = resolved_path })
		end,
		_terminate = function(_, reason)
			error(reason.message)
		end,
	}
	local resolved
	tree:resolve_file("file", function(err, path)
		assert_equal(nil, err, "file resolution error")
		resolved = path
	end)
	assert_equal({
		"workspace/file/resolve",
		{ targetNodeId = "file", expectedRevision = 7 },
	}, request, "exact file resolution request")
	assert_equal(resolved_path, resolved, "authoritative file path")
end

view.close()
print("DWE whole-tree action probe passed")
