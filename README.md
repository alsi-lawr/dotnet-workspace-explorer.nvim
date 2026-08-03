<div align="center">

<img src="docs/assets/dotnet-workspace-explorer.svg"
     width="128"
     alt="dotnet-workspace-explorer.nvim logo">

# dotnet-workspace-explorer.nvim

**A Visual Studio-inspired .NET solution explorer for Neovim.**

<a href="#status">
  <img src="https://img.shields.io/badge/status-experimental-f5a97f"
       alt="Experimental status">
</a>
<a href="https://neovim.io/">
  <img src="https://img.shields.io/badge/Neovim-0.12%2B-57A143?logo=neovim"
       alt="Neovim 0.12 or newer">
</a>
<a href="https://www.nuget.org/packages/ALSI.WorkspaceExplorer">
  <img src="https://img.shields.io/nuget/v/ALSI.WorkspaceExplorer?label=core"
       alt="NuGet core version">
</a>
<a href="LICENSE">
  <img src="https://img.shields.io/badge/license-MIT-blue"
       alt="MIT licence">
</a>

</div>

Browse .NET solutions as solutions: solution folders, projects, files, dependencies, package and
assembly versions, and Git state across C#, F#, and Visual Basic.

<div align="center">

<img src="docs/assets/explorer.webp"
     alt="The explorer navigating a multi-project .NET solution">

</div>

## Requirements

- Neovim 0.12 or newer
- [`dotnet-we` 0.2.0 or newer](https://github.com/alsi-lawr/dotnet-workspace-explorer)
- [`nvim-web-devicons`](https://github.com/nvim-tree/nvim-web-devicons), if you want file icons

## Install

Install the core with Nix:

```sh
nix profile install github:alsi-lawr/dotnet-workspace-explorer
```

Or install it from NuGet:

```sh
dotnet tool install --global ALSI.WorkspaceExplorer
```

Then install the plugin. With
[`lazy.nvim`](https://github.com/folke/lazy.nvim):

```lua
{
  "alsi-lawr/dotnet-workspace-explorer.nvim",
  dependencies = {
    "nvim-tree/nvim-web-devicons",
  },
  opts = {
    position = "left", -- "left" or "right"
    width = 50,
    presentation = {
      devicons = true,
    },
  },
}
```

The plugin starts `dotnet-we workspace <target> --pipe`. No extra command setting is needed when
`dotnet-we` is on your `PATH`.

## Open a workspace

```vim
:DotnetWorkspaceExplorerToggle
:DotnetWorkspaceExplorerOpen /path/to/MySolution.slnx
```

Without a path, the explorer looks for a solution or project in the current directory.

## Key actions

| Key | Action |
| --- | --- |
| `<CR>` or `l` | Open or expand |
| `h` | Collapse |
| `a` | Add a file, directory, project, or solution item |
| `e` | Open a project file |
| `r` | Rename |
| `m`, then `p` | Move and place |
| `c`, then `p` | Copy and paste |
| `d` | Delete |
| `E` / `W` | Expand all / collapse all |
| `R` | Refresh |
| `q` | Close |

Actions are also available as commands, so every mapping can be changed or removed.

## Why use it?

- See solution folders and project structure rather than a flat file tree.
- Inspect project, package, framework, assembly, and project-reference dependencies.
- Keep the current selection and expanded branches while the workspace changes.
- Use the same explorer across C#, F#, and Visual Basic solutions.

## Documentation

- [Getting started][getting-started]
- [Configuration][configuration]
- [Commands and mappings][commands]
- [Recovery and limitations][r]

## Status

The plugin is experimental. Commands and configuration may change before a stable release.

See [CONTRIBUTING.md](CONTRIBUTING.md) for development, testing, and showcase capture instructions.

## Licence

[MIT](LICENSE)

[getting-started]: https://github.com/alsi-lawr/dotnet-workspace-explorer.nvim/wiki/Getting-Started
[configuration]: https://github.com/alsi-lawr/dotnet-workspace-explorer.nvim/wiki/Configuration
[commands]: https://github.com/alsi-lawr/dotnet-workspace-explorer.nvim/wiki/Commands-and-Mappings
[r]: https://github.com/alsi-lawr/dotnet-workspace-explorer.nvim/wiki/Recovery-and-Limitations
