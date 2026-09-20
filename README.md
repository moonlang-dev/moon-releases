# Moon releases

This repository is Moon's public binary-release mirror. It contains only the
installers and tagged toolchain archives; the compiler source is maintained in
a private repository.

## Install

x86-64 Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/moonlang-dev/moon-releases/main/install.sh | bash
```

x86-64 Windows PowerShell:

```powershell
irm https://raw.githubusercontent.com/moonlang-dev/moon-releases/main/install.ps1 | iex
```

The installers require an x86-64 host, select its archive, verify the SHA-256
sidecar, and install Moon under `~/.moon`. Download an installer first and pass
a `vX.Y.Z` argument to pin a specific tagged release. macOS and ARM packages
are temporarily unavailable.

Release archives contain the complete relocatable `moon/` tree: `bin/`,
`lib/`, and `include/`.

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

All five launch `moon lsp`, so install the Moon toolchain first. The Neovim
bundle includes its tree-sitter parser source and installer. Zed builds the
same grammar from an immutable component-version tag such as
`tree-sitter-moon-v0.2.0` published in this repository; that branch contains
only the public grammar, never compiler source.
