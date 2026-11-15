$ErrorActionPreference = 'Stop'

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'windows-runner-ready.ps1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

foreach ($stage in @('build', 'package')) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'windows-release.ps1') -Stage $stage
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
