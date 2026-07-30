local M = {}

local command_specs = {
	{ name = "DotnetWorkspaceExplorerOpen", action = "open", nargs = "?" },
	{ name = "DotnetWorkspaceExplorerClose", action = "close", nargs = 0 },
	{ name = "DotnetWorkspaceExplorerToggle", action = "toggle", nargs = "?" },
	{ name = "DotnetWorkspaceExplorerFocus", action = "focus", nargs = 0 },
	{ name = "DotnetWorkspaceExplorerRefresh", action = "refresh", nargs = 0 },
	{ name = "DotnetWorkspaceExplorerActivate", action = "activate", nargs = 0 },
	{ name = "DotnetWorkspaceExplorerExpand", action = "expand", nargs = 0 },
	{ name = "DotnetWorkspaceExplorerCollapse", action = "collapse", nargs = 0 },
	{ name = "DotnetWorkspaceExplorerAddFile", action = "add_file", nargs = "?" },
}

local function callback(action, accepts_argument)
	return function(args)
		local public = require("dotnet-workspace-explorer")
		if accepts_argument then
			return public[action](args.args ~= "" and args.args or nil)
		end
		return public[action]()
	end
end

function M.register()
	for _, spec in ipairs(command_specs) do
		vim.api.nvim_create_user_command(spec.name, callback(spec.action, spec.nargs == "?"), {
			nargs = spec.nargs,
			force = true,
		})
	end
end

return M
