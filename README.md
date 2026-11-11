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

Run from a terminal with no options, the installers ask where to install moon,
which editor integrations to set up, and where each one goes. Every question
has a default that Enter accepts: `~/.moon`, the editors the installer found on
the machine, and each editor's usual location. Nothing is installed until the
final confirmation.

Given any option, or run without a terminal (in CI, for example), the
installers ask nothing. `--yes` does the same for an install with no other
options, and `--interactive` asks even when options are given, using them as
the suggested answers.

### Options

| `install.sh` | `install.ps1` | Meaning |
| --- | --- | --- |
| `vX.Y.Z` (first argument) | `vX.Y.Z` (first argument) | Install that tagged release instead of the latest |
| `--editor NAMES` | `-Editor NAMES` | Also install editor integrations: `vscode` (`code`), `sublime` (`subl`), `jetbrains`, `neovim` (`nvim`), or `zed`, separated by commas |
| `--editor-path CMD` | `-EditorPath CMD` | Editor command to use, for `vscode` (or a fork such as `codium`) and `neovim` |
| `--editor-config DIR` | `-EditorConfig DIR` | Where the integration goes: VS Code's extensions directory, Sublime's `Packages` directory, one JetBrains IDE's plugins directory, Neovim's config directory, or the directory Zed's extension is unpacked in |
| `--editor-only` | `-EditorOnly` | Keep the installed toolchain and install only the editors |
| `--interactive`, `-i` | `-Interactive` | Ask, with the other options as the suggested answers |
| `--yes`, `-y` | `-Yes` | Ask nothing |
| `--help` | `-Help` | Show the installer's help |

The editors are also the second positional argument, after the version.
`--editor-path` and `--editor-config` describe one editor, so they need exactly
one to be named; the interactive installer asks for them per editor. To pass
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
are `editor`, `editor-path`, `editor-config`, `editor-only`, `interactive`,
`yes`, and `help`. The last four take `yes` or `no`, and a bare key means
`yes`. Repeat `editor` for several editors, as in `editor=nvim,editor=zed`. An
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
place. Zed's extension can be unpacked elsewhere.
