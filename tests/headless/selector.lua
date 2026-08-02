vim.opt.runtimepath:prepend(vim.fn.getcwd())

local config = require("dotnet-workspace-explorer.config")
local Selector = require("dotnet-workspace-explorer.selector").Selector
local view = require("dotnet-workspace-explorer.view")
local Workspace = require("dotnet-workspace-explorer.workspace").Workspace

local function assert_equal(expected, actual, message)
	if not vim.deep_equal(expected, actual) then
		error(
			("%s\nexpected: %s\nactual: %s"):format(message, vim.inspect(expected), vim.inspect(actual))
		)
	end
end

local function scenario(identifier, action)
	local ok, err = pcall(action)
	if not ok then
		error(("DWE-019/%s: %s"):format(identifier, err))
	end
end

local function entry(id, name, kind, expandable, selectable, icon_hint, availability, states)
	local value = {
		entryId = id,
		displayName = name,
		kind = kind,
		expandable = expandable,
		selectable = selectable,
		availability = availability or (selectable and "available" or "ineligible"),
		gitStates = states or {},
	}
	if icon_hint then
		value.iconHint = icon_hint
	end
	return value
end

local function legacy_entry(...)
	local value = entry(...)
	value.availability, value.gitStates = nil, nil
	return value
end

local function start_page(entries, next_token, legacy)
	return {
		revision = 7,
		selectorId = "selector-1",
		expiresAtUtc = "2026-08-01T12:00:00.0000000Z",
		maxSelectionCount = 256,
		root = (legacy and legacy_entry or entry)(
			"root",
			"workspace",
			"directory",
			true,
			false,
			"folder"
		),
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
		summary = "Add two existing items",
		effects = {
			{ operation = "addToProject", target = "App.csproj", recursive = false },
			{ operation = "modify", target = "App.csproj", recursive = false },
		},
	}
end

local function harness(options)
	options = options or {}
	local calls, errors, events = {}, {}, {}
	local reconciliation = {}
	local selected = "file-1"
	local live = true
	local workspace = {
		client = { limits = { maxPageSize = options.page_size or 2 } },
	}
	workspace.has_capability = function(_, name)
		return (name == "workspace.addExisting.selector" and options.capability ~= false)
			or (
				name == "workspace.addExisting.presentation.v2"
				and options.presentation_version_two ~= false
			)
	end
	workspace.request = function(_, method, parameters, callback)
		calls[#calls + 1] = {
			method = method,
			parameters = vim.deepcopy(parameters),
			callback = callback,
		}
		if options.request then
			local handled = options.request(method, parameters, callback, calls)
			if handled then
				return
			end
		end
		if method == "workspace/addExisting/start" then
			return callback(
				nil,
				start_page({
					entry("directory-1", "src", "directory", true, false, "folder"),
					entry("file-1", "App.csproj", "file", false, true, "csproj"),
				})
			)
		elseif method == "workspace/addExisting/children" then
			return callback(nil, {
				revision = 7,
				selectorId = "selector-1",
				parentEntryId = parameters.parentEntryId,
				entries = {
					entry("nested-file", "Nested.cs", "file", false, true, "cs"),
				},
			})
		elseif method == "workspace/addExisting/close" then
			return callback(nil, { closed = true })
		elseif method == "workspace/commands/describe" then
			return callback(nil, descriptor(options.target_kind or "project"))
		elseif method == "workspace/commands/preview" then
			return callback(nil, preview())
		elseif method == "workspace/commands/execute" then
			return callback(nil, { applied = true, revision = 8 })
		end
	end
	local selector = Selector.new({
		workspace = workspace,
		is_live = function()
			return live
		end,
		on_enter = function(instance)
			events[#events + 1] = "enter"
			if options.on_enter then
				options.on_enter(instance)
			end
		end,
		on_render = function(instance)
			events[#events + 1] = "render"
			if options.on_render then
				options.on_render(instance)
			end
		end,
		on_leave = function()
			events[#events + 1] = "leave"
			if options.on_leave then
				options.on_leave()
			end
		end,
		on_selected = function(instance)
			instance:select(selected)
			return selected
		end,
		on_suspend = function()
			reconciliation[#reconciliation + 1] = "suspend"
		end,
		on_resume = function(revision)
			reconciliation[#reconciliation + 1] = revision and ("resume:" .. revision) or "resume"
		end,
		on_error = function(err)
			errors[#errors + 1] = vim.deepcopy(err)
		end,
		on_success = function(revision)
			events[#events + 1] = "success:" .. revision
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
		workspace = workspace,
		calls = calls,
		errors = errors,
		events = events,
		reconciliation = reconciliation,
		start = start,
		select = function(id)
			selected = id
		end,
		set_live = function(value)
			live = value
		end,
	}
end

scenario("exact-start-paging-marks-confirm-execute", function()
	local first_page = true
	local state = harness({
		request = function(method, parameters, callback)
			if method == "workspace/addExisting/start" then
				callback(
					nil,
					start_page({
						entry("directory-1", "src", "directory", true, false, "folder"),
						entry("file-1", "One.cs", "file", false, true, "cs"),
					}, "root-next")
				)
				return true
			elseif method == "workspace/addExisting/children" and first_page then
				first_page = false
				assert_equal("root", parameters.parentEntryId, "root continuation parent")
				callback(nil, {
					revision = 7,
					selectorId = "selector-1",
					parentEntryId = "root",
					entries = { entry("file-2", "Two.fs", "file", false, true, "fs") },
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
	}, state.calls[1].parameters, "exact selector start envelope")
	assert_equal({
		selectorId = "selector-1",
		parentEntryId = "root",
		pageSize = 2,
		continuationToken = "root-next",
	}, state.calls[2].parameters, "exact continuation envelope")
	assert_equal({ "enter" }, state.events, "selector enters after every root page")
	assert_equal({ "directory-1", "file-1", "file-2" }, state.selector.children.root, "opaque pages")

	state.select("file-1")
	state.selector:toggle()
	state.select("file-2")
	state.selector:toggle()
	assert_equal({ "file-1", "file-2" }, state.selector.mark_order, "mark order is complete")
	local original_input = vim.ui.input
	vim.ui.input = function(options, callback)
		assert(options.prompt:find("App.csproj", 1, true), "all preview effects are displayed")
		assert(options.prompt:find("Confirm [y/N]", 1, true), "confirmation prompt is explicit")
		assert_equal("N", options.default, "Add Existing defaults to No")
		assert_equal("confirmation", options.kind, "Add Existing uses vim.ui.input")
		callback("y")
	end
	state.selector:activate()
	assert_equal({
		commandId = "workspace.addExisting",
		targetNodeId = "target-1",
	}, state.calls[3].parameters, "exact describe envelope")
	local expected_preview = {
		commandId = "workspace.addExisting",
		targetNodeId = "target-1",
		arguments = {
			selectorId = "selector-1",
			entryIds = { "file-1", "file-2" },
		},
		expectedRevision = 7,
	}
	assert_equal(expected_preview, state.calls[4].parameters, "exact Add Existing preview")
	vim.ui.input = original_input
	local execute = vim.deepcopy(expected_preview)
	execute.confirmationToken = "preview-token"
	assert_equal(
		execute,
		state.calls[#state.calls].parameters,
		"execute is a deep preview copy plus token"
	)
	assert_equal(
		nil,
		state.calls[#state.calls - 1].parameters.confirmationToken,
		"preview stays clean"
	)
	assert_equal(
		{ "enter", "render", "render", "leave", "success:8" },
		state.events,
		"restore precedes success"
	)
	assert_equal({ "suspend", "resume:8" }, state.reconciliation, "success resumes after restore")
	assert_equal({}, state.errors, "successful flow errors")
end)

scenario("activate lazily expands and collapses directories without confirming", function()
	local nested_continuation
	local state = harness({
		request = function(method, parameters, callback)
			if
				method == "workspace/addExisting/children" and parameters.parentEntryId == "directory-1"
			then
				if not parameters.continuationToken then
					callback(nil, {
						revision = 7,
						selectorId = "selector-1",
						parentEntryId = "directory-1",
						entries = {
							entry("nested-1", "A.vb", "file", false, true, "vb"),
						},
						nextToken = "nested-next",
					})
				else
					nested_continuation = vim.deepcopy(parameters)
					callback(nil, {
						revision = 7,
						selectorId = "selector-1",
						parentEntryId = "directory-1",
						entries = {
							entry("nested-2", "B.txt", "file", false, false, "txt"),
						},
					})
				end
				return true
			end
		end,
	})
	state.start()
	assert_equal(nil, state.selector.children["directory-1"], "directory remains lazy")
	state.select("directory-1")
	state.selector:activate()
	assert_equal({
		selectorId = "selector-1",
		parentEntryId = "directory-1",
		pageSize = 2,
		continuationToken = "nested-next",
	}, nested_continuation, "nested continuation stays opaque")
	assert_equal({ "nested-1", "nested-2" }, state.selector.children["directory-1"], "nested pages")
	state.selector:activate()
	assert_equal(nil, state.selector.expanded["directory-1"], "opaque directory collapses")
	assert_equal(0, #state.errors, "directory activation never attempts confirmation")
end)

scenario("strict-malformed-start-pages-and-duplicate-state", function()
	local cases = {
		{
			name = "wrong revision",
			mutate = function(result)
				result.revision = 8
			end,
		},
		{
			name = "wrong limit",
			mutate = function(result)
				result.maxSelectionCount = 255
			end,
		},
		{
			name = "extra field",
			mutate = function(result)
				result.path = "/forbidden"
			end,
		},
		{
			name = "selectable directory",
			mutate = function(result)
				result.root.selectable = true
			end,
		},
		{
			name = "availability disagrees with selectability",
			mutate = function(result)
				result.entries = {
					entry("blocked", "Blocked.cs", "file", false, false, "cs", "available"),
				}
			end,
		},
		{
			name = "Git states are out of order",
			mutate = function(result)
				result.entries = {
					entry(
						"changed",
						"Changed.cs",
						"file",
						false,
						true,
						"cs",
						"available",
						{ "untracked", "staged" }
					),
				}
			end,
		},
		{
			name = "duplicate ID",
			mutate = function(result)
				result.entries = {
					entry("same", "One", "file", false, true),
					entry("same", "Two", "file", false, true),
				}
			end,
		},
		{
			name = "oversized page",
			mutate = function(result)
				result.entries = {
					entry("one", "One", "file", false, true),
					entry("two", "Two", "file", false, true),
					entry("three", "Three", "file", false, true),
				}
			end,
		},
	}
	for _, case in ipairs(cases) do
		local state = harness({
			request = function(method, _, callback)
				if method == "workspace/addExisting/start" then
					local result = start_page({})
					case.mutate(result)
					callback(nil, result)
					return true
				end
			end,
		})
		state.start()
		assert_equal(false, state.selector:is_engaged(), case.name .. " exits")
		assert_equal({}, state.events, case.name .. " never replaces semantic rows")
		assert_equal("incompatible_selector", state.errors[1].code, case.name .. " strict error")
	end

	local state = harness({
		request = function(method, parameters, callback)
			if method == "workspace/addExisting/start" then
				callback(nil, start_page({}, "repeat"))
				return true
			elseif method == "workspace/addExisting/children" then
				callback(nil, {
					revision = 7,
					selectorId = "selector-1",
					parentEntryId = parameters.parentEntryId,
					entries = {},
					nextToken = "repeat",
				})
				return true
			end
		end,
	})
	state.start()
	assert_equal({}, state.events, "duplicate token never replaces semantic rows")
	assert_equal("incompatible_selector", state.errors[1].code, "duplicate token error")

	for field, wrong in pairs({
		revision = 8,
		selectorId = "other-selector",
		parentEntryId = "other-parent",
	}) do
		local mismatch = harness({
			request = function(method, parameters, callback)
				if
					method == "workspace/addExisting/children"
					and parameters.parentEntryId == "directory-1"
				then
					local result = {
						revision = 7,
						selectorId = "selector-1",
						parentEntryId = "directory-1",
						entries = {},
					}
					result[field] = wrong
					callback(nil, result)
					return true
				end
			end,
		})
		mismatch.start()
		mismatch.select("directory-1")
		mismatch.selector:expand()
		assert_equal({ "enter", "leave" }, mismatch.events, field .. " mismatch restores")
		assert_equal("incompatible_selector", mismatch.errors[1].code, field .. " mismatch")
	end
end)

scenario(
	"mark action is silent for directories and existing files and reports actual failures",
	function()
		local values = {
			entry("directory-1", "src", "directory", true, false),
			entry("blocked", "blocked.csproj", "file", false, false),
			entry("existing", "Existing.cs", "file", false, false, "cs", "alreadyPresent"),
		}
		for index = 1, 257 do
			values[#values + 1] = entry("file-" .. index, index .. ".cs", "file", false, true)
		end
		local state = harness({
			page_size = 4096,
			request = function(method, _, callback)
				if method == "workspace/addExisting/start" then
					callback(nil, start_page(values))
					return true
				end
			end,
		})
		state.start()
		state.selector:confirm()
		assert_equal("empty_selection", state.errors[#state.errors].code, "empty confirm is local")
		assert(
			state.errors[#state.errors].message:find("Press Space", 1, true),
			"empty confirmation explains marking"
		)
		local calls = #state.calls
		local errors = #state.errors
		state.select("directory-1")
		state.selector:toggle()
		state.select("existing")
		state.selector:toggle()
		assert_equal(errors, #state.errors, "directory and existing file are silent")
		state.select("blocked")
		state.selector:toggle()
		assert_equal(
			"not_selectable",
			state.errors[#state.errors].code,
			"ineligible file is contextual"
		)
		for index = 1, 257 do
			state.select("file-" .. index)
			state.selector:toggle()
		end
		assert_equal(256, #state.selector.mark_order, "advertised selection limit")
		assert_equal(false, state.selector.marks["file-257"] == true, "limit cannot be exceeded")
		assert_equal(calls, #state.calls, "local mark checks make no request")
		assert_equal("selection_limit", state.errors[#state.errors].code, "limit error")
	end
)

scenario("ineligible ordinary files explain the selected target rule", function()
	local messages = {
		workspace = "Only .csproj, .fsproj, or .vbproj project files can be added to the solution.",
		solutionFolder = "Only projects or solution items can be added to a Solution Folder.",
		project = "Only non-project files can be added to a project.",
		projectFolder = "Only non-project files can be added to a project folder.",
	}
	for target_kind, message in pairs(messages) do
		local state = harness({
			target_kind = target_kind,
			request = function(method, _, callback)
				if method == "workspace/addExisting/start" then
					callback(
						nil,
						start_page({
							entry("blocked", "Blocked.txt", "file", false, false, "txt"),
						})
					)
					return true
				end
			end,
		})
		state.start()
		state.select("blocked")
		state.selector:toggle()
		assert_equal("not_selectable", state.errors[1].code, target_kind .. " error code")
		assert_equal(message, state.errors[1].message, target_kind .. " target guidance")
	end
end)

scenario("legacy selector entries retain the exact older response shape", function()
	local state = harness({
		presentation_version_two = false,
		request = function(method, _, callback)
			if method == "workspace/addExisting/start" then
				callback(
					nil,
					start_page({
						legacy_entry("file-1", "Legacy.cs", "file", false, true, "cs"),
					}, nil, true)
				)
				return true
			end
		end,
	})
	state.start()
	assert_equal(true, state.selector:is_active(), "legacy selector starts")
	assert_equal(
		{},
		state.selector:get_entry("file-1").git_states,
		"legacy selector has no Git state"
	)
	state.selector:toggle()
	assert_equal({ "file-1" }, state.selector.mark_order, "legacy selectable file remains markable")
end)

scenario("cancel-error-stale-and-late-callback-invalidation", function()
	local close_callback, nested_callback
	local state = harness({
		request = function(method, parameters, callback)
			if method == "workspace/addExisting/close" then
				close_callback = callback
				return true
			elseif
				method == "workspace/addExisting/children" and parameters.parentEntryId == "directory-1"
			then
				nested_callback = callback
				return true
			end
		end,
	})
	state.start()
	state.select("directory-1")
	state.selector:expand()
	state.selector:cancel()
	assert_equal("leave", state.events[#state.events], "cancel restores semantic rows")
	assert_equal({
		selectorId = "selector-1",
	}, state.calls[#state.calls].parameters, "exact close envelope")
	nested_callback(nil, {
		revision = 7,
		selectorId = "selector-1",
		parentEntryId = "directory-1",
		entries = { entry("late", "late.cs", "file", false, true) },
	})
	close_callback(nil, { closed = false })
	assert_equal(false, state.selector:is_engaged(), "late callbacks cannot revive selector")
	assert_equal(0, #state.errors, "late close cannot alter replacement view")

	local stale = harness()
	stale.start()
	stale.selector:workspace_changed(8)
	assert_equal({ "enter", "leave" }, stale.events, "stale revision restores directly")
	assert_equal("stale_selector", stale.errors[1].code, "stale revision error")

	local expired = harness({
		request = function(method, _, callback)
			if method == "workspace/addExisting/start" then
				callback({ code = "selector_expired", message = "expired" })
				return true
			end
		end,
	})
	expired.start()
	assert_equal({}, expired.events, "expired start leaves semantic rows untouched")
	assert_equal("selector_expired", expired.errors[1].code, "expired selector error")
end)

scenario("preview-and-execute-late-callbacks", function()
	for _, delayed_method in ipairs({
		"workspace/commands/describe",
		"workspace/commands/preview",
		"workspace/commands/execute",
	}) do
		local delayed
		local original_input = vim.ui.input
		vim.ui.input = function(_, callback)
			callback("y")
		end
		local state = harness({
			request = function(method, _, callback)
				if method == delayed_method then
					delayed = callback
					return true
				end
			end,
		})
		state.start()
		state.selector:toggle()
		state.selector:confirm()
		state.selector:cancel()
		if delayed_method == "workspace/commands/describe" then
			delayed(nil, descriptor("project"))
		elseif delayed_method == "workspace/commands/preview" then
			delayed(nil, preview())
		else
			delayed(nil, { applied = true, revision = 8 })
		end
		assert_equal({ "enter", "render", "leave" }, state.events, delayed_method .. " late event")
		assert_equal(false, state.selector:is_engaged(), delayed_method .. " remains invalid")
		vim.ui.input = original_input
	end
end)

scenario("confirmation-late-callback", function()
	local pending
	local original_input = vim.ui.input
	vim.ui.input = function(options, callback)
		assert_equal("confirmation", options.kind, "late prompt uses vim.ui.input")
		pending = callback
	end
	local state = harness()
	state.start()
	state.selector:toggle()
	state.selector:confirm()
	assert(pending, "confirmation callback was not retained")
	state.selector:cancel()
	pending("y")
	assert_equal({ "enter", "render", "leave" }, state.events, "late confirmation stays inert")
	assert_equal(false, state.selector:is_engaged(), "late confirmation cannot revive selector")
	assert_equal(
		"workspace/addExisting/close",
		state.calls[#state.calls].method,
		"no execute follows"
	)
	vim.ui.input = original_input
end)

scenario("all-target-context-descriptors", function()
	for _, target_kind in ipairs({ "workspace", "solutionFolder", "project", "projectFolder" }) do
		local original_input = vim.ui.input
		vim.ui.input = function(_, callback)
			callback("n")
		end
		local state = harness({ target_kind = target_kind })
		state.start()
		state.selector:toggle()
		state.selector:confirm()
		assert_equal({}, state.errors, target_kind .. " descriptor accepted")
		assert_equal(true, state.selector:is_active(), target_kind .. " remains after confirm cancel")
		state.selector:cancel()
		vim.ui.input = original_input
	end
end)

scenario("dismissed-confirmation", function()
	local original_input = vim.ui.input
	vim.ui.input = function(_, callback)
		callback(nil)
	end
	local state = harness()
	state.start()
	state.selector:toggle()
	state.selector:confirm()
	assert_equal(true, state.selector:is_active(), "dismissed confirmation leaves selector active")
	assert_equal(
		"workspace/commands/preview",
		state.calls[#state.calls].method,
		"dismissal stops execute"
	)
	state.selector:cancel()
	vim.ui.input = original_input
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

local function mapping_signature(mapping)
	if not mapping then
		return nil
	end
	return {
		lhs = mapping.lhs,
		rhs = mapping.rhs,
		callback = mapping.callback,
		noremap = mapping.noremap,
		nowait = mapping.nowait,
		silent = mapping.silent,
		expr = mapping.expr,
		replace_keycodes = mapping.replace_keycodes,
		desc = mapping.desc,
	}
end

local function find_mapping(lhs)
	local raw = vim.keycode(lhs)
	for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(view.buf, "n")) do
		if mapping.lhsraw == raw then
			return mapping
		end
	end
end

scenario("same-drawer-mapping-and-semantic-view-restoration", function()
	config.setup({
		position = "right",
		width = 34,
		mappings = {
			activate = false,
			close = false,
			new = "a",
		},
	})
	view.open()
	local tree = semantic_tree()
	view.render(tree)
	vim.api.nvim_win_set_width(view.win, 41)
	vim.api.nvim_win_set_cursor(view.win, { 16, 0 })
	vim.api.nvim_win_call(view.win, function()
		vim.fn.winrestview({ topline = 11 })
	end)

	local semantic_actions = setmetatable({}, {
		__index = function()
			return function() end
		end,
	})
	local semantic_new_calls = 0
	semantic_actions.new = function()
		semantic_new_calls = semantic_new_calls + 1
	end
	view.mappings(semantic_actions)
	local plugin_owned = find_mapping("a").callback
	local custom_callback = function() end
	vim.api.nvim_buf_set_keymap(view.buf, "n", "<Space>", "j", {
		noremap = true,
		nowait = true,
		silent = true,
	})
	vim.api.nvim_buf_set_keymap(view.buf, "n", "<CR>", "zz", {
		noremap = false,
		nowait = false,
		silent = false,
	})
	vim.keymap.set("n", "q", custom_callback, {
		buffer = view.buf,
		desc = "custom callback",
		expr = false,
	})
	vim.keymap.set("n", "z", "G", { buffer = view.buf, remap = true })
	pcall(vim.keymap.del, "n", "<Esc>", { buffer = view.buf })

	local before = {}
	for _, lhs in ipairs({ "a", "<Space>", "<CR>", "q", "<Esc>", "z" }) do
		before[lhs] = mapping_signature(find_mapping(lhs)) or false
	end
	local selector = {
		root_id = "selector-root",
		selected_id = "selector-file",
		entries = {
			["selector-root"] = {
				id = "selector-root",
				kind = "directory",
				name = "workspace",
				expandable = true,
				selectable = false,
				icon_hint = "folder",
				availability = "ineligible",
				git_states = {},
			},
			["selector-file"] = {
				id = "selector-file",
				parent_id = "selector-root",
				kind = "file",
				name = "New.cs",
				expandable = false,
				selectable = true,
				icon_hint = "cs",
				availability = "available",
				git_states = {},
			},
		},
		children = { ["selector-root"] = { "selector-file" } },
		expanded = { ["selector-root"] = true },
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
	local actions = {
		activate = function() end,
		close = function() end,
	}
	view.enter_selector(selector, actions, tree)
	assert_equal(view.buf, vim.api.nvim_win_get_buf(view.win), "selector reuses the same drawer")
	assert_equal(41, vim.api.nvim_win_get_width(view.win), "selector keeps user width")
	assert_equal(nil, find_mapping("a"), "semantic New key is absent in selector mode")
	find_mapping("<Space>").callback()
	assert_equal(1, selector.toggles, "Space calls the selector-private toggle")
	for _, lhs in ipairs({ "<CR>", "q", "<Esc>" }) do
		local action = lhs == "<CR>" and "activate" or "close"
		assert(find_mapping(lhs).callback == actions[action])
	end
	assert_equal(before.z, mapping_signature(find_mapping("z")), "unrelated mapping stays untouched")

	vim.api.nvim_win_set_width(view.win, 48)
	view.leave_selector(tree)
	for _, lhs in ipairs({ "a", "<Space>", "<CR>", "q", "<Esc>", "z" }) do
		assert_equal(
			before[lhs],
			mapping_signature(find_mapping(lhs)) or false,
			lhs .. " exact restoration"
		)
	end
	assert(find_mapping("a").callback == plugin_owned, "plugin-owned callback identity is restored")
	find_mapping("a").callback()
	assert_equal(1, semantic_new_calls, "restored semantic New mapping remains active")
	assert_equal(41, vim.api.nvim_win_get_width(view.win), "semantic drawer restores user width")
	assert_equal("semantic-15", tree.selected_id, "semantic ID selection is restored")
	assert_equal("right", config.get().position, "dock side is unchanged")
	view.close()
end)

scenario(
	"success cancellation failure staleness invalidation and replacement restore every modal mapping",
	function()
		local mapping_keys = { "a", "<Space>", "<CR>", "q", "<Esc>" }
		local function exercise(name, options, exit)
			local tree = semantic_tree()
			local semantic_actions = setmetatable({}, {
				__index = function()
					return function() end
				end,
			})
			local modal_actions = {
				activate = function() end,
				close = function() end,
			}
			config.setup({
				mappings = {
					activate = false,
					close = false,
					new = "a",
				},
			})
			view.open()
			for _, lhs in ipairs(mapping_keys) do
				pcall(vim.keymap.del, "n", lhs, { buffer = view.buf })
			end
			view.mappings(semantic_actions)
			vim.api.nvim_buf_set_keymap(view.buf, "n", "<Space>", "j", {
				noremap = true,
				nowait = true,
				silent = true,
			})
			vim.api.nvim_buf_set_keymap(view.buf, "n", "<CR>", "zz", {
				noremap = false,
				nowait = false,
				silent = false,
			})
			vim.keymap.set("n", "q", function() end, {
				buffer = view.buf,
				desc = "custom cancellation",
			})
			vim.api.nvim_buf_set_keymap(view.buf, "n", "<Esc>", "<Nop>", {
				noremap = true,
				nowait = false,
				silent = true,
			})
			view.render(tree)
			local before = {}
			for _, lhs in ipairs(mapping_keys) do
				before[lhs] = mapping_signature(find_mapping(lhs)) or false
			end
			options = vim.tbl_extend("force", options or {}, {
				on_enter = function(active)
					view.enter_selector(active, modal_actions, tree)
				end,
				on_render = function(active)
					view.render_selector(active)
				end,
				on_leave = function()
					view.leave_selector(tree)
				end,
			})
			local state = harness(options)
			state.start()
			assert_equal(nil, find_mapping("a"), name .. " removes semantic New")
			assert(find_mapping("<Space>"), name .. " installs Space")
			exit(state)
			for _, lhs in ipairs(mapping_keys) do
				assert_equal(
					before[lhs],
					mapping_signature(find_mapping(lhs)) or false,
					name .. " restores " .. lhs
				)
			end
			view.close()
		end

		exercise("success", nil, function(state)
			local original_input = vim.ui.input
			vim.ui.input = function(_, callback)
				callback("y")
			end
			state.selector:toggle()
			state.selector:confirm()
			vim.ui.input = original_input
		end)
		exercise("cancellation", nil, function(state)
			state.selector:cancel()
		end)
		exercise("failure", {
			request = function(method, parameters, callback)
				if
					method == "workspace/addExisting/children"
					and parameters.parentEntryId == "directory-1"
				then
					callback({ code = "selector_failed", message = "failed" })
					return true
				end
			end,
		}, function(state)
			state.select("directory-1")
			state.selector:expand()
		end)
		exercise("staleness", nil, function(state)
			state.selector:workspace_changed(8)
		end)
		exercise("invalidation", nil, function(state)
			state.selector:invalidate(true)
		end)
		exercise("session replacement", nil, function(state)
			state.start()
			assert_equal(nil, find_mapping("a"), "replacement keeps semantic New removed")
			assert(find_mapping("<Space>"), "replacement keeps Space installed")
			state.selector:cancel()
		end)
	end
)

scenario("selector-devicons-disabled-missing-and-available", function()
	local selector = {
		root_id = "root",
		selected_id = "file",
		entries = {
			root = {
				id = "root",
				kind = "directory",
				name = "workspace",
				expandable = true,
				selectable = false,
				icon_hint = "folder",
				availability = "ineligible",
				git_states = { "unstaged", "ignored" },
			},
			file = {
				id = "file",
				parent_id = "root",
				kind = "file",
				name = "Opaque",
				expandable = false,
				selectable = true,
				icon_hint = "fs",
				availability = "available",
				git_states = {
					"staged",
					"unstaged",
					"renamed",
					"deleted",
					"unmerged",
					"untracked",
					"ignored",
				},
			},
		},
		children = { root = { "file" } },
		expanded = { root = true },
		marks = {},
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

	config.setup()
	view.open()
	view.render_selector(selector)
	local lines = vim.api.nvim_buf_get_lines(view.buf, 0, -1, false)
	assert_equal(
		"  F ✓✗➜★◌ Opaque",
		lines[2],
		"disabled Devicons fallback with every ordered Git state"
	)

	config.setup({ presentation = { devicons = true } })
	package.loaded["nvim-web-devicons"] = nil
	package.preload["nvim-web-devicons"] = function()
		error("missing")
	end
	view.render_selector(selector)
	lines = vim.api.nvim_buf_get_lines(view.buf, 0, -1, false)
	assert_equal("  F ✓✗➜★◌ Opaque", lines[2], "missing Devicons fallback")

	local lookup
	package.loaded["nvim-web-devicons"] = {
		get_icon = function(name, extension, options)
			lookup = { name, extension, options }
			return "λ", "DevIconFs"
		end,
	}
	view.render_selector(selector)
	lines = vim.api.nvim_buf_get_lines(view.buf, 0, -1, false)
	assert_equal({ "Opaque", "fs", { default = true } }, lookup, "core icon hint is passed opaquely")
	assert(
		lines[2]:find("λ ✓✗➜★◌ Opaque", 1, true),
		"available Devicon and every Git state are rendered"
	)

	selector.marks.file = true
	view.render_selector(selector)
	local namespace = vim.api.nvim_get_namespaces()["dotnet-workspace-explorer"]
	local extmarks = vim.api.nvim_buf_get_extmarks(view.buf, namespace, 0, -1, { details = true })
	local signs = {}
	for _, extmark in ipairs(extmarks) do
		if extmark[4].sign_text then
			signs[#signs + 1] = vim.trim(extmark[4].sign_text)
		end
	end
	assert_equal({ "󰆤" }, signs, "marked target uses bookmark sign")

	selector.marks.file = nil
	selector.entries.file.availability = "alreadyPresent"
	view.render_selector(selector)
	extmarks = vim.api.nvim_buf_get_extmarks(view.buf, namespace, 0, -1, { details = true })
	signs = {}
	for _, extmark in ipairs(extmarks) do
		if extmark[4].sign_text then
			signs[#signs + 1] = vim.trim(extmark[4].sign_text)
		end
	end
	assert_equal({ "✓" }, signs, "already-present file uses distinct sign")

	selector.entries.file.availability = "ineligible"
	view.render_selector(selector)
	extmarks = vim.api.nvim_buf_get_extmarks(view.buf, namespace, 0, -1, { details = true })
	for _, extmark in ipairs(extmarks) do
		assert_equal(nil, extmark[4].sign_text, "selector sign is cleared when eligibility changes")
	end
	view.close()
end)

scenario("mode-aware-public-and-configured-action-routing", function()
	local Editing = require("dotnet-workspace-explorer.editing").Editing
	local Mutations = require("dotnet-workspace-explorer.mutations").Mutations
	local SelectorClass = require("dotnet-workspace-explorer.selector").Selector
	local originals = {
		workspace = Workspace.new,
		editing = Editing.new,
		mutations = Mutations.new,
		selector = SelectorClass.new,
	}
	local active_selector, mutation_creates
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
	Editing.new = function()
		return {
			reconcile = function() end,
			invalidate = function() end,
		}
	end
	Mutations.new = function()
		return {
			create = function()
				mutation_creates = (mutation_creates or 0) + 1
			end,
			invalidate = function() end,
		}
	end
	SelectorClass.new = function()
		active_selector = {
			engaged = true,
			calls = {},
		}
		function active_selector:is_engaged()
			return self.engaged
		end
		for _, action in ipairs({ "toggle", "activate", "cancel", "expand", "collapse" }) do
			active_selector[action] = function(self)
				self.calls[#self.calls + 1] = action
			end
		end
		function active_selector:invalidate()
			self.engaged = false
		end
		active_selector.workspace_changed = function(_) end
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
	assert_equal({}, active_selector.calls, "configured and public New actions are inert")
	for _, mapping in ipairs({
		{ lhs = "o", action = "activate" },
		{ lhs = "x", action = "cancel" },
		{ lhs = "L", action = "expand" },
		{ lhs = "H", action = "collapse" },
	}) do
		find_mapping(mapping.lhs).callback()
		assert_equal(
			mapping.action,
			active_selector.calls[#active_selector.calls],
			mapping.lhs .. " configured selector action"
		)
	end
	assert_equal(nil, mutation_creates, "configured New never reaches semantic mutation in selector")
	active_selector.engaged = false
	find_mapping("n").callback()
	assert_equal(1, mutation_creates, "configured semantic New works after selector exit")
	public.close()

	Workspace.new, Editing.new, Mutations.new, SelectorClass.new =
		originals.workspace, originals.editing, originals.mutations, originals.selector
	package.loaded["dotnet-workspace-explorer"] = nil
end)

print("DWE-019 transient selector scenarios passed")
