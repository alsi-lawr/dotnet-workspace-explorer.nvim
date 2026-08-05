local M = {}

---Creates a recursive copy while preserving metatables.
---@generic T
---@param value T
---@return T
function M.deep_copy(value)
	if type(value) ~= "table" then
		return value
	end

	local result = setmetatable({}, getmetatable(value))
	for key, item in pairs(value) do
		result[M.deep_copy(key)] = M.deep_copy(item)
	end
	return result
end

---Recursively overlays `overrides` onto `base` without mutating either input.
---@generic T: table
---@param base T
---@param overrides table
---@return T
function M.deep_merge(base, overrides)
	local result = M.deep_copy(base)
	for key, value in pairs(overrides) do
		if type(value) == "table" and type(result[key]) == "table" then
			result[key] = M.deep_merge(result[key], value)
		else
			result[key] = M.deep_copy(value)
		end
	end
	return result
end

---Copies a key/value table one level deep.
---@generic K, V
---@param values table<K, V>
---@return table<K, V>
function M.copy_map(values)
	local result = {}
	for key, value in pairs(values) do
		result[key] = value
	end
	return result
end

---Copies a list one level deep.
---@generic T
---@param values? T[]
---@return T[]
function M.copy_list(values)
	local result = {}
	for index, value in ipairs(values or {}) do
		result[index] = value
	end
	return result
end

return M
