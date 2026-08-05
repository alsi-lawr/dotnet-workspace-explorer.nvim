local M = {}

---@param value unknown
---@return boolean
function M.is_map(value)
	return type(value) == "table" and not vim.islist(value)
end

---@param value unknown
---@return boolean
function M.is_integer(value)
	return type(value) == "number" and value >= 0 and value % 1 == 0
end

---@param value unknown
---@return boolean
function M.is_nonempty_string(value)
	return type(value) == "string" and value ~= ""
end

---@param value unknown
---@param keys table<string, boolean>
---@return boolean
function M.has_required_keys(value, keys)
	if not M.is_map(value) then
		return false
	end
	for key in pairs(keys) do
		if value[key] == nil then
			return false
		end
	end
	return true
end

---@param value unknown
---@param allowed table<string, boolean>
---@return boolean
function M.has_only_keys(value, allowed)
	if not M.is_map(value) then
		return false
	end
	for key in pairs(value) do
		if not allowed[key] then
			return false
		end
	end
	return true
end

---@param value unknown
---@param allow_empty? boolean
---@return string[]?
function M.unique_string_list(value, allow_empty)
	if type(value) ~= "table" or not vim.islist(value) or (not allow_empty and #value == 0) then
		return nil
	end
	local seen, result = {}, {}
	for index, item in ipairs(value) do
		if not M.is_nonempty_string(item) or seen[item] then
			return nil
		end
		seen[item], result[index] = true, item
	end
	return result
end

return M
