# dotnet-workspace-explorer.nvim

A development-stage Neovim solution explorer powered by
[`dotnet-workspace-explorer`](https://github.com/alsi-lawr/dotnet-workspace-explorer).
The core owns the solution, project, folder, file, and dependency hierarchy; this plugin renders it
with native Neovim APIs.

![Semantic workspace explorer docked on both sides of Neovim](docs/assets/explorer.webp)

## Development checkout

This repository is not packaged or released. Put a checkout on `runtimepath` and configure the
separate core executable:

```lua
vim.opt.runtimepath:prepend("/path/to/dotnet-workspace-explorer.nvim")

require("dotnet-workspace-explorer").setup({
	command = "dotnet-workspace-explorer",
	target = function()
		return vim.fn.getcwd()
	end,
})
```

`command` may instead be the absolute path to a locally built apphost. `target` must resolve to a
workspace accepted by the core, such as an unambiguous `.sln` or `.slnx`. Loading the plugin and
calling `setup` are inert: neither starts the core nor creates a window.

## Configuration

The complete configuration surface and defaults are:

```lua
require("dotnet-workspace-explorer").setup({
	command = "dotnet-workspace-explorer",
	target = function()
		return vim.fn.getcwd()
	end,
	position = "left", -- "left" or "right"
	width = 30,
	presentation = {
		devicons = false,
	},
	glyphs = {
		closed = ">",
		open = "v",
		leaf = "-",
		solution = "S",
		project = "P",
		folder = "D",
		file = "F",
	},
	mappings = {
		activate = "<CR>",
		collapse = "h",
		expand = "l",
		add_file = "a",
		refresh = "R",
		close = "q",
	},
	actions = {
		add_file = {
			item_type = "Compile",
		},
	},
})
```

Rows use highlight links rather than a fixed palette, so colours follow the active theme.
[`nvim-web-devicons`](https://github.com/nvim-tree/nvim-web-devicons) is optional. To use it, load
and configure Devicons before this plugin, then set `presentation.devicons = true`. Only file rows
are queried. A missing module, unknown icon, or failed lookup silently uses the configured file
glyph; the plugin does not require or configure Devicons.

The explorer is an ordinary scrollable `nofile` split. Reopening applies `width`; subsequent
renders preserve a manual resize.

### Mappings

Mappings are buffer-local conveniences. Disable all mappings without disabling commands:

```lua
require("dotnet-workspace-explorer").setup({ mappings = false })
```

Disable or replace mappings by action:

```lua
require("dotnet-workspace-explorer").setup({
	mappings = {
		activate = "o",
		collapse = false,
		expand = "L",
		add_file = "A",
		refresh = "<F5>",
		close = "Q",
	},
})
```

Existing user-defined buffer mappings are not overwritten.

## Commands and focus

- `:DotnetWorkspaceExplorerOpen [target]`
- `:DotnetWorkspaceExplorerClose`
- `:DotnetWorkspaceExplorerToggle [target]`
- `:DotnetWorkspaceExplorerFocus`
- `:DotnetWorkspaceExplorerRefresh`
- `:DotnetWorkspaceExplorerActivate`
- `:DotnetWorkspaceExplorerExpand`
- `:DotnetWorkspaceExplorerCollapse`
- `:DotnetWorkspaceExplorerAddFile [path]`

`Open`, `Refresh`, `Activate`, `Expand`, and `Collapse` preserve the current window. `Focus` enters
the explorer. `Toggle` closes an open explorer; when closed it opens and focuses it.

Activation expands or collapses semantic containers. Existing files cannot be opened yet because
the core does not publish an authoritative file path or resolve operation. The plugin deliberately
does not guess a path.

## Adding a file

Select a project or any of its descendants, then use `a` or
`:DotnetWorkspaceExplorerAddFile [path]`. With no argument, the plugin prompts for a path. Relative
paths are solution-relative; absolute paths pass through unchanged.

The plugin asks the core to preview the exact request, asks for confirmation, executes that request
with its confirmation token, and refreshes from the authoritative tree on success. Cancelling the
path or confirmation changes nothing. Lua never writes project or solution files and never retries
a mutation automatically.

Read-only `.slnf` workspaces and cores without the write capabilities reject AddFile safely.
Invalid or ambiguous targets, stale revisions, invalid paths, transport failures, and core errors
preserve the current tree and selection where possible and show the safe error. After a fatal
process, transport, or protocol failure, the last good tree remains visible. Run
`:DotnetWorkspaceExplorerRefresh` to replace the failed session in place; there is no automatic
restart or mutation retry.

## Development

Enter the locked shell and run the local checks:

```sh
nix develop
stylua --check lua plugin tests docs/vhs/init.lua
luacheck lua plugin tests docs/vhs/init.lua
nvim -u NONE -i NONE --noplugin --headless \
	--cmd "set runtimepath^=$PWD" -l tests/headless-smoke.lua
```

The smoke crosses only the no-server view boundary. It verifies inert setup, the nine commands,
strict Devicons validation, mapping disable/replacement, and controlled left/right split creation.

For the bounded real-core visual route:

```sh
docs/vhs/make-fixture.sh
dotnet build ../dotnet-cli-plus/Dotnet.WorkspaceExplorer.slnx -c Release --no-restore
(cd ../vhs && go build -o ../dotnet-workspace-explorer.nvim/.agent-workspace/DWE-008/vhs .)
core="$PWD/../dotnet-cli-plus/src/WorkspaceExplorer/bin/Release/net10.0"
DWE_CORE="$core/Dotnet.WorkspaceExplorer" \
	DWE_FIXTURE="$PWD/.agent-workspace/DWE-008/fixture/SemanticStudio.slnx" \
	VHS_NO_SANDBOX=1 .agent-workspace/DWE-008/vhs docs/vhs/explorer.tape
```

The fixture and capture intermediates stay under `.agent-workspace`. The tape uses two clean
`nvim -u docs/vhs/init.lua -i NONE --noplugin` sessions, the real Release core, and Devicons
disabled. It records left/right docking, semantic expansion and scrolling, a cancelled configured
`a` preview, and a confirmed Ex-command creation followed by authoritative refresh.

## License

[MIT](LICENSE)
