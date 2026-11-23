param(
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$')]
    [string]$Version = $(if ($env:CYNA_RELEASE_VERSION) { $env:CYNA_RELEASE_VERSION } else { '0.5.4' })
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not [Environment]::Is64BitOperatingSystem -or [Environment]::OSVersion.Platform -ne 'Win32NT') {
    throw 'The Cyna PowerShell installer requires 64-bit Windows.'
}

$hostTriple = 'x86_64-pc-windows-gnu'
$installRoot = if ($env:CYNA_INSTALL_ROOT) { $env:CYNA_INSTALL_ROOT } else { Join-Path $HOME '.cyna' }
$baseUrl = if ($env:CYNA_DISTRIBUTION_BASE_URL) { $env:CYNA_DISTRIBUTION_BASE_URL.TrimEnd('/') } else { 'https://downloads.cyna.dev/distributions' }
$archiveUrl = if ($env:CYNA_DISTRIBUTION_URL) { $env:CYNA_DISTRIBUTION_URL } else { "$baseUrl/$Version/$hostTriple.zip?v=$Version" }
$destination = Join-Path $installRoot $Version
$binDir = Join-Path $installRoot 'bin'
$temporary = Join-Path ([IO.Path]::GetTempPath()) ("cyna-install-" + [guid]::NewGuid().ToString('N'))
$staged = Join-Path $installRoot ("$Version.staging-" + [guid]::NewGuid().ToString('N'))
$backup = Join-Path $installRoot ("$Version.backup-" + [guid]::NewGuid().ToString('N'))
$installed = $false

New-Item -ItemType Directory -Force $installRoot, $temporary | Out-Null
try {
    $archive = Join-Path $temporary 'distribution.zip'
    $extracted = Join-Path $temporary 'extracted'
    Write-Host "Downloading Cyna $Version for $hostTriple"
    Invoke-WebRequest -Uri $archiveUrl -OutFile $archive -UseBasicParsing
    Expand-Archive -LiteralPath $archive -DestinationPath $extracted

    $payload = Join-Path $extracted $hostTriple
    if (-not (Test-Path -LiteralPath (Join-Path $payload 'bin/cyna.exe') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $payload 'distribution.toml') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $payload 'llvm/bin') -PathType Container)) {
        throw 'The downloaded archive is not a complete Cyna Windows distribution.'
    }
    Move-Item -LiteralPath $payload -Destination $staged
    if (Test-Path -LiteralPath $destination) {
        Move-Item -LiteralPath $destination -Destination $backup
    }
    try {
        Move-Item -LiteralPath $staged -Destination $destination
    } catch {
        if (Test-Path -LiteralPath $backup) {
            Move-Item -LiteralPath $backup -Destination $destination
        }
        throw
    }

    $env:Path = "$(Join-Path $destination 'bin');$(Join-Path $destination 'llvm/bin');$env:Path"
    & (Join-Path $destination 'bin/cyna.exe') version
    if ($LASTEXITCODE -ne 0) { throw 'The installed Cyna compiler failed its version check.' }

    New-Item -ItemType Directory -Force $binDir | Out-Null
    $launcher = @'
@echo off
setlocal
set "CYNA_ROOT=%~dp0.."
for /f "usebackq delims=" %%V in ("%CYNA_ROOT%\current.txt") do set "CYNA_VERSION=%%V"
set "PATH=%CYNA_ROOT%\%CYNA_VERSION%\bin;%CYNA_ROOT%\%CYNA_VERSION%\llvm\bin;%PATH%"
"%CYNA_ROOT%\%CYNA_VERSION%\bin\cyna.exe" %*
'@
    [IO.File]::WriteAllText((Join-Path $binDir 'cyna.cmd'), $launcher + "`r`n", [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $installRoot 'current.txt'), $Version + "`r`n", [Text.Encoding]::ASCII)

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not (($userPath -split ';') -contains $binDir)) {
        [Environment]::SetEnvironmentVariable('Path', "$binDir;$userPath".TrimEnd(';'), 'User')
    }
    $env:Path = "$binDir;$env:Path"
    $installed = $true
    Write-Host "Installed Cyna $Version in $destination"
    Write-Host "Added $binDir to your user PATH. Open a new PowerShell window to use cyna."
} finally {
    if (-not $installed -and (Test-Path -LiteralPath $backup)) {
        Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction SilentlyContinue
        Move-Item -LiteralPath $backup -Destination $destination
    }
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $staged -Recurse -Force -ErrorAction SilentlyContinue
    if ($installed) { Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue }
}
