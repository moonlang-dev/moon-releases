# moon releases

This repository is moon's public binary-release mirror. It contains only the
installers and tagged toolchain archives; the compiler source is maintained in
a private repository.

## Install

x86-64 Linux and Apple silicon macOS:

```sh
curl -fsSL https://raw.githubusercontent.com/moonlang-dev/moon-releases/main/install.sh | bash
```

x86-64 Windows PowerShell:

```powershell
irm https://raw.githubusercontent.com/moonlang-dev/moon-releases/main/install.ps1 | iex
```

The installers select the host's archive from the release's `SHA256SUMS`,
verify its checksum, install moon under `~/.moon` (or `MOON_INSTALL`) and put
its `bin/` on `PATH`. Download an installer first and pass a `vX.Y.Z` argument
(or set `MOON_VERSION`) to pin a specific tagged release.

Each release holds `moon-<version>-<host>.tar.gz` for `x86_64-linux`,
`x86_64-windows` and `aarch64-macos`. An archive contains one relocatable
`moon-<version>-<host>/` tree: `bin/` (`moon` and its C import worker),
`include/moon/std/`, `lib/moon/targets/` and `NOTICE.md`. `run`, `build` and
`test` also need an LLVM 23 installation.

## Editor integrations

The separate rolling [`editors`](https://github.com/moonlang-dev/moon-releases/releases/tag/editors)
release carries five packages, each with a matching `.sha256` sidecar. It is
updated independently of versioned toolchain releases, and each editor has its
own build-and-publish lane. A failed integration does not block successful
packages from being updated.

| Editor | Release asset | Install |
| --- | --- | --- |
| VS Code | [`moon-vscode.vsix`](https://github.com/moonlang-dev/moon-releases/releases/download/editors/moon-vscode.vsix) | `code --install-extension moon-vscode.vsix` |
| Sublime Text | [`moon-sublime.zip`](https://github.com/moonlang-dev/moon-releases/releases/download/editors/moon-sublime.zip) | Extract `moon-sublime` into **Preferences > Browse Packages** |
| JetBrains 2026.2 | [`moon-jetbrains.zip`](https://github.com/moonlang-dev/moon-releases/releases/download/editors/moon-jetbrains.zip) | **Settings > Plugins > Install Plugin from Disk** |
| Neovim | [`moon-neovim.zip`](https://github.com/moonlang-dev/moon-releases/releases/download/editors/moon-neovim.zip) | Extract it, then run `editors/nvim/setup.sh` or `setup.ps1` |
| Zed | [`moon-zed.zip`](https://github.com/moonlang-dev/moon-releases/releases/download/editors/moon-zed.zip) | Extract it, run **zed: install dev extension**, and select `moon-zed` |

All five launch `moon lsp`, so install the moon toolchain first. The Neovim
bundle includes its tree-sitter parser source and installer. Zed builds the
same grammar from an immutable component-version tag
(`tree-sitter-moon-vX.Y.Z`) published in this repository; that branch contains
only the public grammar, never compiler source.
