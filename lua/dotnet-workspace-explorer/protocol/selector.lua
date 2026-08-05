local value = require("dotnet-workspace-explorer.protocol.value")

local M = {}

---@param token unknown
---@return boolean
local function valid_next_token(token)
	return token == nil or value.is_nonempty_string(token)
end

---Validates the first Add Existing selector page.
---@param result unknown
---@param revision integer
---@param page_size integer
---@return boolean
function M.valid_start(result, revision, page_size)
	if not value.is_map(result) then
		return false
	end
	return result.revision == revision
		and value.is_nonempty_string(result.selectorId)
		and value.is_nonempty_string(result.expiresAtUtc)
		and result.maxSelectionCount == 256
		and type(result.entries) == "table"
		and vim.islist(result.entries)
		and #result.entries <= page_size
		and valid_next_token(result.nextToken)
end

---Validates a paged Add Existing children response.
---@param result unknown
---@param selector_id string
---@param parent_id string
---@param revision integer
---@param page_size integer
---@return boolean
function M.valid_page(result, selector_id, parent_id, revision, page_size)
	if not value.is_map(result) then
		return false
	end
	return result.revision == revision
		and result.selectorId == selector_id
		and result.parentEntryId == parent_id
		and type(result.entries) == "table"
		and vim.islist(result.entries)
		and #result.entries <= page_size
		and valid_next_token(result.nextToken)
end

return M
