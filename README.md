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

The installers select the archive for the host, verify it against the
release's `SHA256SUMS`, and install moon under `~/.moon`. Each archive contains
one relocatable `moon-<version>-<host>/` tree: `bin/`, `lib/`, and `include/`.

### Options

| `install.sh` | `install.ps1` | Meaning |
| --- | --- | --- |
| `vX.Y.Z` (first argument) | `vX.Y.Z` (first argument) | Install that tagged release instead of the latest |
| `--editor NAME` | `-Editor NAME` | Also install an editor integration: `vscode` (`code`), `sublime` (`subl`), `jetbrains`, `neovim` (`nvim`), or `zed` |
| `--editor-path CMD` | `-EditorPath CMD` | Editor command to use, for `vscode` (or a fork such as `codium`) and `neovim` |
| `--editor-config DIR` | `-EditorConfig DIR` | Where the integration goes: VS Code's extensions directory, Sublime's `Packages` directory, one JetBrains IDE's plugins directory, or Neovim's config directory |
| `--editor-only` | `-EditorOnly` | Keep the installed toolchain and install only the editor |
| `--help` | `-Help` | Show the installer's help |

The editor is also the second positional argument, after the version. To pass
options, give them to the shell that runs the installer:

```sh
curl -fsSL https://raw.githubusercontent.com/moonlang-dev/moon-releases/main/install.sh | bash -s -- v1.0.0 --editor nvim
```

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/moonlang-dev/moon-releases/main/install.ps1))) v1.0.0 -Editor nvim
```

### Environment variables

| Variable | Meaning |
| --- | --- |
| `MOON_VERSION` | Same as the version argument |
| `MOON_INSTALL` | Install directory, `~/.moon` by default |
| `MOON_INSTALL_ARGS` | The options above as comma-separated `key=value` pairs |

`MOON_INSTALL_ARGS` lets the one-line installs above take options. Its keys
are `editor`, `editor-path`, `editor-config`, `editor-only`, and `help`.
`editor-only` and `help` take `yes` or `no`, and a bare key means `yes`. An
option passed explicitly wins.

```sh
curl -fsSL https://raw.githubusercontent.com/moonlang-dev/moon-releases/main/install.sh | MOON_INSTALL_ARGS=editor=nvim,editor-only bash
```

```powershell
$env:MOON_INSTALL_ARGS = "editor=nvim,editor-only"
irm https://raw.githubusercontent.com/moonlang-dev/moon-releases/main/install.ps1 | iex
```

### Editor integrations

Integrations come from the rolling
[`editors`](https://github.com/moonlang-dev/moon-releases/releases/tag/editors)
release, even when the toolchain version is pinned. They all launch `moon lsp`.

- **VS Code** and **JetBrains** (2026.2 or newer): reload or restart the
  editor afterwards.
- **Sublime Text**: set up the `LSP` package for language server features.
- **Neovim**: needs a C compiler to build its tree-sitter parser.
- **Zed**: the installer unpacks the extension; then run **zed: install dev
  extension** and select the printed directory.

Neovim and Zed files are kept in `~/.local/share/moon/editors`
(`%LOCALAPPDATA%\moon\editors` on Windows), which toolchain upgrades leave in
place. Zed builds its grammar from a `tree-sitter-moon-vX.Y.Z` tag in this
repository; that branch contains only the public grammar, never compiler
source.
