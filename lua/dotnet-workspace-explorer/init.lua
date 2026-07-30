local config = require("dotnet-workspace-explorer.config")

local M = {}

function M.setup(options)
	config.setup(options)
end

function M._register_commands()
	require("dotnet-workspace-explorer.commands").register()
end

return M
