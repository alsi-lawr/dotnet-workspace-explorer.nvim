vim.opt.runtimepath:prepend(vim.fn.getcwd())

local delta = require("dotnet-workspace-explorer.workspace.delta")
local staging = require("dotnet-workspace-explorer.workspace.staging")
local Workspace = require("dotnet-workspace-explorer.workspace").Workspace

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

local function canonical_node(id, kind, name, parent_id, revision, load_state)
	return {
		id = id,
		parent_id = parent_id,
		kind = kind,
		name = name,
		load_state = load_state or "loaded",
		capabilities = {},
		revision = revision or 1,
	}
end

local function wire_node(id, kind, name, revision, load_state)
	return {
		workspaceId = "workspace-id",
		revision = revision,
		id = id,
		kind = kind,
		name = name,
		loadState = load_state or "loaded",
		capabilities = {},
	}
end

local function harness()
	local client = {
		generation = 1,
		inert = false,
		state = "ready",
		limits = { maxPageSize = 1 },
		requests = {},
		active_children = 0,
		max_active_children = 0,
	}
	function client:request(method, parameters, callback)
		self.requests[#self.requests + 1] = {
			method = method,
			parameters = vim.deepcopy(parameters or {}),
			callback = callback,
		}
		if method == "workspace/children" then
			self.active_children = self.active_children + 1
			self.max_active_children = math.max(self.max_active_children, self.active_children)
		end
	end
	function client:_terminate(reason)
		self.inert, self.state, self.termination = true, "failed", reason
	end
	function client:stop()
		self.inert, self.state = true, "stopped"
	end

	local workspace = canonical_node("workspace", "workspace", "Example.slnx", nil)
	local project = canonical_node("project", "project", "Example.fsproj", "workspace")
	local other = canonical_node("other", "project", "Other.fsproj", "workspace")
	local tree
	tree = setmetatable({
		nodes = { workspace = workspace, project = project, other = other },
		children = { workspace = { "project", "other" } },
		loading = {},
		stages = {},
		next_expansion_token = 0,
		expansion_owner = nil,
		roots = { "workspace" },
		expanded = { workspace = true },
		selected_id = "project",
		revision = 1,
		reflected_base_revision = nil,
		workspace_id = "workspace-id",
		phase = "ready",
		epoch = 0,
		reconcile_waiters = {},
		reconciling = false,
		reconcile_queued = false,
		reconciliation_deferred = false,
		deferred_reconciliation = false,
		client = client,
		changes = 0,
		presentations = {},
		errors = {},
		on_change = function(current)
			current.changes = current.changes + 1
			current.presentations[#current.presentations + 1] =
				vim.deepcopy(current:presentation_children_of("project"))
		end,
		on_error = function(problem)
			tree.errors[#tree.errors + 1] = problem
		end,
		on_notification = function() end,
		_delta = delta,
	}, { __index = Workspace })
	return tree, client
end

local function pending(client, method, parent_id, token)
	for _, request in ipairs(client.requests) do
		if
			not request.completed
			and request.method == method
			and (parent_id == nil or request.parameters.parentNodeId == parent_id)
			and (token == nil or request.parameters.continuationToken == token)
		then
			return request
		end
	end
	error("missing pending request " .. method)
end

local function reply(client, request, problem, result)
	request.completed = true
	if request.method == "workspace/children" then
		client.active_children = client.active_children - 1
	end
	request.callback(problem, result)
end

local function children_page(revision, ids, next_token)
	local nodes = {}
	for _, id in ipairs(ids) do
		nodes[#nodes + 1] = wire_node(id, "projectFile", id .. ".fs", revision)
	end
	return {
		revision = revision,
		parentNodeId = "project",
		nodes = nodes,
		nextToken = next_token,
	}
end

do
	local tree, client = harness()
	local results = {}
	tree:expand("project", function(problem, ids)
		results[#results + 1] = { problem = problem, ids = ids }
	end)
	tree:expand("project", function(problem, ids)
		results[#results + 1] = { problem = problem, ids = ids }
	end)
	assert_equal(1, #client.requests, "one request serves concurrent expansion waiters")
	assert_equal(nil, tree:children_of("project"), "canonical children remain absent while staged")
	assert_equal(
		{ loading = true, provisional = false, actionable = true, parent_id = "project" },
		tree:presentation_metadata("project"),
		"parent presentation metadata exposes loading"
	)

	reply(
		client,
		pending(client, "workspace/children", "project"),
		nil,
		children_page(1, { "a" }, "page-2")
	)
	assert_equal({ "a" }, tree:presentation_children_of("project"), "first page is presentable")
	assert_equal(nil, tree:children_of("project"), "first page does not change canonical order")
	assert_equal(
		{ loading = true, provisional = true, actionable = false, parent_id = "project" },
		tree:presentation_metadata("a"),
		"staged rows are explicitly non-actionable"
	)
	tree:select("a")
	assert_equal("project", tree.selected_id, "provisional rows cannot become canonical selection")
	assert_equal(nil, tree:get_node("a"), "canonical node access excludes provisional rows")
	assert_equal(nil, tree:parent("a"), "canonical parent access excludes provisional rows")
	assert_equal(0, #results, "waiters remain pending before the final page")
	reply(
		client,
		pending(client, "workspace/children", "project", "page-2"),
		nil,
		children_page(1, { "b" }, "page-3")
	)
	reply(
		client,
		pending(client, "workspace/children", "project", "page-3"),
		nil,
		children_page(1, { "c" })
	)
	assert_equal(
		{ "a", "b", "c" },
		tree:children_of("project"),
		"final page promotes canonical server order atomically"
	)
	assert_equal(1, client.max_active_children, "continuation pages are requested serially")
	assert_equal(2, #results, "all waiters settle once after promotion")
	assert_equal({ "a", "b", "c" }, results[1].ids, "promoted order reaches the first waiter")
	assert_equal(false, tree:presentation_metadata("a").provisional, "promoted rows are canonical")
end

for _, invalid in ipairs({
	{
		name = "duplicate node id",
		first = children_page(1, { "duplicate" }, "next"),
		second = children_page(1, { "duplicate" }),
	},
	{
		name = "repeated continuation token",
		first = children_page(1, { "a" }, "next"),
		second = children_page(1, { "b" }, "next"),
		not_presented = "b",
	},
	{
		name = "empty continuation token",
		first = children_page(1, { "a" }, ""),
		not_presented = "a",
	},
}) do
	local tree, client = harness()
	local settled = {}
	tree:expand("project", function(problem)
		settled[#settled + 1] = problem and problem.code
	end)
	reply(client, pending(client, "workspace/children", "project"), nil, invalid.first)
	if invalid.second then
		reply(client, pending(client, "workspace/children", "project", "next"), nil, invalid.second)
	end
	assert_equal({ "invalid_tree" }, settled, invalid.name .. " settles once")
	assert_equal(nil, tree:children_of("project"), invalid.name .. " rolls back canonical children")
	assert_equal(nil, tree.expanded.project, invalid.name .. " restores first-load expansion")
	assert_equal(
		"invalid_tree",
		client.termination.code,
		invalid.name .. " terminates the invalid session"
	)
	if invalid.not_presented then
		for _, ids in ipairs(tree.presentations) do
			assert_equal(
				false,
				vim.tbl_contains(ids or {}, invalid.not_presented),
				invalid.name .. " is rejected before presentation"
			)
		end
	end
end

do
	local tree = harness()
	local old = canonical_node("old", "projectFile", "Old.fs", "project")
	tree.nodes.old = old
	tree.children.project = { "old" }
	tree.expanded.project = true
	local settled = 0
	local stage = staging.create(tree, "project", true, function(problem)
		assert_equal("stale_tree", problem.code, "existing-view rollback is stale")
		settled = settled + 1
	end)
	stage.nodes.new = canonical_node("new", "projectFile", "New.fs", "project")
	stage.ids = { "new" }
	assert_equal(
		{ "new" },
		tree:presentation_children_of("project"),
		"stage overlays an existing complete view"
	)
	staging.discard(tree, stage)
	assert_equal(
		{ "old" },
		tree:children_of("project"),
		"rollback preserves prior canonical children"
	)
	assert_equal(old, tree:get_node("old"), "rollback preserves prior canonical nodes")
	assert_equal(true, tree.expanded.project, "rollback restores prior expanded state")
	assert_equal(1, settled, "existing-view rollback settles once")
end

local lifecycle_cases = {
	{
		name = "collapse",
		action = function(tree)
			tree:collapse("project")
		end,
		code = "stale_tree",
	},
	{
		name = "collapse all",
		action = function(tree)
			tree:collapse_all()
		end,
		code = "stale_tree",
	},
	{
		name = "refresh",
		action = function(tree)
			tree:refresh()
		end,
		code = "stale_tree",
	},
	{
		name = "reset",
		action = function(tree)
			tree:_notification("workspace/reset", { workspaceId = "workspace-id", revision = 2 })
		end,
		code = "stale_tree",
	},
	{
		name = "deferred reset",
		action = function(tree)
			tree.reconciliation_deferred = true
			tree:_notification("workspace/reset", { workspaceId = "workspace-id", revision = 2 })
		end,
		code = "stale_tree",
	},
	{
		name = "session stop",
		action = function(tree)
			tree:stop()
		end,
		code = "stale_tree",
	},
	{
		name = "failure",
		action = function(tree)
			tree:_fail({ code = "rpc_failure", message = "failed" })
		end,
		code = "rpc_failure",
	},
}
for _, case in ipairs(lifecycle_cases) do
	local tree, client = harness()
	local settled = {}
	tree:expand("project", function(problem)
		settled[#settled + 1] = problem and problem.code
	end)
	reply(
		client,
		pending(client, "workspace/children", "project"),
		nil,
		children_page(1, { "early" }, "late")
	)
	local late = pending(client, "workspace/children", "project", "late")
	case.action(tree)
	assert_equal({ case.code }, settled, case.name .. " settles the stage once")
	reply(client, late, nil, children_page(1, { "late" }))
	assert_equal({ case.code }, settled, case.name .. " ignores a late page callback")
	assert_equal(nil, tree:children_of("project"), case.name .. " preserves canonical rollback")
end

do
	local tree, client = harness()
	local settled = {}
	tree:expand("project", function(problem)
		settled[#settled + 1] = problem and problem.code
	end)
	reply(
		client,
		pending(client, "workspace/children", "project"),
		nil,
		children_page(1, { "a" }, "last")
	)
	local failing = pending(client, "workspace/children", "project", "last")
	reply(client, failing, { code = "source_failed", message = "failed" })
	assert_equal({ "source_failed" }, settled, "page failure settles once")
	assert_equal(nil, tree:children_of("project"), "page failure leaves first load unloaded")
	failing.callback(nil, children_page(1, { "late" }))
	assert_equal({ "source_failed" }, settled, "late callback after page failure is ignored")
	assert_equal(
		nil,
		tree:children_of("project"),
		"late callback after page failure cannot promote"
	)
end

do
	local tree, client = harness()
	local first_settled, replacement_settled
	tree:expand("project", function(problem)
		first_settled = problem and problem.code
	end)
	local old_request = pending(client, "workspace/children", "project")
	tree:collapse("project")
	tree:expand("project", function(problem)
		replacement_settled = problem and problem.code or "success"
	end)
	local replacement_stage = staging.get(tree, "project")
	local replacement_request = client.requests[#client.requests]
	reply(client, old_request, nil, children_page(1, { "old-attempt" }))
	assert_equal("stale_tree", first_settled, "superseded attempt settles stale")
	assert_equal(
		replacement_stage,
		staging.get(tree, "project"),
		"late callback cannot discard a replacement stage"
	)
	reply(client, replacement_request, nil, children_page(1, { "replacement" }))
	assert_equal("success", replacement_settled, "replacement stage promotes normally")
	assert_equal({ "replacement" }, tree:children_of("project"), "only replacement data promotes")
end

local function reflected_delta(changes)
	return {
		workspaceId = "workspace-id",
		baseRevision = 1,
		newRevision = 2,
		changes = changes,
		diagnostics = {},
	}
end

for name, changes in pairs({
	["hydration parent update"] = {
		{
			kind = "update",
			parentNodeId = "workspace",
			index = 0,
			node = wire_node("project", "project", "Example.fsproj", 2, "hydrated"),
		},
	},
	["disjoint update"] = {
		{
			kind = "update",
			parentNodeId = "workspace",
			index = 1,
			node = wire_node("other", "project", "Other renamed.fsproj", 2),
		},
	},
}) do
	local tree, client = harness()
	tree:expand("project")
	reply(
		client,
		pending(client, "workspace/children", "project"),
		nil,
		children_page(2, { "a" }, "last")
	)
	assert_equal(
		true,
		staging.can_retain_reflected(tree, reflected_delta(changes)),
		name .. " classifies as safe"
	)
	tree:collapse("project")
end

do
	local tree, client = harness()
	local settled
	tree:expand("project", function(problem, ids)
		settled = { problem = problem, ids = ids }
	end)
	reply(
		client,
		pending(client, "workspace/children", "project"),
		nil,
		children_page(2, { "a" }, "last")
	)
	local stage = staging.get(tree, "project")
	local hydration_and_disjoint = reflected_delta({
		{
			kind = "update",
			parentNodeId = "workspace",
			index = 0,
			node = wire_node("project", "project", "Example.fsproj", 2, "hydrated"),
		},
		{
			kind = "update",
			parentNodeId = "workspace",
			index = 1,
			node = wire_node("other", "project", "Other renamed.fsproj", 2),
		},
	})
	assert_equal(
		true,
		staging.can_retain_reflected(tree, hydration_and_disjoint),
		"hydration parent and disjoint updates classify as safe"
	)
	tree:_notification("workspace/delta", hydration_and_disjoint)
	assert_equal(
		stage,
		staging.get(tree, "project"),
		"exact hydration and disjoint updates retain the stage"
	)
	assert_equal("hydrated", tree.nodes.project.load_state, "canonical hydration update applies")
	assert_equal(nil, settled, "retained stage still waits for its final page")
	reply(
		client,
		pending(client, "workspace/children", "project", "last"),
		nil,
		children_page(2, { "b" })
	)
	assert_equal(
		{ "a", "b" },
		tree:children_of("project"),
		"retained stage promotes after its final page"
	)
	assert_equal(nil, settled.problem, "retained stage succeeds")
end

do
	local unsafe_changes = {
		{
			kind = "add",
			parentNodeId = "project",
			index = 0,
			node = wire_node("added", "projectFile", "Added.fs", 2),
		},
		{ kind = "remove", id = "unrelated-child", parentNodeId = "project", index = 0 },
		{
			kind = "move",
			id = "other",
			oldParentId = "workspace",
			oldIndex = 1,
			newParentId = "project",
			newIndex = 0,
		},
		{
			kind = "move",
			id = "other",
			oldParentId = "project",
			oldIndex = 0,
			newParentId = "project",
			newIndex = 1,
		},
		{
			kind = "replace",
			oldId = "other",
			parentNodeId = "project",
			index = 0,
			node = wire_node("replacement", "project", "Replacement.fsproj", 2),
		},
		{
			kind = "update",
			parentNodeId = "project",
			index = 0,
			node = wire_node("a", "projectFile", "Changed.fs", 2),
		},
		{ kind = "remove", id = "a", parentNodeId = "other", index = 0 },
		{
			kind = "move",
			id = "a",
			oldParentId = "other",
			oldIndex = 0,
			newParentId = "workspace",
			newIndex = 2,
		},
		{
			kind = "replace",
			oldId = "a",
			parentNodeId = "other",
			index = 0,
			node = wire_node("replacement", "projectFile", "Replacement.fs", 2),
		},
	}
	for index, change in ipairs(unsafe_changes) do
		local tree, client = harness()
		tree:expand("project")
		reply(
			client,
			pending(client, "workspace/children", "project"),
			nil,
			children_page(2, { "a" }, "last")
		)
		assert_equal(
			false,
			staging.can_retain_reflected(tree, reflected_delta({ change })),
			"unsafe reflected fixture " .. index
		)
	end

	local tree, client = harness()
	local settled = 0
	tree:expand("project", function(problem)
		assert_equal("stale_tree", problem.code, "conflicting delta reports stale stage")
		settled = settled + 1
	end)
	reply(
		client,
		pending(client, "workspace/children", "project"),
		nil,
		children_page(2, { "a" }, "last")
	)
	local late = pending(client, "workspace/children", "project", "last")
	tree:_notification("workspace/delta", reflected_delta({ unsafe_changes[1] }))
	assert_equal(1, settled, "conflicting delta settles once")
	assert_equal(nil, staging.get(tree, "project"), "conflicting delta discards the stage")
	assert_equal(
		"workspace/root",
		client.requests[#client.requests].method,
		"conflicting delta reconciles"
	)
	local request_count = #client.requests
	reply(client, late, nil, children_page(2, { "late" }))
	assert_equal(1, settled, "late continuation after conflicting delta cannot settle twice")
	assert_equal(request_count, #client.requests, "late continuation after discard cannot continue")
	assert_equal(nil, tree:children_of("project"), "late continuation after discard cannot promote")

	local nonmatching_tree, nonmatching_client = harness()
	local nonmatching_settled
	nonmatching_tree:expand("project", function(problem)
		nonmatching_settled = problem and problem.code
	end)
	reply(
		nonmatching_client,
		pending(nonmatching_client, "workspace/children", "project"),
		nil,
		children_page(2, { "a" }, "last")
	)
	local nonmatching = {
		workspaceId = "workspace-id",
		baseRevision = 2,
		newRevision = 3,
		changes = {},
		diagnostics = {},
	}
	assert_equal(
		false,
		staging.can_retain_reflected(nonmatching_tree, nonmatching),
		"nonmatching reflected revisions are rejected"
	)
	nonmatching_tree:_notification("workspace/delta", nonmatching)
	assert_equal("stale_tree", nonmatching_settled, "nonmatching delta discards the active stage")
	assert_equal(
		"workspace/root",
		nonmatching_client.requests[#nonmatching_client.requests].method,
		"nonmatching delta reconciles"
	)
end

do
	local tree, client = harness()
	local expansion_result
	tree:expand("project", function(problem)
		expansion_result = problem and problem.code
		assert_equal(nil, tree.expansion_owner, "per-parent waiter settles before owner claim")
	end)
	local staged_page = pending(client, "workspace/children", "project")
	local expand_all_result
	tree:expand_all(function(problem)
		expand_all_result = problem and problem.code or "success"
	end)
	assert_equal("stale_tree", expansion_result, "Expand All preempts active per-parent stages")
	local request_count = #client.requests
	local normal_result
	tree:expand("other", function(problem)
		normal_result = problem and problem.code
	end)
	assert_equal("stale_tree", normal_result, "normal expansion is rejected while whole-tree-owned")
	assert_equal(request_count, #client.requests, "rejected normal expansion sends no request")
	tree:collapse_all()
	assert_equal("stale_tree", expand_all_result, "Collapse All preempts the whole-tree owner")
	reply(client, staged_page, nil, children_page(1, { "late" }))
	reply(client, pending(client, "workspace/root"), nil, { revision = 1, nodes = {} })
	assert_equal("stale_tree", expand_all_result, "late owner callbacks cannot settle twice")
end

local function root_response(revision)
	return {
		revision = revision,
		nodes = { wire_node("workspace", "workspace", "Example.slnx", revision) },
	}
end

local function empty_workspace_children(revision)
	return { revision = revision, parentNodeId = "workspace", nodes = {} }
end

local function snapshot_page(parent_id, revision, nodes, next_token)
	return {
		revision = revision,
		parentNodeId = parent_id,
		nodes = nodes,
		nextToken = next_token,
	}
end

do
	local tree, client = harness()
	tree.marks = { project = true }
	local prior_nodes = vim.deepcopy(tree.nodes)
	local callback_count, callback_result = 0, nil
	tree:expand_all(function(problem)
		callback_count = callback_count + 1
		callback_result = problem and problem.code or "success"
	end)
	reply(client, pending(client, "workspace/root"), nil, root_response(1))
	assert_equal(prior_nodes, tree.nodes, "root overlay leaves canonical nodes unchanged")
	assert_equal({ "workspace" }, tree:presentation_roots(), "root page is immediately presentable")
	assert_equal(
		true,
		tree:presentation_metadata("workspace").provisional,
		"overlay root is read-only"
	)

	reply(
		client,
		pending(client, "workspace/children", "workspace"),
		nil,
		snapshot_page("workspace", 1, {
			wire_node("project", "project", "Example.fsproj", 1),
			wire_node("other", "projectFile", "Other.fs", 1),
		})
	)
	assert_equal(
		{ "project", "other" },
		tree:presentation_children_of("workspace"),
		"validated child page preserves server order in the overlay"
	)
	assert_equal(prior_nodes, tree.nodes, "child overlay leaves canonical nodes unchanged")

	reply(
		client,
		pending(client, "workspace/children", "project"),
		nil,
		snapshot_page(
			"project",
			1,
			{ wire_node("first", "projectFile", "First.fs", 1) },
			"project-next"
		)
	)
	assert_equal(
		{ "first" },
		tree:presentation_children_of("project"),
		"first descendant page is visible before completion"
	)
	assert_equal(0, callback_count, "partial overlay does not settle Expand All")
	reply(
		client,
		pending(client, "workspace/children", "project", "project-next"),
		nil,
		snapshot_page("project", 1, { wire_node("second", "projectFile", "Second.fs", 1) })
	)
	assert_equal(1, callback_count, "complete overlay promotes once")
	assert_equal("success", callback_result, "complete overlay succeeds")
	assert_equal(nil, tree.expansion_owner, "successful promotion releases ownership")
	assert_equal({ "project", "other" }, tree.children.workspace, "root order promotes exactly")
	assert_equal({ "first", "second" }, tree.children.project, "paged order promotes exactly")
	assert_equal(true, tree.expanded.workspace, "root expansion promotes")
	assert_equal(true, tree.expanded.project, "nested expansion promotes")
	assert_equal("project", tree.selected_id, "semantic selection survives promotion")
	assert_equal({ project = true }, tree.marks, "canonical marks survive promotion")
	assert_equal(1, client.max_active_children, "whole-tree pages remain serially bounded")
end

do
	local tree, client = harness()
	local prior_nodes, prior_children = vim.deepcopy(tree.nodes), vim.deepcopy(tree.children)
	local result
	tree:expand_all(function(problem)
		result = problem and problem.code or "success"
	end)
	reply(client, pending(client, "workspace/root"), nil, root_response(1))
	local late = pending(client, "workspace/children", "workspace")
	tree:collapse_all()
	assert_equal("stale_tree", result, "Collapse All settles an overlay owner once")
	assert_equal(prior_nodes, tree.nodes, "Collapse All restores prior canonical nodes")
	assert_equal(prior_children, tree.children, "Collapse All restores prior canonical order")
	local request_count, change_count = #client.requests, tree.changes
	reply(client, late, nil, empty_workspace_children(1))
	assert_equal(request_count, #client.requests, "late overlay callback cannot continue")
	assert_equal(change_count, tree.changes, "late overlay callback cannot render")
	assert_equal(prior_nodes, tree.nodes, "late overlay callback cannot promote")
end

for _, lifecycle in ipairs({
	{
		name = "refresh",
		invoke = function(tree)
			tree:refresh(function() end)
		end,
	},
	{
		name = "reset",
		invoke = function(tree)
			tree:_notification("workspace/reset", {})
		end,
	},
	{
		name = "failure",
		invoke = function(tree)
			tree:_fail({ code = "failed", message = "failed" })
		end,
	},
	{
		name = "session stop/close",
		invoke = function(tree)
			tree:stop("closed")
		end,
	},
}) do
	local tree, client = harness()
	local prior_nodes, prior_children = vim.deepcopy(tree.nodes), vim.deepcopy(tree.children)
	local settled = 0
	tree:expand_all(function()
		settled = settled + 1
	end)
	reply(client, pending(client, "workspace/root"), nil, root_response(1))
	local late = pending(client, "workspace/children", "workspace")
	lifecycle.invoke(tree)
	assert_equal(nil, tree.expansion_owner, lifecycle.name .. " invalidates the exact owner")
	assert_equal(1, settled, lifecycle.name .. " settles the owner exactly once")
	assert_equal(prior_nodes, tree.nodes, lifecycle.name .. " preserves canonical nodes")
	assert_equal(prior_children, tree.children, lifecycle.name .. " preserves canonical order")
	local request_count, change_count = #client.requests, tree.changes
	reply(client, late, nil, empty_workspace_children(1))
	assert_equal(request_count, #client.requests, lifecycle.name .. " makes late callbacks inert")
	assert_equal(change_count, tree.changes, lifecycle.name .. " blocks late renders")
	assert_equal(1, settled, lifecycle.name .. " blocks duplicate settlement")
end

for _, failure in ipairs({
	{ name = "producer failure", problem = { code = "backend_failed", message = "failed" } },
}) do
	local tree, client = harness()
	local prior_nodes, prior_children = vim.deepcopy(tree.nodes), vim.deepcopy(tree.children)
	local settled = 0
	tree:expand_all(function()
		settled = settled + 1
	end)
	reply(client, pending(client, "workspace/root"), nil, root_response(1))
	reply(
		client,
		pending(client, "workspace/children", "workspace"),
		failure.problem,
		failure.result
	)
	assert_equal(nil, tree.expansion_owner, failure.name .. " releases the owner")
	assert_equal(prior_nodes, tree.nodes, failure.name .. " restores canonical nodes")
	assert_equal(prior_children, tree.children, failure.name .. " restores canonical order")
	assert_equal(1, settled, failure.name .. " settles exactly once")
end

do
	local tree, client = harness()
	local prior_nodes, prior_children = vim.deepcopy(tree.nodes), vim.deepcopy(tree.children)
	local settled = 0
	tree:expand_all(function()
		settled = settled + 1
	end)
	reply(client, pending(client, "workspace/root"), nil, root_response(1))
	reply(client, pending(client, "workspace/children", "workspace"), nil, {
		revision = 1,
		parentNodeId = "workspace",
		nodes = "invalid",
	})
	assert_equal(nil, tree.expansion_owner.overlay, "malformed page discards the visible overlay")
	assert_equal(prior_nodes, tree.nodes, "malformed page restores canonical nodes")
	assert_equal(prior_children, tree.children, "malformed page restores canonical order")
	assert_equal(0, settled, "owner remains guarded only for its reconciliation retry")
	tree:collapse_all()
	assert_equal(1, settled, "Collapse All cancels the retained retry owner once")
end

do
	local tree, client = harness()
	tree.expanded = {}
	local callback_count, callback_result = 0, nil
	tree:expand_all(function(problem)
		callback_count = callback_count + 1
		callback_result = problem and problem.code or "success"
	end)
	local original_owner = tree.expansion_owner
	reply(client, pending(client, "workspace/root"), nil, root_response(2))
	assert_equal(0, callback_count, "stale Expand All root remains pending through reconciliation")
	reply(client, pending(client, "workspace/root"), nil, root_response(2))
	assert_equal(0, callback_count, "reconciliation does not settle the original callback")
	assert(tree.expansion_owner ~= original_owner, "reconciled Expand All transfers to a new owner")
	reply(client, pending(client, "workspace/root"), nil, root_response(2))
	reply(
		client,
		pending(client, "workspace/children", "workspace"),
		nil,
		empty_workspace_children(2)
	)
	assert_equal(1, callback_count, "retried root path settles the original callback once")
	assert_equal("success", callback_result, "retried root path succeeds")
end

do
	local tree, client = harness()
	tree.expanded = {}
	local callback_count, callback_result = 0, nil
	tree:expand_all(function(problem)
		callback_count = callback_count + 1
		callback_result = problem and problem.code or "success"
	end)
	local original_owner = tree.expansion_owner
	reply(client, pending(client, "workspace/root"), nil, root_response(1))
	reply(
		client,
		pending(client, "workspace/children", "workspace"),
		nil,
		empty_workspace_children(2)
	)
	assert_equal(
		0,
		callback_count,
		"invalidated child snapshot remains pending through reconciliation"
	)
	reply(client, pending(client, "workspace/root"), nil, root_response(2))
	assert(tree.expansion_owner ~= original_owner, "child retry transfers to a new owner")
	reply(client, pending(client, "workspace/root"), nil, root_response(2))
	reply(
		client,
		pending(client, "workspace/children", "workspace"),
		nil,
		empty_workspace_children(2)
	)
	assert_equal(1, callback_count, "retried child path settles the original callback once")
	assert_equal("success", callback_result, "retried child snapshot path succeeds")
end

do
	local tree, client = harness()
	tree.expanded = {}
	local first_count, first_result = 0, nil
	tree:expand_all(function(problem)
		first_count = first_count + 1
		first_result = problem and problem.code or "success"
	end)
	reply(client, pending(client, "workspace/root"), nil, root_response(1))
	local late_first_child = pending(client, "workspace/children", "workspace")
	tree:collapse_all()
	assert_equal(1, first_count, "external preemption settles owner A once")
	assert_equal("stale_tree", first_result, "externally preempted owner A is stale")

	local second_count, second_result = 0, nil
	tree:expand_all(function(problem)
		second_count = second_count + 1
		second_result = problem and problem.code or "success"
	end)
	local second_owner = tree.expansion_owner
	local request_count = #client.requests
	reply(client, late_first_child, { code = "workspace_conflict", message = "stale owner" })
	assert_equal(second_owner, tree.expansion_owner, "late owner A cannot replace owner B")
	assert_equal(request_count, #client.requests, "late owner A cannot reconcile or request")
	assert_equal(0, second_count, "late owner A cannot settle owner B")

	reply(client, pending(client, "workspace/root"), nil, root_response(1))
	reply(
		client,
		pending(client, "workspace/children", "workspace"),
		nil,
		empty_workspace_children(1)
	)
	assert_equal(1, first_count, "late owner A cannot settle itself again")
	assert_equal(1, second_count, "replacement owner B settles once")
	assert_equal("success", second_result, "replacement owner B succeeds")
end

do
	local tree, client = harness()
	tree.expanded = {}
	local first_count = 0
	tree:expand_all(function()
		first_count = first_count + 1
	end)
	reply(client, pending(client, "workspace/root"), nil, root_response(1))
	local late_first_child = pending(client, "workspace/children", "workspace")
	tree:collapse_all()
	assert_equal(1, first_count, "valid-page scenario preempts owner A once")

	local second_count, second_result = 0, nil
	tree:expand_all(function(problem)
		second_count = second_count + 1
		second_result = problem and problem.code or "success"
	end)
	local second_owner = tree.expansion_owner
	local request_count = #client.requests
	reply(client, late_first_child, nil, {
		revision = 1,
		parentNodeId = "workspace",
		nodes = {},
		nextToken = "owner-a-next",
	})
	assert_equal(second_owner, tree.expansion_owner, "valid late owner A page cannot replace B")
	assert_equal(
		request_count,
		#client.requests,
		"valid late owner A page cannot continue or reconcile"
	)
	assert_equal(1, first_count, "valid late owner A page cannot settle A again")
	assert_equal(0, second_count, "valid late owner A page cannot settle B")

	reply(client, pending(client, "workspace/root"), nil, root_response(1))
	reply(
		client,
		pending(client, "workspace/children", "workspace"),
		nil,
		empty_workspace_children(1)
	)
	assert_equal(1, second_count, "owner B succeeds exactly once after valid late A page")
	assert_equal("success", second_result, "owner B result remains successful")
end

print("DWE workspace presentation staging probe passed")
