local M = {}

---Constructs a protocol problem value.
---@param code string
---@param message string
---@param data? unknown
---@return DweProblem
function M.problem(code, message, data)
	return { code = code, message = message, data = data }
end

---Returns a MessagePack map with no fields rather than an empty array.
---@return table
function M.empty()
	return vim.empty_dict()
end

---@param stderr string
---@return string
function M.exit_message(stderr)
	local message = stderr:gsub("^%s+", ""):gsub("%s+$", "")
	return message ~= "" and message or "Workspace process exited."
end

return M
