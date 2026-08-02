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

The explorer opens on the left by default. Use `<CR>` to expand or collapse containers and open
files in the previous editor window. Use `e` to edit a project file, `r` to rename, `m` or `c` to
mark nodes for a move or copy, and `p` to place the marked batch. `E` expands the complete solution
and `W` collapses it. The existing `l`, `h`, `a`, `d`, `R`, and `q` mappings expand, collapse,
create, delete, refresh, and close. Dependencies expand into compact, read-only Visual
Studio-inspired reference properties, including available package and assembly versions.

New includes logical Solution Folders where the selected context supports them. Add Existing opens
a temporary core-backed selector in the same drawer: `<CR>` expands or collapses directories and
confirms marked files from a file row, Space marks eligible files, and `q` or Escape cancels. The
semantic tree returns with its mappings and semantic selection restored; cancellation leaves it
unchanged.

Every action is also available through its `DotnetWorkspaceExplorer*` command and public Lua
function. Mappings can be replaced or disabled individually; `clear_marks` and `git_refresh` have
no default key.

Git decorations are enabled by default. Disable them when a session does not need repository state:

```lua
require("dotnet-workspace-explorer").setup({
	git = {
		enable = false,
	},
})
```

After changing Git configuration for an open explorer, run `:DotnetWorkspaceExplorerRefresh` to
negotiate a fresh session. Theme-linked glyphs distinguish staged `✓`, unstaged `✗`, renamed `➜`,
deleted ``, unmerged ``, untracked `★`, and ignored `◌` state before each affected name. Status
updates are event-driven, and `:DotnetWorkspaceExplorerGitRefresh` requests one explicitly.

## Why this explorer

- **Solution-aware:** the .NET core owns the hierarchy rather than asking Lua to infer it.
- **Theme-native:** semantic highlights follow the active colorscheme; Devicons are optional.
- **Editor-native:** the explorer is an ordinary split with normal Neovim scrolling and movement.
- **Mutation-safe:** creation, deletion, rename, and marked move/copy batches are fully previewed,
  explicitly confirmed, and applied by the core.

## Documentation

- [Getting started](../../wiki/Getting-Started)
- [Configuration](../../wiki/Configuration)
- [Commands and mappings](../../wiki/Commands-and-Mappings)
- [Recovery and limitations](../../wiki/Recovery-and-Limitations)

## Status

The plugin is experimental and does not yet have a tagged release.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the development shell, checks, repository boundaries, and
visual-capture workflow.

## License

MIT. See [LICENSE](LICENSE).
