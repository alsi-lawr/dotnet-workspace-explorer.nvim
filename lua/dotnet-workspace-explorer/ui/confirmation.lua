local M = {}

---Prompts for an explicit `y` response; every other answer is false.
---@param prompt string
---@param callback DweBooleanCallback
function M.yes_no(prompt, callback)
	vim.ui.input({
		prompt = prompt .. "\nConfirm [y/N]: ",
		kind = "confirmation",
	}, function(answer)
		callback(type(answer) == "string" and answer:lower() == "y")
	end)
end

return M
