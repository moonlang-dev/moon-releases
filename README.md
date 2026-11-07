# moon releases

This repository is moon's public binary-release mirror. It contains only the
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
sidecar, and install moon under `~/.moon`. Download an installer first and pass
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

### Install with the moon installer

Both installers can fetch, verify, and install one integration alongside the
toolchain. The package always comes from the rolling `editors` release, even
when the toolchain version is pinned.

```sh
curl -fsSL https://raw.githubusercontent.com/moonlang-dev/moon-releases/main/install.sh | bash -s -- --editor nvim
```

```powershell
irm https://raw.githubusercontent.com/moonlang-dev/moon-releases/main/install.ps1 -OutFile install.ps1
./install.ps1 -Editor nvim
```

If the execution policy blocks a downloaded script, run it without saving it:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/moonlang-dev/moon-releases/main/install.ps1))) -Editor nvim
```

The editor is also the second positional argument, after the version:
`install.sh v1.0.0 nvim` or `./install.ps1 v1.0.0 nvim`.

| `install.sh` | `install.ps1` | Meaning |
| --- | --- | --- |
| `--editor NAME` | `-Editor NAME` | `vscode` (`code`), `sublime` (`subl`), `jetbrains`, `neovim` (`nvim`), or `zed` |
| `--editor-path CMD` | `-EditorPath CMD` | Editor command to use, for `vscode` and `neovim` |
| `--editor-config DIR` | `-EditorConfig DIR` | Install location, as listed below |
| `--editor-only` | `-EditorOnly` | Keep the installed toolchain and install only the editor |

When piping an installer into a shell with no way to pass options, set
`MOON_INSTALL_ARGS` to the same options as comma-separated `key=value` pairs.
Its keys are `editor`, `editor-path`, `editor-config`, `editor-only` and
`help`. `editor-only` and `help` take `yes` or `no`, and a bare key means
`yes`. An option passed explicitly wins over `MOON_INSTALL_ARGS`.

```sh
curl -fsSL https://raw.githubusercontent.com/moonlang-dev/moon-releases/main/install.sh | MOON_INSTALL_ARGS=editor=nvim,editor-only bash
```

```powershell
$env:MOON_INSTALL_ARGS = "editor=nvim,editor-only"
irm https://raw.githubusercontent.com/moonlang-dev/moon-releases/main/install.ps1 | iex
```

| Editor | Default target | `--editor-config` | Afterwards |
| --- | --- | --- | --- |
| `vscode` | The `code` command | Extensions directory | Reload VS Code |
| `sublime` | Sublime Text's `Packages` directory | `Packages` directory | Set up the `LSP` package for language server features |
| `jetbrains` | Every IDE at 2026.2 or newer | One IDE's plugins directory | Restart the IDE |
| `neovim` | Neovim's config directory | Config directory | None |
| `zed` | Unpacks to the moon data directory | Not supported | Run **zed: install dev extension** and select the printed directory |

`--editor-path` also accepts VS Code forks such as `codium`. Neovim needs a C
compiler to build its parser. Zed has no command-line way to install a dev
extension, so that last step stays manual.

The Neovim and Zed packages are kept in `~/.local/share/moon/editors`
(`%LOCALAPPDATA%\moon\editors` on Windows) because their installed
configuration refers to those files. Toolchain upgrades do not replace this
directory.

### Install manually

All five launch `moon lsp`, so install the moon toolchain first. The Neovim
bundle includes its tree-sitter parser source and installer. Zed builds the
same grammar from an immutable component-version tag
(`tree-sitter-moon-vX.Y.Z`) published in this repository; that branch contains
only the public grammar, never compiler source.
