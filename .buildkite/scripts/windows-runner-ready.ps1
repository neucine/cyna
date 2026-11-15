$ErrorActionPreference = 'Stop'

foreach ($stage in @('dependencies', 'tools')) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'windows-release.ps1') -Stage $stage
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    if ($stage -eq 'dependencies') {
        Remove-Item Env:PRIVATE_REPO_READ_TOKEN -ErrorAction SilentlyContinue
    }
}
