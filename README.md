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
