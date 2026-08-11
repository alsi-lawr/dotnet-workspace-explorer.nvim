vim.opt.runtimepath:prepend(vim.fn.getcwd())

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

local terminal_calls = {}
package.loaded["dotnet-workspace-explorer.package_terminal"] = {
	open = function(argv, target)
		terminal_calls[#terminal_calls + 1] = {
			kind = "open",
			argv = vim.deepcopy(argv),
			target = target,
		}
		return true
	end,
	kill = function()
		terminal_calls[#terminal_calls + 1] = { kind = "kill" }
	end,
}

local public = require("dotnet-workspace-explorer")
local context = require("dotnet-workspace-explorer.controller.context")
local Workspace = require("dotnet-workspace-explorer.workspace").Workspace

local notifications = {}
local original_notify = vim.notify
vim.notify = function(message, level)
	notifications[#notifications + 1] = { message = message, level = level }
end

local function node(id, kind, parent)
	return {
		id = id,
		parent_id = parent,
		kind = kind,
		name = id,
		load_state = "loaded",
		capabilities = {},
		revision = 7,
	}
end

local function basic_tree(selected_id, nodes)
	return setmetatable({
		nodes = nodes,
		selected_id = selected_id,
		phase = "ready",
	}, { __index = Workspace })
end

local function resolving_tree(selected_id, request_handler)
	local nodes = {
		root = node("root", "workspace"),
		project = node("project", "project", "root"),
		dependencies = node("dependencies", "dependencyContainer", "project"),
	}
	local tree = basic_tree(selected_id, nodes)
	tree.epoch = 2
	tree.revision = 7
	tree.workspace_id = "workspace-id"
	tree._invalidate = function(self)
		self.invalidated = true
	end
	tree.client = {
		generation = 3,
		inert = false,
		request = function(_, method, parameters, callback)
			request_handler(method, vim.deepcopy(parameters), callback, tree)
		end,
		_terminate = function(_, problem)
			tree.termination = problem
		end,
	}
	return tree
end

local function reset_context(tree, target)
	context.tree = tree
	context.target = target
	context.selector = nil
	notifications = {}
end

local function assert_no_new_terminal(before, message)
	assert_equal(before, #terminal_calls, message)
end

public.setup({ package_command = "configured-dotnet-pe" })

local explicit = "/tmp/project with spaces;$(not-a-shell).fsproj"
reset_context(nil, nil)
assert(public.packages(explicit), "explicit Package Explorer target was rejected")
assert_equal({
	kind = "open",
	argv = { "configured-dotnet-pe", explicit },
	target = explicit,
}, terminal_calls[1], "explicit target handoff")

local before = #terminal_calls
public.packages(" \t ")
assert_no_new_terminal(before, "blank explicit target reached the terminal owner")
assert(
	notifications[#notifications].message:find("nonblank", 1, true),
	"blank target rejection was not actionable"
)

public.packages_kill()
local replacement = "/tmp/replacement.fsproj"
assert(public.packages(replacement), "immediate post-Kill replacement was rejected")
assert_equal({ kind = "kill" }, terminal_calls[2], "public Kill handoff")
assert_equal({
	kind = "open",
	argv = { "configured-dotnet-pe", replacement },
	target = replacement,
}, terminal_calls[3], "immediate replacement handoff")

local root_target = "/tmp/workspace root;literal$.slnx"
local root_tree = basic_tree("root", { root = node("root", "workspace") })
reset_context(root_tree, root_target)
assert(public.packages(), "workspace root launch was rejected")
assert_equal({
	kind = "open",
	argv = { "configured-dotnet-pe", root_target },
	target = root_target,
}, terminal_calls[4], "workspace root target handoff")

local project_path = vim.fs.abspath(vim.fn.tempname() .. " project.fsproj")
local project_request
local project_tree = resolving_tree("project", function(method, parameters, callback)
	project_request = { method, parameters }
	callback(nil, { revision = 7, targetNodeId = "project", path = project_path })
end)
reset_context(project_tree, root_target)
public.packages()
assert_equal({
	"workspace/file/resolve",
	{ targetNodeId = "project", expectedRevision = 7 },
}, project_request, "project resolver request")
assert_equal({
	kind = "open",
	argv = { "configured-dotnet-pe", project_path },
	target = project_path,
}, terminal_calls[5], "resolved project target handoff")

local dependency_request
local dependency_tree = resolving_tree("dependencies", function(method, parameters, callback)
	dependency_request = { method, parameters }
	callback(nil, { revision = 7, targetNodeId = "project", path = project_path })
end)
reset_context(dependency_tree, root_target)
public.packages()
assert_equal({
	"workspace/file/resolve",
	{ targetNodeId = "project", expectedRevision = 7 },
}, dependency_request, "Dependencies owning-project resolver request")
assert_equal(
	project_path,
	terminal_calls[6].target,
	"Dependencies did not use the resolved project"
)

local selector_race_callback
local selector_race_tree = resolving_tree("dependencies", function(_, _, callback)
	selector_race_callback = callback
end)
reset_context(selector_race_tree, root_target)
before = #terminal_calls
public.packages()
context.selector = {
	is_engaged = function()
		return true
	end,
}
selector_race_callback(nil, {
	revision = 7,
	targetNodeId = "project",
	path = project_path,
})
assert_no_new_terminal(before, "selector engaged during resolution reached the terminal owner")
assert(
	notifications[#notifications].message:find("Close Add Existing", 1, true),
	"callback-time selector rejection was not actionable"
)

local selector_tree = basic_tree("root", { root = node("root", "workspace") })
reset_context(selector_tree, root_target)
context.selector = {
	is_engaged = function()
		return true
	end,
}
before = #terminal_calls
public.packages()
assert_no_new_terminal(before, "selector mode reached the terminal owner")
assert(
	notifications[#notifications].message:find("Close Add Existing", 1, true),
	"selector rejection was not actionable"
)

reset_context(nil, root_target)
before = #terminal_calls
public.packages()
assert_no_new_terminal(before, "missing explorer used an implicit target fallback")

local stale_tree = basic_tree("root", { root = node("root", "workspace") })
stale_tree.phase = "stopped"
reset_context(stale_tree, root_target)
before = #terminal_calls
public.packages()
assert_no_new_terminal(before, "stopped tree reached the terminal owner")

local missing_tree = basic_tree(nil, { root = node("root", "workspace") })
reset_context(missing_tree, root_target)
before = #terminal_calls
public.packages()
assert_no_new_terminal(before, "missing selection reached the terminal owner")

local unsupported_tree = basic_tree("file", {
	root = node("root", "workspace"),
	file = node("file", "projectFile", "root"),
})
reset_context(unsupported_tree, root_target)
before = #terminal_calls
public.packages()
assert_no_new_terminal(before, "unsupported selection reached the terminal owner")

local orphan_tree = basic_tree("dependencies", {
	dependencies = node("dependencies", "dependencyContainer", "missing-parent"),
})
reset_context(orphan_tree, root_target)
before = #terminal_calls
public.packages()
assert_no_new_terminal(before, "broken Dependencies ancestry reached the terminal owner")
assert(
	notifications[#notifications].message:find("no owning project", 1, true),
	"broken ancestry rejection was not actionable"
)

local conflict_tree = resolving_tree("project", function(_, _, callback)
	callback({ code = "workspace_conflict", message = "exact workspace conflict" })
end)
reset_context(conflict_tree, root_target)
before = #terminal_calls
public.packages()
assert_no_new_terminal(before, "resolver conflict reached the terminal owner")
assert(conflict_tree.invalidated, "resolver conflict did not invalidate its tree")
assert_equal("exact workspace conflict", notifications[#notifications].message, "conflict error")

local incompatible_tree = resolving_tree("project", function(_, _, callback)
	callback(nil, {
		revision = 7,
		targetNodeId = "project",
		path = vim.fs.abspath(vim.fn.tempname() .. ".txt"),
	})
end)
reset_context(incompatible_tree, root_target)
before = #terminal_calls
public.packages()
assert_no_new_terminal(before, "incompatible project resolution reached the terminal owner")
assert_equal(
	"invalid_file_resolution",
	incompatible_tree.termination.code,
	"incompatible project resolution did not terminate its workspace client"
)

local delayed_callback
local delayed_tree = resolving_tree("project", function(_, _, callback)
	delayed_callback = callback
end)
reset_context(delayed_tree, root_target)
before = #terminal_calls
public.packages()
context.tree = basic_tree("root", { root = node("root", "workspace") })
delayed_callback(nil, { revision = 7, targetNodeId = "project", path = project_path })
assert_no_new_terminal(before, "replaced tree callback reached the terminal owner")
assert(
	notifications[#notifications].message:find("workspace changed", 1, true),
	"replaced tree callback was not reported as stale"
)

local generation_callback
local generation_tree = resolving_tree("project", function(_, _, callback)
	generation_callback = callback
end)
reset_context(generation_tree, root_target)
before = #terminal_calls
public.packages()
generation_tree.client.generation = generation_tree.client.generation + 1
generation_callback(nil, { revision = 7, targetNodeId = "project", path = project_path })
assert_no_new_terminal(before, "stale resolver generation reached the terminal owner")
assert(
	notifications[#notifications].message:find("tree changed", 1, true),
	"stale resolver generation was not reported"
)

local invalid_tree = basic_tree("project", { project = node("project", "project") })
invalid_tree.resolve_project = function(_, _, callback)
	callback(nil, "  ")
end
reset_context(invalid_tree, root_target)
before = #terminal_calls
public.packages()
assert_no_new_terminal(before, "blank resolver target reached the terminal owner")
assert(
	notifications[#notifications].message:find("nonblank", 1, true),
	"blank resolver target was not reported"
)

context.tree, context.target, context.selector = nil, nil, nil
vim.notify = original_notify
print("DWE-026 package launch probe passed")
