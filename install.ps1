[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Position = 0)]
    [string]$Target = "latest",

    [Parameter(Position = 1)]
    [string[]]$Editor = @(),

    [string]$EditorPath,

    [string]$EditorConfig,

    [switch]$EditorOnly,

    [switch]$Interactive,

    [switch]$Yes,

    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$DefaultGitHub = "https://github.com"
$DefaultRepository = "moonlang-dev/moon-releases"

# Any parameter or MOON_INSTALL_ARGS marks a scripted run, which asks nothing
# unless told to.
$Configured = $PSBoundParameters.Count -gt 0 -or [bool]$env:MOON_INSTALL_ARGS

# `irm <url> | iex` cannot pass parameters, so MOON_INSTALL_ARGS can carry
# them instead as comma-separated pairs, such as
# "editor=nvim,editor-path=nvim,editor-only". A parameter passed explicitly
# wins.
if ($env:MOON_INSTALL_ARGS) {
    $ArgParameters = @{
        "editor"        = "Editor"
        "editor-path"   = "EditorPath"
        "editor-config" = "EditorConfig"
        "editor-only"   = "EditorOnly"
        "interactive"   = "Interactive"
        "yes"           = "Yes"
        "help"          = "Help"
    }
    $ArgEditors = @()
    foreach ($Pair in $env:MOON_INSTALL_ARGS.Split(',')) {
        if (-not $Pair.Trim()) {
            continue
        }
        $Key, $Value = $Pair -split '=', 2
        $Key = $Key.Trim()
        $Value = if ($null -ne $Value) { $Value.Trim() } else { "" }
        $Parameter = $ArgParameters[$Key]
        if (-not $Parameter) {
            throw "Unknown key '$Key' in MOON_INSTALL_ARGS (use editor, editor-path, editor-config, editor-only, interactive, yes, or help)."
        }
        if ($Parameter -in "EditorOnly", "Interactive", "Yes", "Help") {
            $Value = switch -Regex ($Value) {
                '^(|1|true|yes|on)$' { $true }
                '^(0|false|no|off)$' { $false }
                default { throw "Invalid value '$Value' for $Key in MOON_INSTALL_ARGS (use yes or no)." }
            }
            $Value = [switch]$Value
        }
        elseif (-not $Value) {
            throw "$Key in MOON_INSTALL_ARGS needs a value, as in $Key=<value>."
        }
        if ($Parameter -eq "Editor") {
            $ArgEditors += $Value
        }
        elseif ($Parameter -in "Interactive", "Yes") {
            # An explicit -Interactive or -Yes settles the question either way.
            if (-not ($PSBoundParameters.ContainsKey("Interactive") -or $PSBoundParameters.ContainsKey("Yes"))) {
                Set-Variable -Name $Parameter -Value $Value
            }
        }
        elseif (-not $PSBoundParameters.ContainsKey($Parameter)) {
            Set-Variable -Name $Parameter -Value $Value
        }
    }
    if ($ArgEditors.Count -gt 0 -and -not $PSBoundParameters.ContainsKey("Editor")) {
        $Editor = $ArgEditors
    }
}

if ($Help) {
    Write-Output @'
Usage: install.ps1 [[-Target] <version>] [[-Editor] <names>] [options]

Installs the moon toolchain and, optionally, editor integrations.

Run from a terminal with no parameters, the installer asks where to install
moon, which editors to set up, and where each integration goes. Given any
parameter, or without a terminal, it asks nothing and uses the defaults.

  -Target <version>     latest (default) or vX.Y.Z; MOON_VERSION also sets this
  -Editor <names>       vscode, sublime, jetbrains, neovim, or zed (also
                        accepts code, subl, and nvim); separate several with
                        commas
  -EditorPath <cmd>     editor command to use (vscode, neovim)
  -EditorConfig <dir>   where the integration is installed:
                          vscode     extensions directory
                          sublime    Packages directory
                          jetbrains  one IDE's plugins directory
                          neovim     config directory
                          zed        directory the extension is unpacked in
                        -EditorPath and -EditorConfig need exactly one editor
  -EditorOnly           keep the installed toolchain; install only the editors
  -Interactive          ask, with the other parameters as the suggested answers
  -Yes                  ask nothing
  -Help                 show this help

MOON_INSTALL sets the install directory, ~\.moon by default, and MOON_VERSION
sets -Target.

For `irm <url> | iex`, which cannot pass parameters, set MOON_INSTALL_ARGS to
comma-separated pairs instead; a parameter passed explicitly wins:

  $env:MOON_INSTALL_ARGS = "editor=nvim,editor-config=C:\nvim,editor-only"

Its keys are editor, editor-path, editor-config, editor-only, interactive,
yes, and help. The last four take yes or no, and a bare key means yes. Repeat
editor for several editors.
'@
    return
}

$AllEditors = @("vscode", "sublime", "jetbrains", "neovim", "zed")
$EditorLabels = @{
    vscode = "VS Code"; sublime = "Sublime Text"; jetbrains = "JetBrains"; neovim = "Neovim"; zed = "Zed"
}
$EditorAliases = @{
    vscode = "vscode"; code = "vscode"
    sublime = "sublime"; subl = "sublime"
    jetbrains = "jetbrains"
    neovim = "neovim"; nvim = "neovim"
    zed = "zed"
}
$Editors = @()
foreach ($Name in @($Editor | ForEach-Object { "$_".Split(',') } | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
    $Canonical = $EditorAliases[$Name]
    if (-not $Canonical) {
        throw "Unknown editor '$Name' (use vscode, sublime, jetbrains, neovim, or zed)."
    }
    if ($Editors -notcontains $Canonical) {
        $Editors += $Canonical
    }
}

if ($Interactive -and $Yes) {
    throw "-Interactive and -Yes cannot be combined."
}
if (($EditorPath -or $EditorConfig) -and $Editors.Count -ne 1) {
    throw "-EditorPath and -EditorConfig require exactly one editor."
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

$InstallInput = if ($env:MOON_INSTALL) { $env:MOON_INSTALL } else { Join-Path $HOME ".moon" }
$VsCodeCli = ""
$VsCodeDir = ""
$SublimeDir = ""
$JetBrainsTargets = @()
$NvimCli = ""
$NvimConfig = ""
$ZedDir = $EditorDataDir
if ($EditorPath -or $EditorConfig) {
    if ($EditorPath -and $Editors[0] -notin "vscode", "neovim") {
        throw "-EditorPath does not apply to $($Editors[0])."
    }
    switch ($Editors[0]) {
        "vscode" { $VsCodeCli = $EditorPath; $VsCodeDir = $EditorConfig }
        "sublime" { $SublimeDir = $EditorConfig }
        "jetbrains" { $JetBrainsTargets = @($EditorConfig) }
        "neovim" { $NvimCli = $EditorPath; $NvimConfig = $EditorConfig }
        "zed" { $ZedDir = $EditorConfig }
    }
}

# The Find-* functions look for what the parameters left unset, and return
# nothing when there is nothing to find.
function Find-MoonVsCode {
    $Command = Get-Command "code" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($Command) {
        return $Command.Source
    }
    return @(
        (Join-Path $LocalAppData "Programs\Microsoft VS Code\bin\code.cmd"),
        (Join-Path $env:ProgramFiles "Microsoft VS Code\bin\code.cmd")
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
}

function Find-MoonSublime {
    return "Sublime Text", "Sublime Text 3" |
        ForEach-Object { Join-Path $RoamingAppData "$_\Packages" } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Container } |
        Select-Object -First 1
}

# Every IDE that can load the plugin gets it. Older IDEs reject it, because
# the plugin's since-build is 262 (2026.2).
function Find-MoonJetBrains {
    $JetBrainsRoot = Join-Path $RoamingAppData "JetBrains"
    if (-not (Test-Path -LiteralPath $JetBrainsRoot -PathType Container)) {
        return
    }
    foreach ($Product in Get-ChildItem -LiteralPath $JetBrainsRoot -Directory) {
        if ($Product.Name -match '^[A-Za-z]+(\d{4})\.(\d+)$') {
            $Year = [int]$Matches[1]
            $Minor = [int]$Matches[2]
            if ($Year -gt 2026 -or ($Year -eq 2026 -and $Minor -ge 2)) {
                Join-Path $Product.FullName "plugins"
            }
        }
    }
}

function Test-MoonZed {
    return [bool](Get-Command "zed" -ErrorAction SilentlyContinue) -or
        (Test-Path -LiteralPath (Join-Path $RoamingAppData "Zed") -PathType Container) -or
        (Test-Path -LiteralPath (Join-Path $LocalAppData "Programs\Zed") -PathType Container)
}

# Returns what stops the Neovim setup from running, or nothing.
function Get-MoonNeovimProblem {
    if (-not ($env:CC -or (Get-Command "zig", "gcc", "clang" -ErrorAction SilentlyContinue))) {
        return "a C compiler is required to build the Neovim parser (set CC, or install zig, gcc, or clang)"
    }
}

function Resolve-MoonCommand([string]$Name) {
    $Command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $Command) {
        throw "Editor command not found: '$Name'."
    }
    return $Command.Source
}

function Resolve-MoonPath([string]$Path) {
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

# Reads one line from the terminal; an empty line means the default. $Shown
# stands in for a default that has no value to print.
function Read-MoonAnswer([string]$Prompt, [string]$Default = "", [string]$Shown = "") {
    if (-not $Shown) {
        $Shown = $Default
    }
    $Label = if ($Shown) { "$Prompt [$Shown]" } else { $Prompt }
    $Reply = "$(Read-Host $Label)".Trim()
    if ($Reply) {
        return $Reply
    }
    return $Default
}

function Read-MoonRequiredAnswer([string]$Prompt, [string]$Default = "") {
    while ($true) {
        $Reply = Read-MoonAnswer $Prompt $Default
        if ($Reply) {
            return $Reply
        }
        Write-Host "A value is needed here."
    }
}

$CanPrompt = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected -and
    -not ([Environment]::GetCommandLineArgs() | Where-Object { $_ -match '^-noni' })
if ($Interactive -and -not $CanPrompt) {
    throw "-Interactive needs a terminal to ask on."
}
if (-not $Interactive -and -not $Yes -and -not $Configured -and $CanPrompt) {
    $Interactive = $true
}

if ($Interactive) {
    Write-Host "moon installer"
    Write-Host "Press Enter to accept the answer in brackets."
    Write-Host ""
    if (-not $EditorOnly) {
        $InstallInput = Read-MoonAnswer "Install moon in" $InstallInput
    }

    if (-not $VsCodeCli) {
        $VsCodeCli = "$(Find-MoonVsCode)"
    }
    if (-not $SublimeDir) {
        $SublimeDir = "$(Find-MoonSublime)"
    }
    if ($JetBrainsTargets.Count -eq 0) {
        $JetBrainsTargets = @(Find-MoonJetBrains)
    }
    $NvimFound = $NvimCli
    if (-not $NvimFound) {
        $NvimCommand = Get-Command "nvim" -ErrorAction SilentlyContinue | Select-Object -First 1
        $NvimFound = if ($NvimCommand) { $NvimCommand.Source } else { "" }
    }
    $NvimProblem = Get-MoonNeovimProblem
    $EditorNotes = @{
        vscode    = $VsCodeCli
        sublime   = $SublimeDir
        jetbrains = switch ($JetBrainsTargets.Count) {
            0 { "" }
            1 { $JetBrainsTargets[0] }
            default { "$_ IDEs at 2026.2 or newer" }
        }
        neovim    = if ($NvimProblem) { "" } else { $NvimFound }
        zed       = if (Test-MoonZed) { "found" } else { "" }
    }

    Write-Host ""
    Write-Host "Editor integrations"
    $Detected = @()
    for ($Index = 0; $Index -lt $AllEditors.Count; $Index++) {
        $Name = $AllEditors[$Index]
        $Note = $EditorNotes[$Name]
        if ($Note) {
            $Detected += $Name
        }
        elseif ($Name -eq "jetbrains") {
            $Note = "no IDE at 2026.2 or newer found"
        }
        elseif ($Name -eq "neovim" -and $NvimFound) {
            $Note = "$NvimFound, but $NvimProblem"
        }
        else {
            $Note = "not found"
        }
        Write-Host ("  {0}) {1,-13} {2}" -f ($Index + 1), $EditorLabels[$Name], $Note)
    }
    $DefaultEditors = @(if ($Editors.Count -gt 0) { $Editors } else { $Detected })
    $DefaultSelection = if ($DefaultEditors.Count -gt 0) { $DefaultEditors -join " " } else { "none" }

    while ($true) {
        $Selection = Read-MoonAnswer "Editors to set up (numbers or names, 'all', or 'none')" $DefaultSelection
        $Chosen = @()
        $Valid = $true
        foreach ($Word in @($Selection -split '[,\s]+' | Where-Object { $_ })) {
            if ($Word -eq "all") {
                $Chosen = $AllEditors
            }
            elseif ($Word -eq "none") {
                $Chosen = @()
            }
            elseif ($Word -match '^[1-5]$') {
                $Chosen += $AllEditors[[int]$Word - 1]
            }
            elseif ($EditorAliases[$Word]) {
                $Chosen += $EditorAliases[$Word]
            }
            else {
                Write-Host "'$Word' is not one of the editors above."
                $Valid = $false
            }
        }
        if ($Valid) {
            break
        }
    }
    $Editors = @($AllEditors | Where-Object { $Chosen -contains $_ })

    foreach ($Name in $Editors) {
        switch ($Name) {
            "vscode" {
                $VsCodeCli = Read-MoonAnswer "VS Code command" $(if ($VsCodeCli) { $VsCodeCli } else { "code" })
                $VsCodeDir = Read-MoonAnswer "VS Code extensions directory" $VsCodeDir $(if ($VsCodeDir) { $VsCodeDir } else { "the default" })
            }
            "sublime" {
                $SublimeDir = Read-MoonRequiredAnswer "Sublime Text Packages directory" $SublimeDir
            }
            "jetbrains" {
                if ($JetBrainsTargets.Count -gt 1) {
                    Write-Host "JetBrains plugins directories found:"
                    $JetBrainsTargets | ForEach-Object { Write-Host "  $_" }
                    $Reply = Read-MoonAnswer "JetBrains plugins directory" "" "all $($JetBrainsTargets.Count) above"
                    if ($Reply) {
                        $JetBrainsTargets = @($Reply)
                    }
                }
                else {
                    $JetBrainsTargets = @(Read-MoonRequiredAnswer "JetBrains plugins directory" "$($JetBrainsTargets | Select-Object -First 1)")
                }
            }
            "neovim" {
                $NvimCli = Read-MoonAnswer "Neovim command" $(if ($NvimCli) { $NvimCli } else { "nvim" })
                $NvimConfig = Read-MoonAnswer "Neovim config directory" $NvimConfig $(if ($NvimConfig) { $NvimConfig } else { "the default" })
            }
            "zed" {
                $ZedDir = Read-MoonAnswer "Unpack the Zed extension in" $ZedDir
            }
        }
    }

    $Labels = @($Editors | ForEach-Object { $EditorLabels[$_] }) -join ", "
    if ($EditorOnly) {
        if (-not $Labels) {
            throw "No editor was selected, and -EditorOnly installs nothing else."
        }
        $Question = "Set up ${Labels}?"
    }
    else {
        $Question = "Install moon ($Target) in $InstallInput"
        if ($Labels) {
            $Question += " and set up $Labels"
        }
        $Question += "?"
    }
    Write-Host ""
    if ((Read-MoonAnswer $Question "y" "Y/n") -notmatch '^(y|yes)$') {
        Write-Host "Cancelled; nothing was installed."
        return
    }
    Write-Host ""
}

if ($EditorOnly -and $Editors.Count -eq 0) {
    throw "-EditorOnly requires an editor."
}

# Runs before the toolchain is touched, so a bad editor request changes nothing.
foreach ($Name in $Editors) {
    switch ($Name) {
        "vscode" {
            $VsCodeCli = if ($VsCodeCli) { Resolve-MoonCommand $VsCodeCli } else { "$(Find-MoonVsCode)" }
            if (-not $VsCodeCli) {
                throw "Could not find the 'code' command; pass -EditorPath."
            }
            if ($VsCodeDir) {
                $VsCodeDir = Resolve-MoonPath $VsCodeDir
            }
        }
        "sublime" {
            if (-not $SublimeDir) {
                $SublimeDir = "$(Find-MoonSublime)"
            }
            if (-not $SublimeDir) {
                throw "Could not find Sublime Text's Packages directory; pass -EditorConfig."
            }
            $SublimeDir = Resolve-MoonPath $SublimeDir
        }
        "jetbrains" {
            if ($JetBrainsTargets.Count -eq 0) {
                $JetBrainsTargets = @(Find-MoonJetBrains)
            }
            if ($JetBrainsTargets.Count -eq 0) {
                throw "Found no JetBrains IDE at version 2026.2 or newer; pass -EditorConfig."
            }
            $JetBrainsTargets = @($JetBrainsTargets | ForEach-Object { Resolve-MoonPath $_ })
        }
        "neovim" {
            if ($NvimCli) {
                $NvimCli = Resolve-MoonCommand $NvimCli
            }
            if ($NvimConfig) {
                $NvimConfig = Resolve-MoonPath $NvimConfig
            }
            $NvimProblem = Get-MoonNeovimProblem
            if ($NvimProblem) {
                throw "$($NvimProblem.Substring(0, 1).ToUpper())$($NvimProblem.Substring(1))."
            }
        }
        "zed" {
            $ZedDir = Resolve-MoonPath $ZedDir
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

function Install-MoonEditor([string]$Name, [string]$MoonExe) {
    $TempDir = Join-Path ([IO.Path]::GetTempPath()) ("moon-editor-" + [IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $TempDir | Out-Null
    Write-Output ""
    try {
        switch ($Name) {
            "vscode" {
                $Vsix = Get-MoonEditorAsset "moon-vscode.vsix" $TempDir
                $CliArguments = @("--install-extension", $Vsix, "--force")
                if ($VsCodeDir) {
                    $CliArguments += @("--extensions-dir", $VsCodeDir)
                }
                & $VsCodeCli @CliArguments
                if ($LASTEXITCODE -ne 0) {
                    throw "'$VsCodeCli' could not install the extension."
                }
                Write-Output "moon extension installed with $VsCodeCli"
            }
            "sublime" {
                $Staged = Expand-MoonEditorPackage "moon-sublime" $TempDir
                $Destination = Join-Path $SublimeDir "moon-sublime"
                Set-MoonEditorDirectory $Staged $Destination
                Write-Output "moon package installed to $Destination"
                Write-Output "For language server features, set up the LSP package as described in its README.md."
            }
            "jetbrains" {
                $Staged = Expand-MoonEditorPackage "moon-jetbrains" $TempDir
                foreach ($JetBrainsTarget in $JetBrainsTargets) {
                    $Destination = Join-Path $JetBrainsTarget "moon-jetbrains"
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
                if ($NvimConfig) {
                    $SetupArguments += @("-ConfigDir", $NvimConfig)
                }
                $CallerPath = $env:Path
                if ($NvimCli) {
                    $env:Path = "$(Split-Path -Parent $NvimCli);$env:Path"
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
                $Destination = Join-Path $ZedDir "moon-zed"
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

$InstallInput = Resolve-MoonPath $InstallInput
if ($EditorOnly) {
    $MoonExe = Join-Path $InstallInput "bin\moon.exe"
    if (-not (Test-Path -LiteralPath $MoonExe -PathType Leaf)) {
        $MoonCommand = Get-Command "moon" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $MoonCommand) {
            throw "moon is not installed; run this installer without -EditorOnly."
        }
        $MoonExe = $MoonCommand.Source
    }
    foreach ($Name in $Editors) {
        Install-MoonEditor $Name $MoonExe
    }
    return
}

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

foreach ($Name in $Editors) {
    Install-MoonEditor $Name $Exe
}
