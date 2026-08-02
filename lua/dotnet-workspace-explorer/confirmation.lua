local M = {}

function M.yes_no(prompt)
	return vim.fn.confirm(prompt, "&Yes\n&No", 2) == 1
end

return M
