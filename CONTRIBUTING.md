# Contributing to dotnet-workspace-explorer.nvim

Thanks for helping improve the explorer. Keep this repository focused on the small native-Lua
client and its Neovim presentation. Workspace discovery, hierarchy, path authority, and mutations
belong in
[`dotnet-workspace-explorer`](https://github.com/alsi-lawr/dotnet-workspace-explorer).

## Local setup

Enter the locked development shell from the repository root:

```sh
nix develop
```

The shell provides Neovim, LuaLS, StyLua, Luacheck, .NET 10, Go, ttyd, FFmpeg, and Chromium.

## Checks

Format Lua before committing:

```sh
stylua lua plugin tests docs/vhs/init.lua
```

Run the focused checks:

```sh
stylua --check lua plugin tests docs/vhs/init.lua
luacheck lua plugin tests docs/vhs/init.lua
nvim -u NONE -i NONE --noplugin --headless \
  --cmd "set runtimepath^=$PWD" -l tests/headless-smoke.lua
nvim -u NONE -i NONE --noplugin --headless \
  --cmd "set runtimepath^=$PWD" -l tests/headless/presentation.lua
nvim -u NONE -i NONE --noplugin --headless \
  --cmd "set runtimepath^=$PWD" -l tests/headless/mutations.lua
nvim -u NONE -i NONE --noplugin --headless \
  --cmd "set runtimepath^=$PWD" -l tests/headless/workspace.lua
```

The smoke keeps `setup` and plugin loading inert. The presentation probe exercises the semantic
tree, optional Devicons behavior, docking, mappings, selection, scrolling, and refresh without
starting the real core. The mutation probe covers contextual creation and deletion, including
capability, schema, cancellation, confirmation, and operation-completion boundaries.
The workspace probe covers notification reconciliation, transparent hydration retry, and
preservation of expanded paths and deep selection.

## Making changes

- Keep transport and generation safety in `rpc.lua`, normalized tree state in `workspace.lua`,
  context action orchestration in `mutations.lua`, public lifecycle actions in `init.lua`,
  configuration in `config.lua`, and presentation in `view.lua`.
- Preserve the core as the authority for solution state and writes. Lua must not infer workspace
  paths or edit project files directly.
- Expose user actions as commands before adding buffer-local convenience mappings.
- Link presentation to standard highlight groups rather than fixing a palette.
- Keep optional integrations optional and preserve their configured fallback.
- Document detailed user behavior in the
  [wiki](https://github.com/alsi-lawr/dotnet-workspace-explorer.nvim/wiki), not in the README.

## Visual capture

The retained explorer assets use the real Release core, an explicit `nvim-web-devicons` checkout,
and the repository owner's VHS fork:

```sh
docs/vhs/make-fixture.sh
dotnet build ../dotnet-workspace-explorer/Dotnet.WorkspaceExplorer.slnx \
  --configuration Release --no-restore
mkdir -p .agent-workspace/visual
plugin_root="$PWD"
(cd ../vhs && go build -o "$plugin_root/.agent-workspace/visual/vhs" .)

core="$PWD/../dotnet-workspace-explorer/src/WorkspaceExplorer/bin/Release/net10.0"
DWE_CORE="$core/Dotnet.WorkspaceExplorer" \
  DWE_FIXTURE="$PWD/.agent-workspace/visual/fixture/SemanticStudio.slnx" \
  DWE_DEVICONS="$HOME/.local/share/nvim/lazy/nvim-web-devicons" \
  VHS_NO_SANDBOX=1 \
  .agent-workspace/visual/vhs --capture-mode=webgl docs/vhs/explorer.tape
```

If the core checkout uses a different directory, update the two core paths. Keep generated fixtures
and capture binaries under `.agent-workspace`; only the final PNG and WebP belong in `docs/assets`.

## Pull requests

- Keep commits focused and use conventional commit messages.
- Explain user-visible behavior and compatibility implications.
- Include the commands run and their results.
- Keep unrelated formatting, renames, dependency changes, and cleanup out of the patch.
