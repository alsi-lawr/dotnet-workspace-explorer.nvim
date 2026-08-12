vim.opt.runtimepath:prepend(vim.fn.getcwd())

local config = require("dotnet-workspace-explorer.config")
local AddExistingSelector = require("dotnet-workspace-explorer.operations.selector").Selector
local view = require("dotnet-workspace-explorer.ui.view")
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

local function scenario(identifier, action)
	local ok, err = pcall(action)
	if not ok then
		error(("DWE-019/%s: %s"):format(identifier, err))
	end
end

local function noop() end

local function entry(id, name, kind, expandable, selectable, availability)
	return {
		entryId = id,
		displayName = name,
		kind = kind,
		expandable = expandable,
		selectable = selectable,
		availability = availability or (selectable and "available" or "ineligible"),
		gitStates = {},
	}
end

local function legacy_entry(id, name, kind, expandable, selectable)
	return {
		entryId = id,
		displayName = name,
		kind = kind,
		expandable = expandable,
		selectable = selectable,
	}
end

local function start_page(entries, next_token, legacy)
	return {
		revision = 7,
		selectorId = "selector-1",
		expiresAtUtc = "2026-08-01T12:00:00.0000000Z",
		maxSelectionCount = 256,
		root = (legacy and legacy_entry or entry)("root", "workspace", "directory", true, false),
		entries = entries,
		nextToken = next_token,
	}
end

local function descriptor(target_kind)
	return {
		command = {
			id = "workspace.addExisting",
			name = "Add Existing",
			access = "write",
			parameters = {
				{ id = "selectorId", name = "Selector", type = "text", required = true },
				{ id = "entryIds", name = "Entries", type = "textArray", required = true },
			},
			targetKinds = { target_kind },
		},
	}
end

local function preview()
	return {
		confirmationToken = "preview-token",
		expiresAtUtc = "2026-08-01T12:00:00.0000000Z",
		summary = "Add existing items",
		effects = {
			{ operation = "addToProject", target = "App.csproj", recursive = false },
		},
	}
end

local function harness(options)
	options = options or {}
	local calls, errors = {}, {}
	local selected = "file-1"
	local live = true
	local metrics = {}
	local workspace = {
		client = { limits = { maxPageSize = options.page_size or 2 } },
	}
	workspace.has_capability = function(_, name)
		if name == "workspace.addExisting.selector" then
			return options.capability ~= false
		elseif name == "workspace.addExisting.presentation.v2" then
			return options.presentation_version_two ~= false
		elseif name == "workspace.addExisting.directories.v1" then
			return options.directory_selection_version_one == true
		end
		return false
	end
	workspace.request = function(_, method, parameters, callback)
		calls[#calls + 1] = {
			method = method,
			parameters = vim.deepcopy(parameters),
		}
		if options.request and options.request(method, parameters, callback) then
			return
		end
		if method == "workspace/addExisting/start" then
			callback(
				nil,
				start_page({
					entry("directory-1", "src", "directory", true, false),
					entry("file-1", "App.csproj", "file", false, true),
				})
			)
		elseif method == "workspace/addExisting/children" then
			callback(nil, {
				revision = 7,
				selectorId = "selector-1",
				parentEntryId = parameters.parentEntryId,
				entries = {
					entry("nested-file", "Nested.cs", "file", false, true),
				},
			})
		elseif method == "workspace/addExisting/close" then
			callback(nil, { closed = true })
		elseif method == "workspace/commands/describe" then
			callback(nil, descriptor(options.target_kind or "project"))
		elseif method == "workspace/commands/preview" then
			callback(nil, preview())
		elseif method == "workspace/commands/execute" then
			callback(nil, { applied = true, revision = 8 })
		end
	end
	local selector = AddExistingSelector.new({
		workspace = workspace,
		is_live = function()
			return live
		end,
		on_enter = noop,
		on_render = noop,
		on_leave = noop,
		on_selected = function(instance)
			instance:select(selected)
			return selected
		end,
		on_error = function(err)
			errors[#errors + 1] = vim.deepcopy(err)
		end,
		on_success = function(revision)
			metrics.success_revision = revision
		end,
	})
	local function start()
		selector:start({
			target_id = "target-1",
			target_kind = options.target_kind or "project",
			revision = 7,
			selection_id = "selection-1",
		})
	end
	return {
		selector = selector,
		calls = calls,
		errors = errors,
		metrics = metrics,
		start = start,
		select = function(id)
			selected = id
		end,
		set_live = function(value)
			live = value
		end,
	}
end

local function calls_for(state, method)
	local matches = {}
	for _, call in ipairs(state.calls) do
		if call.method == method then
			matches[#matches + 1] = call
		end
	end
	return matches
end

scenario("start-paging-mark-confirm-execute", function()
	local state = harness({
		request = function(method, parameters, callback)
			if method == "workspace/addExisting/start" then
				callback(
					nil,
					start_page({
						entry("directory-1", "src", "directory", true, false),
						entry("file-1", "One.cs", "file", false, true),
					}, "root-next")
				)
				return true
			elseif method == "workspace/addExisting/children" then
				assert_equal("root", parameters.parentEntryId, "root page parent")
				callback(nil, {
					revision = 7,
					selectorId = "selector-1",
					parentEntryId = "root",
					entries = {
						entry("file-2", "Two.fs", "file", false, true),
					},
				})
				return true
			end
		end,
	})
	state.start()

	assert_equal({
		targetNodeId = "target-1",
		selectionId = "selection-1",
		expectedRevision = 7,
		pageSize = 2,
	}, state.calls[1].parameters, "selector start envelope")
	assert_equal({
		selectorId = "selector-1",
		parentEntryId = "root",
		pageSize = 2,
		continuationToken = "root-next",
	}, state.calls[2].parameters, "root continuation envelope")
	assert(state.selector:get_entry("file-2"), "the continued page is available for selection")

	state.select("file-1")
	state.selector:toggle()
	state.select("file-2")
	state.selector:toggle()

	local original_input = vim.ui.input
	vim.ui.input = function(_, callback)
		callback("y")
	end
	state.selector:activate()
	vim.ui.input = original_input

	assert_equal({
		commandId = "workspace.addExisting",
		targetNodeId = "target-1",
	}, calls_for(state, "workspace/commands/describe")[1].parameters, "describe envelope")
	local command = {
		commandId = "workspace.addExisting",
		targetNodeId = "target-1",
		arguments = {
			selectorId = "selector-1",
			entryIds = { "file-1", "file-2" },
		},
		expectedRevision = 7,
	}
	assert_equal(
		command,
		calls_for(state, "workspace/commands/preview")[1].parameters,
		"preview envelope"
	)
	command.confirmationToken = "preview-token"
	assert_equal(
		command,
		calls_for(state, "workspace/commands/execute")[1].parameters,
		"execute envelope"
	)
	assert_equal(false, state.selector:is_engaged(), "successful execution exits selector mode")
	assert_equal(8, state.metrics.success_revision, "successful revision is reported")
	assert_equal({}, state.errors, "successful flow has no errors")
end)

scenario("directory-expansion-and-cached-collapse", function()
	local state = harness({
		request = function(method, parameters, callback)
			if
				method == "workspace/addExisting/children"
				and parameters.parentEntryId == "directory-1"
			then
				if parameters.continuationToken == nil then
					callback(nil, {
						revision = 7,
						selectorId = "selector-1",
						parentEntryId = "directory-1",
						entries = {
							entry("nested-1", "One.cs", "file", false, true),
						},
						nextToken = "nested-next",
					})
				else
					callback(nil, {
						revision = 7,
						selectorId = "selector-1",
						parentEntryId = "directory-1",
						entries = {
							entry("nested-2", "Two.cs", "file", false, true),
						},
					})
				end
				return true
			end
		end,
	})
	state.start()
	state.select("directory-1")
	state.selector:activate()

	local pages = calls_for(state, "workspace/addExisting/children")
	assert_equal({
		selectorId = "selector-1",
		parentEntryId = "directory-1",
		pageSize = 2,
	}, pages[1].parameters, "directory children envelope")
	assert_equal({
		selectorId = "selector-1",
		parentEntryId = "directory-1",
		pageSize = 2,
		continuationToken = "nested-next",
	}, pages[2].parameters, "directory continuation envelope")
	assert(state.selector:get_entry("nested-2"), "nested continuation is selectable")

	state.selector:activate()
	state.selector:activate()
	assert_equal(
		{ "nested-1", "nested-2" },
		state.selector:children_of("directory-1"),
		"collapse and re-expand preserve loaded children"
	)
	assert_equal({}, state.errors, "directory activation stays valid")
end)

scenario("confirmation-rejection-and-cancellation", function()
	local original_input = vim.ui.input
	vim.ui.input = function(_, callback)
		callback("n")
	end
	local state = harness()
	state.start()
	state.selector:toggle()
	state.selector:confirm()
	vim.ui.input = original_input

	assert_equal(
		nil,
		calls_for(state, "workspace/commands/execute")[1],
		"rejection does not execute"
	)
	assert_equal(true, state.selector:is_active(), "rejection leaves the selector available")
	state.selector:cancel()
	assert_equal({
		selectorId = "selector-1",
	}, calls_for(state, "workspace/addExisting/close")[1].parameters, "close envelope")
	assert_equal(false, state.selector:is_engaged(), "cancellation exits selector mode")
end)

scenario("late-callbacks-and-stale-revisions-stay-inert", function()
	local pending_children
	local children = harness({
		request = function(method, parameters, callback)
			if
				method == "workspace/addExisting/children"
				and parameters.parentEntryId == "directory-1"
			then
				pending_children = callback
				return true
			end
		end,
	})
	children.start()
	children.select("directory-1")
	children.selector:expand()
	children.selector:cancel()
	pending_children(nil, {
		revision = 7,
		selectorId = "selector-1",
		parentEntryId = "directory-1",
		entries = {
			entry("late", "Late.cs", "file", false, true),
		},
	})
	assert_equal(nil, children.selector:get_entry("late"), "late pages cannot revive a selector")
	assert_equal(false, children.selector:is_engaged(), "cancelled selector remains inactive")

	local pending_confirmation
	local original_input = vim.ui.input
	vim.ui.input = function(_, callback)
		pending_confirmation = callback
	end
	local confirmation = harness()
	confirmation.start()
	confirmation.selector:toggle()
	confirmation.selector:confirm()
	confirmation.selector:cancel()
	pending_confirmation("y")
	vim.ui.input = original_input
	assert_equal(
		nil,
		calls_for(confirmation, "workspace/commands/execute")[1],
		"late confirmation cannot execute"
	)

	local stale = harness()
	stale.start()
	stale.selector:workspace_changed(8)
	assert_equal(false, stale.selector:is_engaged(), "revision change exits selector mode")
	assert_equal("stale_selector", stale.errors[1].code, "revision change reports staleness")
end)

scenario("capability-variants", function()
	local unsupported = harness({ capability = false })
	unsupported.start()
	assert_equal(nil, unsupported.calls[1], "unsupported selector sends no request")
	assert_equal(
		"unsupported_capability",
		unsupported.errors[1].code,
		"missing selector capability"
	)

	local original_input = vim.ui.input
	vim.ui.input = function(_, callback)
		callback("n")
	end
	local legacy = harness({
		presentation_version_two = false,
		request = function(method, _, callback)
			if method == "workspace/addExisting/start" then
				callback(
					nil,
					start_page({
						legacy_entry("file-1", "Legacy.cs", "file", false, true),
					}, nil, true)
				)
				return true
			end
		end,
	})
	legacy.start()
	legacy.selector:toggle()
	legacy.selector:confirm()
	assert_equal(true, legacy.selector:is_active(), "presentation v1 selector remains supported")
	assert_equal(
		{ "file-1" },
		calls_for(legacy, "workspace/commands/preview")[1].parameters.arguments.entryIds,
		"presentation v1 entries remain markable"
	)
	legacy.selector:cancel()

	local directories = harness({
		directory_selection_version_one = true,
		request = function(method, parameters, callback)
			if method == "workspace/addExisting/start" then
				callback(
					nil,
					start_page({
						entry("directory-1", "src", "directory", true, true),
					})
				)
				return true
			elseif
				method == "workspace/addExisting/children"
				and parameters.parentEntryId == "directory-1"
			then
				callback(nil, {
					revision = 7,
					selectorId = "selector-1",
					parentEntryId = "directory-1",
					entries = {},
				})
				return true
			end
		end,
	})
	directories.start()
	directories.select("directory-1")
	directories.selector:toggle()
	directories.selector:activate()
	directories.selector:confirm()
	vim.ui.input = original_input
	assert_equal(
		{ "directory-1" },
		calls_for(directories, "workspace/commands/preview")[1].parameters.arguments.entryIds,
		"directory capability permits marking without changing Enter expansion"
	)
	assert_equal({}, directories.errors, "supported capability variants remain valid")
	directories.selector:cancel()
end)

scenario("additive-response-data-is-accepted", function()
	local state = harness({
		request = function(method, parameters, callback)
			if method == "workspace/addExisting/start" then
				local result = start_page({
					entry("directory-1", "src", "directory", true, false),
					entry("file-1", "App.csproj", "file", false, true),
				})
				result.futurePageData = { supportedLater = true }
				result.root.futureEntryData = "root"
				result.entries[2].futureEntryData = "file"
				result.entries[2].gitStates = { "futureState", "unstaged", "staged" }
				callback(nil, result)
				return true
			elseif method == "workspace/addExisting/children" then
				callback(nil, {
					revision = 7,
					selectorId = "selector-1",
					parentEntryId = parameters.parentEntryId,
					entries = {
						vim.tbl_extend(
							"force",
							entry("nested-file", "Nested.cs", "file", false, true),
							{ futureEntryData = true, gitStates = { "futureState" } }
						),
					},
					futurePageData = true,
				})
				return true
			elseif method == "workspace/addExisting/close" then
				callback(nil, { closed = true, futureCloseData = true })
				return true
			end
		end,
	})
	state.start()
	assert_equal(true, state.selector:is_active(), "additive start data keeps the selector active")

	state.selector:toggle()
	local original_input = vim.ui.input
	vim.ui.input = function(_, callback)
		callback("n")
	end
	state.selector:confirm()
	vim.ui.input = original_input
	assert_equal(
		{ "file-1" },
		calls_for(state, "workspace/commands/preview")[1].parameters.arguments.entryIds,
		"entries with additive data remain usable"
	)

	state.select("directory-1")
	state.selector:expand()
	assert(state.selector:get_entry("nested-file"), "additive children data remains usable")
	state.selector:cancel()
	assert_equal({}, state.errors, "additive response data does not fail the selector")
end)

scenario("critical-response-identity-remains-required", function()
	local missing_id = harness({
		request = function(method, _, callback)
			if method == "workspace/addExisting/start" then
				local result = start_page({})
				result.selectorId = nil
				callback(nil, result)
				return true
			end
		end,
	})
	missing_id.start()
	assert_equal(false, missing_id.selector:is_engaged(), "missing selector identity is rejected")
	assert_equal("incompatible_selector", missing_id.errors[1].code, "missing identity error")

	local wrong_parent = harness({
		request = function(method, parameters, callback)
			if
				method == "workspace/addExisting/children"
				and parameters.parentEntryId == "directory-1"
			then
				callback(nil, {
					revision = 7,
					selectorId = "selector-1",
					parentEntryId = "another-directory",
					entries = {},
				})
				return true
			end
		end,
	})
	wrong_parent.start()
	wrong_parent.select("directory-1")
	wrong_parent.selector:expand()
	assert_equal(false, wrong_parent.selector:is_engaged(), "wrong page identity is rejected")
	assert_equal("incompatible_selector", wrong_parent.errors[1].code, "wrong page identity error")
end)

local function semantic_tree()
	local nodes, children = {}, { workspace = {} }
	nodes.workspace = { id = "workspace", kind = "workspace", name = "Example.slnx" }
	for index = 1, 30 do
		local id = "semantic-" .. index
		nodes[id] = {
			id = id,
			parent_id = "workspace",
			kind = "solutionItem",
			name = ("Item %02d.txt"):format(index),
		}
		children.workspace[#children.workspace + 1] = id
	end
	return setmetatable({
		nodes = nodes,
		children = children,
		roots = { "workspace" },
		expanded = { workspace = true },
		selected_id = "semantic-15",
		phase = "ready",
	}, { __index = Workspace })
end

local function selector_tree()
	local entries, children =
		{
			root = {
				id = "root",
				kind = "directory",
				name = "workspace",
				expandable = true,
				selectable = false,
				availability = "ineligible",
				git_states = {},
			},
		}, { root = {} }
	for index = 1, 30 do
		local id = "selector-" .. index
		entries[id] = {
			id = id,
			parent_id = "root",
			kind = "file",
			name = ("File %02d.cs"):format(index),
			expandable = false,
			selectable = true,
			availability = "available",
			git_states = {},
		}
		children.root[#children.root + 1] = id
	end
	local selector = {
		root_id = "root",
		selected_id = "selector-15",
		entries = entries,
		children = children,
		expanded = { root = true },
		marks = {},
		toggles = 0,
	}
	function selector:get_entry(id)
		return self.entries[id]
	end
	function selector:is_expandable(id)
		return self.entries[id].expandable
	end
	function selector:children_of(id)
		return self.children[id]
	end
	function selector:select(id)
		self.selected_id = id
	end
	function selector:toggle()
		self.toggles = self.toggles + 1
	end
	return selector
end

local function find_mapping(lhs)
	local raw = vim.keycode(lhs)
	for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(view.buf, "n")) do
		if mapping.lhsraw == raw then
			return mapping
		end
	end
end

scenario("selector-view-preserves-selection-and-viewport", function()
	config.setup({
		mappings = {
			activate = false,
			close = false,
			new = "a",
		},
	})
	view.open()
	local tree = semantic_tree()
	view.render(tree)
	vim.api.nvim_win_set_cursor(view.win, { 16, 0 })
	vim.api.nvim_win_call(view.win, function()
		vim.fn.winrestview({ topline = 11 })
	end)
	local semantic_anchor = vim.api.nvim_buf_get_lines(view.buf, 10, 11, false)[1]

	local selector = selector_tree()
	view.enter_selector(selector, {
		activate = function() end,
		close = function() end,
	}, tree)
	vim.api.nvim_win_set_cursor(view.win, { 16, 0 })
	vim.api.nvim_win_call(view.win, function()
		vim.fn.winrestview({ topline = 11 })
	end)
	local selector_anchor = vim.api.nvim_buf_get_lines(view.buf, 10, 11, false)[1]
	view.render_selector(selector)
	assert_equal("selector-15", selector.selected_id, "selector selection survives re-render")
	local selector_topline = vim.api.nvim_win_call(view.win, vim.fn.winsaveview).topline
	assert_equal(
		selector_anchor,
		vim.api.nvim_buf_get_lines(view.buf, selector_topline - 1, selector_topline, false)[1],
		"selector viewport anchor survives re-render"
	)

	view.leave_selector(tree)
	assert_equal("semantic-15", tree.selected_id, "semantic selection is restored")
	local semantic_topline = vim.api.nvim_win_call(view.win, vim.fn.winsaveview).topline
	assert_equal(
		semantic_anchor,
		vim.api.nvim_buf_get_lines(view.buf, semantic_topline - 1, semantic_topline, false)[1],
		"semantic viewport anchor is restored"
	)
	view.close()
end)

scenario("selector-mode-action-routing", function()
	local EditingOperations = require("dotnet-workspace-explorer.operations.editing").Editing
	local MutationOperations = require("dotnet-workspace-explorer.operations.mutations").Mutations
	local SelectorOperations = require("dotnet-workspace-explorer.operations.selector").Selector
	local originals = {
		workspace = Workspace.new,
		editing = EditingOperations.new,
		mutations = MutationOperations.new,
		selector = SelectorOperations.new,
	}
	local active_selector, mutation_created
	Workspace.new = function(options)
		local tree = semantic_tree()
		tree.revision, tree.workspace_id, tree.git_enabled = 7, "workspace-id", false
		tree.start = function(self, callback)
			options.on_change(self)
			callback()
		end
		tree.stop = function() end
		tree.is_terminal = function()
			return false
		end
		tree.has_capability = function()
			return true
		end
		return tree
	end
	EditingOperations.new = function()
		return {
			reconcile = function() end,
			invalidate = function() end,
		}
	end
	MutationOperations.new = function()
		return {
			create = function()
				mutation_created = true
			end,
			invalidate = function() end,
		}
	end
	SelectorOperations.new = function()
		active_selector = {
			engaged = true,
			routed = {},
		}
		function active_selector:is_engaged()
			return self.engaged
		end
		for _, action in ipairs({ "toggle", "activate", "cancel", "expand", "collapse" }) do
			active_selector[action] = function(self)
				self.routed[#self.routed + 1] = action
			end
		end
		function active_selector:invalidate()
			self.engaged = false
		end
		active_selector.workspace_changed = function() end
		return active_selector
	end

	package.loaded["dotnet-workspace-explorer"] = nil
	local public = require("dotnet-workspace-explorer")
	public.setup({
		mappings = {
			new = "n",
			activate = "o",
			close = "x",
			expand = "L",
			collapse = "H",
		},
	})
	public._register_commands()
	public.open("target")
	find_mapping("n").callback()
	public.new()
	vim.cmd("DotnetWorkspaceExplorerNew")
	assert_equal(nil, mutation_created, "New actions are inert in selector mode")
	for _, mapping in ipairs({
		{ lhs = "o", action = "activate" },
		{ lhs = "x", action = "cancel" },
		{ lhs = "L", action = "expand" },
		{ lhs = "H", action = "collapse" },
	}) do
		find_mapping(mapping.lhs).callback()
		assert_equal(
			mapping.action,
			active_selector.routed[#active_selector.routed],
			mapping.lhs .. " routes to selector " .. mapping.action
		)
	end
	active_selector.engaged = false
	find_mapping("n").callback()
	assert_equal(true, mutation_created, "New returns to semantic routing after selector exit")
	public.close()

	Workspace.new, EditingOperations.new, MutationOperations.new, SelectorOperations.new =
		originals.workspace, originals.editing, originals.mutations, originals.selector
	package.loaded["dotnet-workspace-explorer"] = nil
end)

print("DWE-019 transient selector scenarios passed")
