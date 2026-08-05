local actions = require("dotnet-workspace-explorer.controller.actions")
local context = require("dotnet-workspace-explorer.controller.context")
local session = require("dotnet-workspace-explorer.controller.session")

local M = {
	setup = session.setup,
	open = session.open,
	close = session.close,
	toggle = session.toggle,
	focus = session.focus,
	refresh = session.refresh,
}

for name, action in pairs(actions) do
	M[name] = action
end
context.actions = M

function M._register_commands()
	require("dotnet-workspace-explorer.controller.commands").register()
end

return M
