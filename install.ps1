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
    throw "Invalid Moon version '$Target' (use latest or vX.Y.Z)."
}

if (-not [Environment]::Is64BitOperatingSystem) {
    throw "Moon releases require 64-bit Windows."
}
if (-not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::Windows)) {
    throw "This installer only supports Windows. Use install.sh on x86-64 Linux."
}

$Architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
switch ($Architecture) {
    "X64" { $Architecture = "x86_64" }
    default { throw "Moon tagged releases currently support only Windows x86_64 (detected '$Architecture')." }
}

$GitHub = if ($env:MOON_GITHUB) { $env:MOON_GITHUB.TrimEnd('/') } else { $DefaultGitHub }
$Repository = if ($env:MOON_GITHUB_REPO) { $env:MOON_GITHUB_REPO.Trim('/') } else { $DefaultRepository }
$Asset = "moon-windows-$Architecture.zip"
$Url = "$GitHub/$Repository/releases/$ReleasePath/$Asset"

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

$Archive = Join-Path $WorkDir $Asset
$ChecksumFile = "$Archive.sha256"
$BackupDir = Join-Path $WorkDir "previous"
$Installed = $false
$ReplacementStarted = $false
$Committed = $false

try {
    Write-Output "Downloading $Url"
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Archive
    Invoke-WebRequest -UseBasicParsing -Uri "$Url.sha256" -OutFile $ChecksumFile

    $ChecksumText = Get-Content -LiteralPath $ChecksumFile -Raw
    if ($ChecksumText -notmatch '(?im)^\s*([0-9a-f]{64})(?:\s|$)') {
        throw "Checksum asset does not start with a SHA-256 digest."
    }
    $ExpectedChecksum = $Matches[1].ToLowerInvariant()
    $ActualChecksum = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($ActualChecksum -ne $ExpectedChecksum) {
        throw "Checksum verification failed for '$Asset'."
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        foreach ($Entry in $Zip.Entries) {
            $Name = $Entry.FullName.Replace('\', '/')
            $Segments = $Name.Split('/', [StringSplitOptions]::RemoveEmptyEntries)
            if ($Name.StartsWith('/') -or $Segments.Count -eq 0 -or $Segments[0] -ne "moon" -or $Segments -contains "..") {
                throw "Release archive contains an unexpected path: '$Name'."
            }
        }
    }
    finally {
        $Zip.Dispose()
    }

    $ExtractDir = Join-Path $WorkDir "extracted"
    Expand-Archive -LiteralPath $Archive -DestinationPath $ExtractDir
    $StagedDir = Join-Path $ExtractDir "moon"
    $StagedExe = Join-Path $StagedDir "bin\moon.exe"
    if (-not (Test-Path -LiteralPath $StagedExe -PathType Leaf)) {
        throw "Release archive does not contain moon/bin/moon.exe."
    }
    foreach ($Directory in "lib", "include") {
        if (-not (Test-Path -LiteralPath (Join-Path $StagedDir $Directory) -PathType Container)) {
            throw "Release archive does not contain moon/$Directory."
        }
    }

    if (Test-Path -LiteralPath $InstallDir) {
        Move-Item -LiteralPath $InstallDir -Destination $BackupDir
    }
    $ReplacementStarted = $true
    Move-Item -LiteralPath $StagedDir -Destination $InstallDir
    $Exe = Join-Path $InstallDir "bin\moon.exe"
    $VersionOutput = & $Exe version 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Installed Moon could not start (exit code $LASTEXITCODE):`n$($VersionOutput -join "`n")"
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
    throw "Moon installation did not complete."
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
if (($env:Path.Split(';', [StringSplitOptions]::RemoveEmptyEntries) | Where-Object { $_.TrimEnd([char[]]'\') -ieq $BinDir.TrimEnd([char[]]'\') }).Count -eq 0) {
    $env:Path = "$BinDir;$env:Path"
}

Write-Output ""
Write-Output "Moon was installed successfully to $(Join-Path $BinDir 'moon.exe')"
Write-Output ($VersionOutput | Select-Object -First 1)
if ($PathReady) {
    Write-Output "Run 'moon --help' to get started."
}
else {
    Write-Output "Open a new terminal, then run 'moon --help'."
}
