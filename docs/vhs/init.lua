local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
vim.opt.shortmess:append("I")
vim.o.cmdheight = 1
vim.o.laststatus = 2
vim.o.more = false
vim.o.showmode = false

local position = assert(vim.env.DWE_POSITION, "DWE_POSITION is required")
assert(position == "left" or position == "right", "DWE_POSITION must be left or right")

vim.ui.input = function(options, callback)
	vim.fn.inputsave()
	local value = vim.fn.input(options.prompt or "")
	vim.fn.inputrestore()
	callback(value)
end

vim.ui.select = function(_, options, callback)
	vim.fn.inputsave()
	local choice = vim.fn.input((options.prompt or "Select") .. " [Create/Cancel]: ")
	vim.fn.inputrestore()
	callback(choice == "Create" and "Create" or "Cancel")
end

local explorer = require("dotnet-workspace-explorer")
explorer.setup({
	command = assert(vim.env.DWE_CORE, "DWE_CORE is required"),
	target = function()
		return assert(vim.env.DWE_FIXTURE, "DWE_FIXTURE is required")
	end,
	position = position,
	presentation = { devicons = false },
	width = 40,
	mappings = {
		activate = "<CR>",
		collapse = "h",
		expand = "l",
		add_file = "a",
		refresh = "R",
		close = "q",
	},
})

vim.cmd.colorscheme("habamax")
explorer._register_commands()
vim.cmd("DotnetWorkspaceExplorerOpen")
