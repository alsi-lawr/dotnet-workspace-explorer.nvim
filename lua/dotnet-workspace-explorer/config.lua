local M = {}

local mapping_names = {
	activate = true,
	add_file = true,
	close = true,
	collapse = true,
	expand = true,
	refresh = true,
}

local function defaults()
	return {
		command = "dotnet-workspace-explorer",
		target = function()
			return vim.fn.getcwd()
		end,
		position = "left",
		presentation = {
			devicons = false,
		},
		width = 30,
		glyphs = {
			closed = ">",
			open = "v",
			leaf = " ",
			solution = "S",
			project = "P",
			folder = "D",
			file = "F",
		},
		mappings = {
			activate = "<CR>",
			collapse = "h",
			expand = "l",
			add_file = "a",
			refresh = "R",
			close = "q",
		},
		actions = {
			add_file = {
				item_type = "Compile",
			},
		},
	}
end

local current = defaults()

local function fail(message)
	error("dotnet-workspace-explorer: " .. message, 3)
end

local function ensure_table(value, path)
	if type(value) ~= "table" then
		fail(path .. " must be a table")
	end
end

local function ensure_known_keys(value, allowed, path)
	for key in pairs(value) do
		if not allowed[key] then
			fail(path .. "." .. tostring(key) .. " is not a supported option")
		end
	end
end

local function copy(value)
	if type(value) ~= "table" then
		return value
	end

	local result = setmetatable({}, getmetatable(value))
	for key, item in pairs(value) do
		result[key] = copy(item)
	end
	return result
end

local function merge(base, overrides)
	local result = copy(base)
	for key, value in pairs(overrides) do
		if type(value) == "table" and type(result[key]) == "table" then
			result[key] = merge(result[key], value)
		else
			result[key] = copy(value)
		end
	end
	return result
end

local function validate_input(options)
	ensure_table(options, "options")
	ensure_known_keys(options, {
		command = true,
		target = true,
		position = true,
		presentation = true,
		width = true,
		glyphs = true,
		mappings = true,
		actions = true,
	}, "options")

	if options.presentation ~= nil then
		ensure_table(options.presentation, "presentation")
		ensure_known_keys(options.presentation, { devicons = true }, "presentation")
	end

	if options.glyphs ~= nil then
		ensure_table(options.glyphs, "glyphs")
		ensure_known_keys(options.glyphs, {
			closed = true,
			open = true,
			leaf = true,
			solution = true,
			project = true,
			folder = true,
			file = true,
		}, "glyphs")
	end

	if options.mappings ~= nil and options.mappings ~= false then
		ensure_table(options.mappings, "mappings")
		ensure_known_keys(options.mappings, mapping_names, "mappings")
	end

	if options.actions ~= nil then
		ensure_table(options.actions, "actions")
		ensure_known_keys(options.actions, { add_file = true }, "actions")
		if options.actions.add_file ~= nil then
			ensure_table(options.actions.add_file, "actions.add_file")
			ensure_known_keys(options.actions.add_file, { item_type = true }, "actions.add_file")
		end
	end
end

local function validate(options)
	if type(options.command) ~= "string" or options.command == "" then
		fail("command must be a non-empty string")
	end
	local target_metatable = type(options.target) == "table" and getmetatable(options.target) or nil
	local target_is_callable = type(options.target) == "function"
		or (target_metatable ~= nil and type(target_metatable.__call) == "function")
	if not target_is_callable then
		fail("target must be callable")
	end
	if options.position ~= "left" and options.position ~= "right" then
		fail("position must be 'left' or 'right'")
	end
	if type(options.presentation.devicons) ~= "boolean" then
		fail("presentation.devicons must be a boolean")
	end
	if type(options.width) ~= "number" or options.width <= 0 or options.width % 1 ~= 0 then
		fail("width must be a positive integer")
	end

	for name, glyph in pairs(options.glyphs) do
		if type(glyph) ~= "string" then
			fail("glyphs." .. name .. " must be a string")
		end
	end

	if options.mappings ~= false then
		for name, mapping in pairs(options.mappings) do
			if mapping ~= false and (type(mapping) ~= "string" or mapping == "") then
				fail("mappings." .. name .. " must be a non-empty string or false")
			end
		end
	end

	local item_type = options.actions.add_file.item_type
	if type(item_type) ~= "string" or item_type == "" then
		fail("actions.add_file.item_type must be a non-empty string")
	end
end

function M.setup(options)
	if options == nil then
		options = {}
	end
	validate_input(options)
	local candidate = merge(defaults(), options)
	validate(candidate)
	current = candidate
end

function M.get()
	return current
end

return M
