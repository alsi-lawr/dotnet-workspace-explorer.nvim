local M = {}

---@return DweConfig
function M.create()
	return {
		command = "dotnet-we",
		package_command = "dotnet-pe",
		target = function()
			return vim.fn.getcwd()
		end,
		position = "left",
		presentation = {
			devicons = false,
		},
		git = {
			enable = true,
		},
		width = 30,
		glyphs = {
			closed = "",
			open = "",
			leaf = "",
			solution = "S",
			project = "P",
			folder = "D",
			file = "F",
		},
		mappings = {
			activate = "<CR>",
			collapse = "h",
			collapse_all = "W",
			edit = "e",
			expand = "l",
			expand_all = "E",
			git_refresh = false,
			clear_marks = false,
			mark_copy = "c",
			mark_move = "m",
			new = "a",
			packages = "P",
			place = "p",
			delete = "d",
			refresh = "R",
			rename = "r",
			close = "q",
		},
	}
end

return M
