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

local function assert_contains(values, expected, message)
	for _, value in ipairs(values) do
		if value == expected then
			return
		end
	end

	error(
		("%s\nexpected collection to contain: %s\nactual: %s"):format(
			message,
			vim.inspect(expected),
			vim.inspect(values)
		)
	)
end

local function assert_not_contains(values, unexpected, message)
	for _, value in ipairs(values) do
		if value == unexpected then
			error(
				("%s\nunexpected value: %s\nactual: %s"):format(
					message,
					vim.inspect(unexpected),
					vim.inspect(values)
				)
			)
		end
	end
end

local config = require("dotnet-workspace-explorer.config")
local renderer = require("dotnet-workspace-explorer.ui.renderer")

local buffer = vim.api.nvim_create_buf(false, true)
local namespace = vim.api.nvim_create_namespace("dwe-renderer-highlights-test")

---@type DweViewState
local state = {
	buf = buffer,
	rows = {},
	owned_mappings = {},
	ns = namespace,
}

local nodes = {
	workspace = {
		id = "workspace",
		kind = "workspace",
		name = "Example.slnx",
	},
	file = {
		id = "file",
		parent_id = "workspace",
		kind = "projectFile",
		name = "Program.cs",
	},
}

local selected_id = "file"
local metadata = {}

local tree = {
	nodes = nodes,
	children = {
		workspace = { "file" },
	},
	roots = { "workspace" },
	expanded = {
		workspace = true,
	},
	decorations = {},
	marks = {},
	phase = "ready",
}

function tree:get_node(id)
	return self.nodes[id]
end

function tree:presentation_node(id)
	return self:get_node(id)
end

function tree.is_expandable(_, id)
	return id == "workspace"
end

function tree:children_of(id)
	return self.children[id]
end

function tree:presentation_children_of(id)
	return self:children_of(id)
end

function tree:presentation_metadata(id)
	return metadata[id]
		or {
			loading = false,
			provisional = false,
			actionable = self.nodes[id] ~= nil,
		}
end

function tree.select(_, id)
	selected_id = id
end

setmetatable(tree, {
	__index = function(_, key)
		if key == "selected_id" then
			return selected_id
		end
	end,
})

local original_add_highlight = vim.api.nvim_buf_add_highlight
local original_devicons_loaded = package.loaded["nvim-web-devicons"]
local original_devicons_preload = package.preload["nvim-web-devicons"]

local highlights = {}

local function capture_highlights()
	highlights = {}

	vim.api.nvim_buf_add_highlight = function(buf, ns, group, line, start, finish)
		highlights[#highlights + 1] = {
			buf = buf,
			ns = ns,
			group = group,
			line = line,
			start = start,
			finish = finish,
		}

		return 0
	end
end

local function groups()
	local result = {}

	for _, highlight in ipairs(highlights) do
		result[#result + 1] = highlight.group
	end

	return result
end

local function cleanup()
	vim.api.nvim_buf_add_highlight = original_add_highlight
	package.loaded["nvim-web-devicons"] = original_devicons_loaded
	package.preload["nvim-web-devicons"] = original_devicons_preload

	if vim.api.nvim_buf_is_valid(buffer) then
		vim.api.nvim_buf_delete(buffer, { force = true })
	end

	config.setup()
end

local ok, err = xpcall(function()
	-- Fallback icons should use the plugin's semantic highlight groups.
	config.setup({
		presentation = {
			devicons = false,
		},
	})

	capture_highlights()
	renderer.tree(state, tree)

	local fallback_groups = groups()

	assert_contains(
		fallback_groups,
		"DotnetWorkspaceExplorerSolution",
		"workspace fallback icon should use the solution highlight"
	)

	assert_contains(
		fallback_groups,
		"DotnetWorkspaceExplorerFile",
		"file fallback icon and name should use the file highlight"
	)

	assert_equal(
		{ "S Example.slnx", "  F Program.cs" },
		vim.api.nvim_buf_get_lines(buffer, 0, -1, false),
		"renderer should produce the expected fallback presentation"
	)

	-- Devicon groups must be used directly. They must not have the semantic
	-- node-group suffix appended to them.
	config.setup({
		presentation = {
			devicons = true,
		},
	})

	package.loaded["nvim-web-devicons"] = nil
	package.preload["nvim-web-devicons"] = function()
		return {
			get_icon = function(name)
				if name == "workspace.slnx" then
					return "W", "DevIconSolution"
				end

				if name == "Program.cs" then
					return "C", "DevIconCs"
				end

				error("unexpected devicon lookup: " .. tostring(name))
			end,
		}
	end

	capture_highlights()
	renderer.tree(state, tree)

	local devicon_groups = groups()

	assert_contains(
		devicon_groups,
		"DevIconSolution",
		"workspace icon should preserve its devicon highlight group"
	)

	assert_contains(
		devicon_groups,
		"DevIconCs",
		"file icon should preserve its devicon highlight group"
	)

	assert_not_contains(
		devicon_groups,
		"DevIconSolutionSolution",
		"workspace semantic group must not be appended to the devicon group"
	)

	assert_not_contains(
		devicon_groups,
		"DevIconCsFile",
		"file semantic group must not be appended to the devicon group"
	)

	-- Names remain semantically themed independently of their icons.
	assert_contains(
		devicon_groups,
		"DotnetWorkspaceExplorerSolution",
		"workspace name should retain its semantic highlight"
	)

	assert_contains(
		devicon_groups,
		"DotnetWorkspaceExplorerFile",
		"file name should retain its semantic highlight"
	)

	assert_equal(
		{ "W Example.slnx", "  C Program.cs" },
		vim.api.nvim_buf_get_lines(buffer, 0, -1, false),
		"renderer should use the resolved devicons"
	)

	assert_equal("file", selected_id, "rendering should preserve semantic selection")

	metadata.workspace = {
		loading = true,
		provisional = false,
		actionable = true,
		parent_id = "workspace",
	}
	metadata.file = {
		loading = true,
		provisional = true,
		actionable = false,
		parent_id = "workspace",
	}
	tree.marks.file = true
	tree.decorations.file = { "unstaged" }
	capture_highlights()
	renderer.tree(state, tree)
	local staged_groups = groups()
	assert_contains(
		staged_groups,
		"DotnetWorkspaceExplorerLoading",
		"the canonical loading parent uses its loading highlight"
	)
	assert_contains(
		staged_groups,
		"DotnetWorkspaceExplorerProvisional",
		"provisional rows use their read-only highlight"
	)
	assert_equal(
		{ "W Example.slnx (loading)", "  C Program.cs (provisional, read-only)" },
		vim.api.nvim_buf_get_lines(buffer, 0, -1, false),
		"staged presentation explicitly distinguishes loading and provisional rows"
	)
	assert_equal(false, state.rows[2].actionable, "a provisional render row is non-actionable")
	assert_equal(nil, state.rows[2].sign, "a provisional render row has no canonical sign")
end, debug.traceback)

cleanup()

if not ok then
	error(err)
end

print("DWE renderer highlight tests passed")
