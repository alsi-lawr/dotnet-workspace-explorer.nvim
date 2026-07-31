local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local devicons_root = assert(vim.env.DWE_DEVICONS, "DWE_DEVICONS is required")
vim.opt.runtimepath:prepend(devicons_root)

vim.opt.shortmess:append("I")
vim.o.cmdheight = 1
vim.o.laststatus = 2
vim.o.more = false
vim.o.showmode = false
vim.o.termguicolors = true

local position = assert(vim.env.DWE_POSITION, "DWE_POSITION is required")
assert(position == "left" or position == "right", "DWE_POSITION must be left or right")

vim.ui.input = function(options, callback)
	vim.fn.inputsave()
	local value = vim.fn.input(options.prompt or "")
	vim.fn.inputrestore()
	callback(value)
end

vim.ui.select = function(items, options, callback)
	local labels = {}
	for index, item in ipairs(items) do
		labels[index] = type(item) == "table" and item.displayName or tostring(item)
	end
	vim.fn.inputsave()
	local choice = tonumber(
		vim.fn.input((options.prompt or "Select") .. " [" .. table.concat(labels, "/") .. "]: ")
	)
	vim.fn.inputrestore()
	callback(items[choice])
end

local explorer = require("dotnet-workspace-explorer")
require("nvim-web-devicons").setup()
explorer.setup({
	command = assert(vim.env.DWE_CORE, "DWE_CORE is required"),
	target = function()
		return assert(vim.env.DWE_FIXTURE, "DWE_FIXTURE is required")
	end,
	position = position,
	presentation = { devicons = true },
	width = 52,
	mappings = {
		activate = "<CR>",
		collapse = "h",
		expand = "l",
		new = "a",
		delete = "d",
		refresh = "R",
		close = "q",
	},
})

vim.cmd.colorscheme("habamax")
explorer._register_commands()
vim.cmd("DotnetWorkspaceExplorerOpen")
