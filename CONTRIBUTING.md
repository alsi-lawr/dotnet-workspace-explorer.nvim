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
nvim -u NONE -i NONE --noplugin --headless \
  --cmd "set runtimepath^=$PWD" -l tests/headless/editing.lua
nvim -u NONE -i NONE --noplugin --headless \
  --cmd "set runtimepath^=$PWD" -l tests/headless/git/status.lua
nvim -u NONE -i NONE --noplugin --headless \
  --cmd "set runtimepath^=$PWD" -l tests/headless/tree-actions.lua
nvim -u NONE -i NONE --noplugin --headless \
  --cmd "set runtimepath^=$PWD" -l tests/headless/selector.lua
```

The smoke keeps `setup` and plugin loading inert. The presentation probe exercises the semantic
tree, optional Devicons behavior, docking, mappings, selection, scrolling, and refresh without
starting the real core. It also covers expandable dependency details and their icon-free property
rows. The mutation probe covers contextual creation and deletion, including capability, schema,
cancellation, confirmation, and operation-completion boundaries.
The workspace probe covers notification reconciliation, transparent hydration retry, and
preservation of expanded paths and deep selection.
The editing probe covers exact rename/move/copy envelopes and mark lifecycle. The Git probe covers
conditional status negotiation, freshness, coalescing, cleanup, and decoration replacement. The
tree-action probe covers project-file resolution plus atomic full expansion and collapse.
The selector probe covers the transient Add Existing protocol, opaque paging, whole-directory and
file marks, latest-wins overlap, modal mapping restoration, callback invalidation, action routing,
semantic-state restoration, and optional Devicons states.

The bounded real-core probe accepts explicit paths to a disposable fixture:

```sh
DWE_CORE=/path/to/dotnet-we \
DWE_FIXTURE="${TMPDIR:-/tmp}/dwe-real-core/fixture/SemanticStudio.slnx" \
nvim -u NONE -i NONE --noplugin --headless \
  --cmd "set runtimepath^=$PWD" -l tests/real-core-smoke.lua
```

## Making changes

- Keep transport and generation safety in `rpc.lua`, normalized tree state in `workspace.lua`,
  New/Delete orchestration in `mutations.lua`, transient Add Existing state in `selector.lua`,
  rename/move/copy orchestration in `editing.lua`, event-driven Git status in `git/status.lua`,
  public lifecycle actions in `init.lua`, configuration in `config.lua`, and presentation in
  `view.lua`.
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
capture_root="${TMPDIR:-/tmp}/dwe-nvim-showcase"
DWE_CAPTURE_ROOT="$capture_root" docs/vhs/make-fixture.sh
mkdir -p "$capture_root"
nix build github:alsi-lawr/dotnet-workspace-explorer \
  --out-link "$capture_root/core"
plugin_root="$PWD"
(cd ../vhs && go build -o "$capture_root/vhs" .)

DWE_CORE="$capture_root/core/bin/dotnet-we" \
  DWE_FIXTURE="$capture_root/fixture/SemanticStudio.slnx" \
  DWE_DEVICONS="$HOME/.local/share/nvim/lazy/nvim-web-devicons" \
  VHS_NO_SANDBOX=1 \
  "$capture_root/vhs" --capture-mode=webgl docs/vhs/explorer.tape
```

Only the final PNG and WebP belong in `docs/assets`.

## Pull requests

- Keep commits focused and use conventional commit messages.
- Explain user-visible behavior and compatibility implications.
- Include the commands run and their results.
- Keep unrelated formatting, renames, dependency changes, and cleanup out of the patch.
