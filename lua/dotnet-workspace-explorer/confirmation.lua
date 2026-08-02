local M = {}

function M.yes_no(prompt, callback)
	vim.ui.input({
		prompt = prompt .. "\nConfirm [y/N]: ",
		default = "N",
		kind = "confirmation",
	}, function(answer)
		callback(type(answer) == "string" and answer:lower() == "y")
	end)
end

return M
