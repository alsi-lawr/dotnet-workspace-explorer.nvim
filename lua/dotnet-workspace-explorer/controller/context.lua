---Session-scoped mutable references shared by controller modules.
---@class DweControllerContext
---@field actions? table
---@field tree? DweWorkspaceTree
---@field mutations? table
---@field selector? table
---@field editing? table
---@field git_status? table
---@field target? string
---@field initial_failed? boolean
---@field terminal_failed? boolean
---@field has_good? boolean

---@type DweControllerContext
local context = {}
return context
