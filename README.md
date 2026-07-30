<div align="center">

<img src="docs/assets/dotnet-workspace-explorer.svg" width="128" alt="Explorer logo">

# dotnet-workspace-explorer.nvim

**A Visual Studio-inspired .NET solution explorer for Neovim.**

<a href="#status">
<img alt="Experimental" src="https://img.shields.io/badge/status-experimental-f59e0b">
</a>
<a href="#quick-start">
<img alt="Neovim 0.12+" src="https://img.shields.io/badge/Neovim-0.12%2B-57A143?logo=neovim">
</a>
<a href="https://github.com/alsi-lawr/dotnet-workspace-explorer">
<img alt=".NET core" src="https://img.shields.io/badge/core-.NET-512bd4?logo=dotnet">
</a>
<a href="LICENSE">
<img alt="MIT" src="https://img.shields.io/badge/license-MIT-22c55e">
</a>

</div>

See your .NET solution the way it was organised, not flattened into a generic file browser. Browse
projects, solution folders, source files, references, and NuGet packages across C#, F#, and Visual
Basic in a familiar, fully scrollable tree.

<div align="center">

<img src="docs/assets/explorer.webp" alt=".NET solution explorer in Neovim">

</div>

## Quick start

You need Neovim 0.12+ and a built
[`dotnet-workspace-explorer`](https://github.com/alsi-lawr/dotnet-workspace-explorer) executable.
The core is not yet
published to NuGet; the [getting-started guide](../../wiki/Getting-Started) covers the current
source-build setup.

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
	"alsi-lawr/dotnet-workspace-explorer.nvim",
	dependencies = {
		"nvim-tree/nvim-web-devicons",
	},
	config = function()
		require("nvim-web-devicons").setup()
		require("dotnet-workspace-explorer").setup({
			command = "dotnet-workspace-explorer",
			presentation = {
				devicons = true,
			},
		})
	end,
}
```

Open the solution selected from the current directory:

```vim
:DotnetWorkspaceExplorerOpen
```

Or pass a specific `.sln`, `.slnx`, or read-only `.slnf` target:

```vim
:DotnetWorkspaceExplorerOpen /path/to/Demo.slnx
```

The explorer opens on the left by default. Use `<CR>` or `l` to expand, `h` to collapse, `a` to add
a file to the selected project, `R` to refresh, and `q` to close. All actions are also commands, and
every mapping can be replaced or disabled.

## Why this explorer

- **Solution-aware:** the .NET core owns the hierarchy rather than asking Lua to infer it.
- **Theme-native:** semantic highlights follow the active colorscheme; Devicons are optional.
- **Editor-native:** the explorer is an ordinary split with normal Neovim scrolling and movement.
- **Mutation-safe:** file creation is previewed, explicitly confirmed, and applied by the core.

## Documentation

- [Getting started](../../wiki/Getting-Started)
- [Configuration](../../wiki/Configuration)
- [Commands and mappings](../../wiki/Commands-and-Mappings)
- [Adding files](../../wiki/Adding-Files)
- [Recovery and limitations](../../wiki/Recovery-and-Limitations)

## Status

The plugin is experimental and does not yet have a tagged release. Existing files cannot be opened
from the tree until the core publishes an authoritative path-resolution operation; the explorer
deliberately does not guess paths.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the development shell, checks, repository boundaries, and
visual-capture workflow.

## License

MIT. See [LICENSE](LICENSE).
