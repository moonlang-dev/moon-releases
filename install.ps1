[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Position = 0)]
    [string]$Target = "latest",

    [Parameter(Position = 1)]
    [string]$Editor,

    [string]$EditorPath,

    [string]$EditorConfig,

    [switch]$EditorOnly,

    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$DefaultGitHub = "https://github.com"
$DefaultRepository = "moonlang-dev/moon-releases"

if ($Help) {
    Write-Output @'
Usage: install.ps1 [[-Target] <version>] [[-Editor] <name>] [options]

Installs the moon toolchain and, optionally, one editor integration.

  -Target <version>     latest (default) or vX.Y.Z; MOON_VERSION also sets this
  -Editor <name>        vscode, sublime, jetbrains, neovim, or zed
                        (also accepts code, subl, and nvim)
  -EditorPath <cmd>     editor command to use (vscode, neovim)
  -EditorConfig <dir>   where the integration is installed:
                          vscode     extensions directory
                          sublime    Packages directory
                          jetbrains  one IDE's plugins directory
                          neovim     config directory
  -EditorOnly           keep the installed toolchain; install only the editor
  -Help                 show this help
'@
    return
}

if (-not $Editor) {
    if ($EditorPath -or $EditorConfig) {
        throw "-EditorPath and -EditorConfig require an editor."
    }
    if ($EditorOnly) {
        throw "-EditorOnly requires an editor."
    }
}
if ($EditorOnly -and $Target -ne "latest") {
    throw "-EditorOnly does not install a toolchain, so it cannot take a version."
}

if ($Target -eq "latest" -and $env:MOON_VERSION) {
    $Target = $env:MOON_VERSION
}
if ($Target -eq "latest") {
    $ReleasePath = "latest/download"
}
elseif ($Target -match '^v?(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)$') {
    $ReleasePath = "download/v$($Matches[1])"
}
else {
    throw "Invalid moon version '$Target' (use latest or vX.Y.Z)."
}

if (-not [Environment]::Is64BitOperatingSystem) {
    throw "moon releases require 64-bit Windows."
}
if (-not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::Windows)) {
    throw "This installer only supports Windows. Use install.sh on x86-64 Linux."
}

$Architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
switch ($Architecture) {
    "X64" { $Architecture = "x86_64" }
    default { throw "moon tagged releases currently support only Windows x86_64 (detected '$Architecture')." }
}

$Tar = Join-Path $env:SystemRoot "System32\tar.exe"
if (-not (Test-Path -LiteralPath $Tar -PathType Leaf)) {
    throw "The Windows tar tool ($Tar) is required to install moon."
}

$GitHub = if ($env:MOON_GITHUB) { $env:MOON_GITHUB.TrimEnd('/') } else { $DefaultGitHub }
$Repository = if ($env:MOON_GITHUB_REPO) { $env:MOON_GITHUB_REPO.Trim('/') } else { $DefaultRepository }
$HostName = "$Architecture-windows"
$BaseUrl = "$GitHub/$Repository/releases/$ReleasePath"
$EditorBaseUrl = "$GitHub/$Repository/releases/download/editors"
$LocalAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME "AppData\Local" }
$RoamingAppData = if ($env:APPDATA) { $env:APPDATA } else { Join-Path $HOME "AppData\Roaming" }
# Neovim's generated config and Zed's dev extension keep pointing at these
# files, so they live outside the toolchain directory that upgrades replace.
$EditorDataDir = Join-Path $LocalAppData "moon\editors"
$EditorName = $null
$EditorCli = $null
$EditorTargets = @()

# Runs before the toolchain is touched, so a bad editor request changes nothing.
if ($Editor) {
    $EditorAliases = @{
        vscode = "vscode"; code = "vscode"
        sublime = "sublime"; subl = "sublime"
        jetbrains = "jetbrains"
        neovim = "neovim"; nvim = "neovim"
        zed = "zed"
    }
    $EditorName = $EditorAliases[$Editor]
    if (-not $EditorName) {
        throw "Unknown editor '$Editor' (use vscode, sublime, jetbrains, neovim, or zed)."
    }
    if ($EditorPath -and $EditorName -notin "vscode", "neovim") {
        throw "-EditorPath does not apply to $EditorName."
    }
    if ($EditorConfig -and $EditorName -eq "zed") {
        throw "-EditorConfig does not apply to zed."
    }

    if ($EditorPath) {
        $EditorCommand = Get-Command $EditorPath -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $EditorCommand) {
            throw "Editor command not found: '$EditorPath'."
        }
        $EditorCli = $EditorCommand.Source
    }
    if ($EditorConfig) {
        $EditorConfig = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($EditorConfig)
        $EditorTargets = @($EditorConfig)
    }

    switch ($EditorName) {
        "vscode" {
            if (-not $EditorCli) {
                $EditorCommand = Get-Command "code" -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($EditorCommand) {
                    $EditorCli = $EditorCommand.Source
                }
                else {
                    $EditorCli = @(
                        (Join-Path $LocalAppData "Programs\Microsoft VS Code\bin\code.cmd"),
                        (Join-Path $env:ProgramFiles "Microsoft VS Code\bin\code.cmd")
                    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
                }
            }
            if (-not $EditorCli) {
                throw "Could not find the 'code' command; pass -EditorPath."
            }
        }
        "sublime" {
            if ($EditorTargets.Count -eq 0) {
                $EditorTargets = @(
                    "Sublime Text", "Sublime Text 3" |
                        ForEach-Object { Join-Path $RoamingAppData "$_\Packages" } |
                        Where-Object { Test-Path -LiteralPath $_ -PathType Container } |
                        Select-Object -First 1
                )
            }
            if ($EditorTargets.Count -eq 0) {
                throw "Could not find Sublime Text's Packages directory; pass -EditorConfig."
            }
        }
        "jetbrains" {
            # Every IDE that can load the plugin gets it. Older IDEs reject it,
            # because the plugin's since-build is 262 (2026.2).
            $JetBrainsRoot = Join-Path $RoamingAppData "JetBrains"
            if ($EditorTargets.Count -eq 0 -and (Test-Path -LiteralPath $JetBrainsRoot -PathType Container)) {
                foreach ($Product in Get-ChildItem -LiteralPath $JetBrainsRoot -Directory) {
                    if ($Product.Name -match '^[A-Za-z]+(\d{4})\.(\d+)$') {
                        $Year = [int]$Matches[1]
                        $Minor = [int]$Matches[2]
                        if ($Year -gt 2026 -or ($Year -eq 2026 -and $Minor -ge 2)) {
                            $EditorTargets += Join-Path $Product.FullName "plugins"
                        }
                    }
                }
            }
            if ($EditorTargets.Count -eq 0) {
                throw "Found no JetBrains IDE at version 2026.2 or newer; pass -EditorConfig."
            }
        }
        "neovim" {
            if (-not ($env:CC -or (Get-Command "zig", "gcc", "clang" -ErrorAction SilentlyContinue))) {
                throw "A C compiler is required to build the Neovim parser (set CC, or install zig, gcc, or clang)."
            }
        }
    }
}

function Get-MoonEditorAsset([string]$Asset, [string]$Directory) {
    $AssetUrl = "$EditorBaseUrl/$Asset"
    $AssetPath = Join-Path $Directory $Asset
    Write-Host "Downloading $AssetUrl"
    Invoke-WebRequest -UseBasicParsing -Uri $AssetUrl -OutFile $AssetPath
    Invoke-WebRequest -UseBasicParsing -Uri "$AssetUrl.sha256" -OutFile "$AssetPath.sha256"
    $Sidecar = Get-Content -LiteralPath "$AssetPath.sha256" -Raw
    if ($Sidecar -notmatch '^\s*([0-9a-fA-F]{64})(\s|$)') {
        throw "Invalid checksum file for '$Asset'."
    }
    $Expected = $Matches[1].ToLowerInvariant()
    if ((Get-FileHash -LiteralPath $AssetPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Expected) {
        throw "Checksum verification failed for '$Asset'."
    }
    return $AssetPath
}

# Applies the toolchain archive's rules: one top-level directory and no parent
# traversal. Expand-Archive writes links as ordinary files.
function Expand-MoonEditorPackage([string]$Package, [string]$Directory) {
    $Zip = Get-MoonEditorAsset "$Package.zip" $Directory
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Reader = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        foreach ($ZipEntry in $Reader.Entries) {
            $EntryName = $ZipEntry.FullName.Replace('\', '/')
            $Segments = @($EntryName.Split('/', [StringSplitOptions]::RemoveEmptyEntries))
            if ($EntryName.StartsWith('/') -or $EntryName -match '^[A-Za-z]:' -or $Segments.Count -eq 0 -or $Segments[0] -cne $Package -or $Segments -contains "..") {
                throw "Editor package contains an unexpected path: '$EntryName'."
            }
        }
    }
    finally {
        $Reader.Dispose()
    }
    Expand-Archive -LiteralPath $Zip -DestinationPath $Directory -Force
    return (Join-Path $Directory $Package)
}

function Set-MoonEditorDirectory([string]$Source, [string]$Destination) {
    $Parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Force -Path $Parent | Out-Null
    $Staged = Join-Path $Parent (".moon-editor-" + [IO.Path]::GetRandomFileName())
    try {
        Copy-Item -LiteralPath $Source -Destination $Staged -Recurse
        if (Test-Path -LiteralPath $Destination) {
            Remove-Item -LiteralPath $Destination -Recurse -Force
        }
        Move-Item -LiteralPath $Staged -Destination $Destination
    }
    finally {
        if (Test-Path -LiteralPath $Staged) {
            Remove-Item -LiteralPath $Staged -Recurse -Force
        }
    }
}

function Install-MoonEditor([string]$MoonExe) {
    $TempDir = Join-Path ([IO.Path]::GetTempPath()) ("moon-editor-" + [IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $TempDir | Out-Null
    try {
        switch ($EditorName) {
            "vscode" {
                $Vsix = Get-MoonEditorAsset "moon-vscode.vsix" $TempDir
                $CliArguments = @("--install-extension", $Vsix, "--force")
                if ($EditorConfig) {
                    $CliArguments += @("--extensions-dir", $EditorConfig)
                }
                & $EditorCli @CliArguments
                if ($LASTEXITCODE -ne 0) {
                    throw "'$EditorCli' could not install the extension."
                }
                Write-Output "moon extension installed with $EditorCli"
            }
            "sublime" {
                $Staged = Expand-MoonEditorPackage "moon-sublime" $TempDir
                $Destination = Join-Path $EditorTargets[0] "moon-sublime"
                Set-MoonEditorDirectory $Staged $Destination
                Write-Output "moon package installed to $Destination"
                Write-Output "For language server features, set up the LSP package as described in its README.md."
            }
            "jetbrains" {
                $Staged = Expand-MoonEditorPackage "moon-jetbrains" $TempDir
                foreach ($EditorTarget in $EditorTargets) {
                    $Destination = Join-Path $EditorTarget "moon-jetbrains"
                    Set-MoonEditorDirectory $Staged $Destination
                    Write-Output "moon plugin installed to $Destination"
                }
                Write-Output "Restart the IDE to load the plugin."
            }
            "neovim" {
                $Staged = Expand-MoonEditorPackage "moon-neovim" $TempDir
                $Bundle = Join-Path $EditorDataDir "moon-neovim"
                Set-MoonEditorDirectory $Staged $Bundle
                $Setup = Join-Path $Bundle "editors\nvim\setup.ps1"
                # Windows PowerShell reads a script without a BOM as ANSI, which
                # breaks on the non-ASCII punctuation in setup.ps1.
                $SetupText = [IO.File]::ReadAllText($Setup)
                [IO.File]::WriteAllText($Setup, $SetupText, (New-Object Text.UTF8Encoding $true))

                # A child process has its own execution policy and strict mode.
                $Pwsh = Get-Command "pwsh" -ErrorAction SilentlyContinue | Select-Object -First 1
                $Shell = if ($Pwsh) { $Pwsh.Source } else { Join-Path $PSHOME "powershell.exe" }
                $SetupArguments = @(
                    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Setup,
                    "-ExecutableDir", (Split-Path -Parent $MoonExe)
                )
                if ($EditorConfig) {
                    $SetupArguments += @("-ConfigDir", $EditorConfig)
                }
                $CallerPath = $env:Path
                if ($EditorCli) {
                    $env:Path = "$(Split-Path -Parent $EditorCli);$env:Path"
                }
                try {
                    & $Shell @SetupArguments
                    if ($LASTEXITCODE -ne 0) {
                        throw "Neovim setup failed (exit code $LASTEXITCODE)."
                    }
                }
                finally {
                    $env:Path = $CallerPath
                }
            }
            "zed" {
                $Staged = Expand-MoonEditorPackage "moon-zed" $TempDir
                $Destination = Join-Path $EditorDataDir "moon-zed"
                Set-MoonEditorDirectory $Staged $Destination
                Write-Output "moon extension unpacked to $Destination"
                Write-Output "Finish in Zed: run 'zed: install dev extension' and select that directory."
                Write-Output "Zed builds it with Rust, which must be installed through rustup."
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $TempDir) {
            Remove-Item -LiteralPath $TempDir -Recurse -Force
        }
    }
}

if ($EditorOnly) {
    $InstalledMoon = Join-Path $(if ($env:MOON_INSTALL) { $env:MOON_INSTALL } else { Join-Path $HOME ".moon" }) "bin\moon.exe"
    if (Test-Path -LiteralPath $InstalledMoon -PathType Leaf) {
        Install-MoonEditor $InstalledMoon
        return
    }
    $MoonCommand = Get-Command "moon" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $MoonCommand) {
        throw "moon is not installed; run this installer without -EditorOnly."
    }
    Install-MoonEditor $MoonCommand.Source
    return
}

$InstallInput = if ($env:MOON_INSTALL) { $env:MOON_INSTALL } else { Join-Path $HOME ".moon" }
$InstallDir = [IO.Path]::GetFullPath($InstallInput)
$InstallRoot = [IO.Path]::GetPathRoot($InstallDir)
$DirectorySeparators = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$NormalizedInstall = $InstallDir.TrimEnd($DirectorySeparators)
$NormalizedRoot = $InstallRoot.TrimEnd($DirectorySeparators)
$NormalizedHome = ([IO.Path]::GetFullPath($HOME)).TrimEnd($DirectorySeparators)
if (-not $NormalizedInstall -or $NormalizedInstall -eq $NormalizedRoot -or $NormalizedInstall -eq $NormalizedHome) {
    throw "Refusing unsafe install directory '$InstallDir'."
}
if ((Test-Path -LiteralPath $InstallDir) -and -not (Test-Path -LiteralPath $InstallDir -PathType Container)) {
    throw "Install path exists and is not a directory: '$InstallDir'."
}

$InstallParent = Split-Path -Parent $InstallDir
New-Item -ItemType Directory -Force -Path $InstallParent | Out-Null
$WorkDir = Join-Path $InstallParent (".moon-install-" + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $WorkDir | Out-Null

$SumsFile = Join-Path $WorkDir "SHA256SUMS"
$BackupDir = Join-Path $WorkDir "previous"
$Installed = $false
$ReplacementStarted = $false
$Committed = $false

try {
    # SHA256SUMS names each host's `moon-<version>-<host>.tar.gz`, so the
    # latest release needs no separate version lookup.
    try {
        Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl/SHA256SUMS" -OutFile $SumsFile
    }
    catch {
        throw "No moon release found at '$BaseUrl' ($($_.Exception.Message.Split("`n")[0].Trim()))."
    }
    $Asset = $null
    $ExpectedChecksum = $null
    foreach ($Line in Get-Content -LiteralPath $SumsFile) {
        if ($Line -cmatch '^\s*([0-9a-fA-F]{64})\s+\*?(moon-[0-9A-Za-z.+-]+-' + [regex]::Escape($HostName) + '\.tar\.gz)\s*$') {
            $ExpectedChecksum = $Matches[1].ToLowerInvariant()
            $Asset = $Matches[2]
            break
        }
    }
    if (-not $Asset) {
        throw "The release at '$BaseUrl' has no archive for $HostName."
    }
    $Root = $Asset.Substring(0, $Asset.Length - ".tar.gz".Length)
    $Url = "$BaseUrl/$Asset"
    $Archive = Join-Path $WorkDir $Asset

    Write-Output "Downloading $Url"
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Archive
    $ActualChecksum = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($ActualChecksum -ne $ExpectedChecksum) {
        throw "Checksum verification failed for '$Asset'."
    }

    # Reject absolute paths, parent traversal, links and anything outside the
    # one top-level directory before asking tar to write anything.
    $Entries = & $Tar -tzf $Archive
    if ($LASTEXITCODE -ne 0) {
        throw "Release archive '$Asset' could not be read."
    }
    foreach ($Name in $Entries) {
        $Name = $Name.Replace('\', '/')
        if ($Name.StartsWith('./')) { $Name = $Name.Substring(2) }
        $Segments = $Name.Split('/', [StringSplitOptions]::RemoveEmptyEntries)
        if ($Name.StartsWith('/') -or $Name -match '^[A-Za-z]:' -or $Segments.Count -eq 0 -or $Segments[0] -cne $Root -or $Segments -contains "..") {
            throw "Release archive contains an unexpected path: '$Name'."
        }
    }
    foreach ($Listing in (& $Tar -tvzf $Archive)) {
        if ($Listing.Length -eq 0 -or "-d".IndexOf($Listing[0]) -lt 0) {
            throw "Release archive contains a link or special file."
        }
    }

    $ExtractDir = Join-Path $WorkDir "extracted"
    New-Item -ItemType Directory -Path $ExtractDir | Out-Null
    & $Tar -xzf $Archive -C $ExtractDir
    if ($LASTEXITCODE -ne 0) {
        throw "Release archive '$Asset' could not be extracted."
    }
    $StagedDir = Join-Path $ExtractDir $Root
    $StagedExe = Join-Path $StagedDir "bin\moon.exe"
    if (-not (Test-Path -LiteralPath $StagedExe -PathType Leaf)) {
        throw "Release archive does not contain $Root/bin/moon.exe."
    }
    foreach ($Directory in "lib\moon\targets", "include\moon\std") {
        if (-not (Test-Path -LiteralPath (Join-Path $StagedDir $Directory) -PathType Container)) {
            throw "Release archive does not contain $Root/$($Directory.Replace('\', '/'))."
        }
    }

    if (Test-Path -LiteralPath $InstallDir) {
        Move-Item -LiteralPath $InstallDir -Destination $BackupDir
    }
    $ReplacementStarted = $true
    Move-Item -LiteralPath $StagedDir -Destination $InstallDir
    $Exe = Join-Path $InstallDir "bin\moon.exe"
    $VersionOutput = & $Exe --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Installed moon could not start (exit code $LASTEXITCODE):`n$($VersionOutput -join "`n")"
    }
    $Installed = $true
    $Committed = $true

    if (Test-Path -LiteralPath $BackupDir) {
        Remove-Item -LiteralPath $BackupDir -Recurse -Force
    }
}
finally {
    if (-not $Committed -and (Test-Path -LiteralPath $BackupDir)) {
        if (Test-Path -LiteralPath $InstallDir) {
            Remove-Item -LiteralPath $InstallDir -Recurse -Force
        }
        Move-Item -LiteralPath $BackupDir -Destination $InstallDir
    }
    elseif ($ReplacementStarted -and -not $Committed) {
        if (Test-Path -LiteralPath $InstallDir) {
            Remove-Item -LiteralPath $InstallDir -Recurse -Force
        }
    }
    if (Test-Path -LiteralPath $WorkDir) {
        Remove-Item -LiteralPath $WorkDir -Recurse -Force
    }
}

if (-not $Installed) {
    throw "moon installation did not complete."
}

$BinDir = Join-Path $InstallDir "bin"
$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
$PathEntries = if ($UserPath) { $UserPath.Split(';', [StringSplitOptions]::RemoveEmptyEntries) } else { @() }
$PathReady = $false
foreach ($Entry in $PathEntries) {
    if ($Entry.TrimEnd([char[]]'\') -ieq $BinDir.TrimEnd([char[]]'\')) {
        $PathReady = $true
        break
    }
}
if (-not $PathReady) {
    $NewUserPath = if ($UserPath) { "$BinDir;$UserPath" } else { $BinDir }
    [Environment]::SetEnvironmentVariable("Path", $NewUserPath, "User")
}
[Environment]::SetEnvironmentVariable("MOON_INSTALL", $InstallDir, "User")
$env:MOON_INSTALL = $InstallDir
if (@($env:Path.Split(';', [StringSplitOptions]::RemoveEmptyEntries) | Where-Object { $_.TrimEnd([char[]]'\') -ieq $BinDir.TrimEnd([char[]]'\') }).Count -eq 0) {
    $env:Path = "$BinDir;$env:Path"
}

Write-Output ""
Write-Output "moon was installed successfully to $(Join-Path $BinDir 'moon.exe')"
Write-Output ($VersionOutput | Select-Object -First 1)
if ($PathReady) {
    Write-Output "Run 'moon --help' to get started."
}
else {
    Write-Output "Open a new terminal, then run 'moon --help'."
}

if ($EditorName) {
    Write-Output ""
    Install-MoonEditor $Exe
}
