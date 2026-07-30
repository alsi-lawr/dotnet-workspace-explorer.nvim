# dotnet-workspace-explorer.nvim

A lightweight Neovim solution explorer powered by
[`dotnet-workspace-explorer`](https://github.com/alsi-lawr/dotnet-workspace-explorer).

The plugin uses native Neovim APIs and has no runtime plugin dependencies.

## Configuration

```lua
require("dotnet-workspace-explorer").setup({
	command = "dotnet-workspace-explorer",
	target = function()
		return vim.fn.getcwd()
	end,
	position = "left",
	width = 30,
})
```

Loading and configuring the plugin is inert. Explorer processes and windows are created only by
explicit explorer actions.

## Commands

The plugin registers these public commands:

- `:DotnetWorkspaceExplorerOpen [target]`
- `:DotnetWorkspaceExplorerClose`
- `:DotnetWorkspaceExplorerToggle [target]`
- `:DotnetWorkspaceExplorerFocus`
- `:DotnetWorkspaceExplorerRefresh`
- `:DotnetWorkspaceExplorerActivate`
- `:DotnetWorkspaceExplorerExpand`
- `:DotnetWorkspaceExplorerCollapse`
- `:DotnetWorkspaceExplorerAddFile [path]`

## Development

Enter the locked development shell:

```sh
nix develop
```

Check the Lua sources:

```sh
stylua --check lua plugin
luacheck lua plugin
```

The development shell includes the .NET SDK and the Go, Chromium, ttyd, and FFmpeg tooling needed
to build the sibling Workspace Explorer and the working-tree `../vhs` fork for local visual checks.

## License

[MIT](LICENSE)
