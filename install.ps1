param(
    [Parameter(Position = 0)]
    [string]$Target = "latest"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$DefaultGitHub = "https://github.com"
$DefaultRepository = "moonlang-dev/moon-releases"

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
