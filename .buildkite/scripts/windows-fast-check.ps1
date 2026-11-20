$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Set-Location (Resolve-Path (Join-Path $PSScriptRoot '..\..'))

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'windows-runner-ready.ps1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$env:PATH = "$(Join-Path (Get-Location) '.tools\llvm\22.1.2\llvm\bin');$(Join-Path (Get-Location) '.tools\zig\0.17.0');$(Join-Path (Get-Location) '.tools\python-shim');$env:PATH"

Write-Host '--- Build compiler'
& zig build -Dtarget=x86_64-windows-gnu -Doptimize=fast
if ($LASTEXITCODE -ne 0) { throw 'Cyna Windows build failed' }

Write-Host '--- Run hosted std tests'
& zig build test-native -Dtarget=x86_64-windows-gnu -Dtest-filter='native std.' -j2 --summary all
if ($LASTEXITCODE -ne 0) { throw 'Cyna Windows hosted std tests failed' }

$declaredVersion = (& python .buildkite/scripts/current-version.py).Trim()
$actualVersion = (& .\zig-out\bin\cyna.exe version 2>&1 | Out-String).Trim()
if ($actualVersion -ne "cyna $declaredVersion") {
    throw "Cyna Windows version output was '$actualVersion', expected 'cyna $declaredVersion'"
}
