param([ValidateSet('dependencies', 'tools', 'build', 'package', 'all')][string]$Stage = 'all')
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Set-Location (Resolve-Path (Join-Path $PSScriptRoot '..\..'))
if ((& python --version) -notmatch '^Python 3\.13\.') { throw 'Python 3.13 is required' }

function Invoke-Dependencies {
Write-Host '--- Prepare dependencies'
& python .buildkite/scripts/windows-prepare.py dependencies
if ($LASTEXITCODE -ne 0) { throw 'Windows dependency preparation failed' }
Remove-Item Env:PRIVATE_REPO_READ_TOKEN -ErrorAction SilentlyContinue
}

function Invoke-Tools {
Write-Host '--- Prepare tools'
& python .buildkite/scripts/windows-prepare.py tools
if ($LASTEXITCODE -ne 0) { throw 'Windows tool preparation failed' }

$zigArchive = Join-Path (Get-Location) '.tools\zig\zig-x86_64-windows-0.17.0.zip'
$zigDir = Join-Path (Get-Location) '.tools\zig\0.17.0'
if (-not (Test-Path (Join-Path $zigDir 'zig.exe'))) {
    New-Item -ItemType Directory -Force (Split-Path $zigArchive) | Out-Null
    Copy-Item dist\windows-inputs\windows-zig.zip $zigArchive
    $digest = (Get-FileHash -Algorithm SHA256 $zigArchive).Hash.ToLowerInvariant()
    if ($digest -ne 'b5663f69581dcf391293fbf16c06cb80d81d806545ce618b4d0bab7f0eb8c428') { throw 'Zig checksum mismatch' }
    Expand-Archive -Path $zigArchive -DestinationPath (Split-Path $zigArchive) -Force
    Move-Item (Join-Path (Split-Path $zigArchive) 'zig-x86_64-windows-0.17.0') $zigDir
}
$env:PATH = "$zigDir;$env:PATH"
$shimDir = Join-Path (Get-Location) '.tools\python-shim'
New-Item -ItemType Directory -Force $shimDir | Out-Null
Copy-Item (Get-Command python.exe).Source (Join-Path $shimDir 'python3.exe') -Force
$env:PATH = "$shimDir;$env:PATH"
if ((& python3 --version) -notmatch '^Python 3\.13\.') { throw 'Python 3 shim failed' }
if ((& zig version) -ne '0.17.0') { throw 'Wrong Zig version' }

$llvmRoot = Join-Path (Get-Location) '.tools\llvm\22.1.2'
$llvmDir = Join-Path $llvmRoot 'llvm'
$llvmBin = Join-Path $llvmDir 'bin'
if (-not (Test-Path (Join-Path $llvmBin 'clang-ir.exe')) -or
    -not (Test-Path (Join-Path $llvmDir 'zig\lib'))) {
    if (Test-Path $llvmRoot) { Remove-Item -Recurse -Force $llvmRoot }
    New-Item -ItemType Directory -Force $llvmRoot | Out-Null
    Expand-Archive -Path 'dist\windows-inputs\windows-llvm.zip' -DestinationPath $llvmRoot -Force
    Copy-Item (Join-Path $llvmBin 'clang.exe') (Join-Path $llvmBin 'clang-ir.exe') -Force
    New-Item -ItemType Directory -Force (Join-Path $llvmDir 'zig') | Out-Null
    Copy-Item (Join-Path $zigDir 'zig.exe') (Join-Path $llvmDir 'zig\zig.exe') -Force
    Copy-Item (Join-Path $zigDir 'lib') (Join-Path $llvmDir 'zig\lib') -Recurse -Force
}
& zig cc .buildkite\scripts\windows-clang-wrapper.c -O2 -o (Join-Path $llvmBin 'clang.exe')
if ($LASTEXITCODE -ne 0) { throw 'Windows portable Clang wrapper failed' }
$env:PATH = "$llvmBin;$env:PATH"
}

function Invoke-Build {
if ($releaseMode -eq 'preflight') { return }
$env:PATH = "$(Join-Path (Get-Location) '.tools/zig/0.17.0');$(Join-Path (Get-Location) '.tools/python-shim');$env:PATH"
Write-Host '--- Build binary'
& zig build -Dtarget=x86_64-windows-gnu -Doptimize=fast
if ($LASTEXITCODE -ne 0) { throw 'Cyna Windows build failed' }
& zig cc .buildkite\scripts\windows-clang-wrapper.c -O2 -o dist\windows-clang-wrapper.exe
if ($LASTEXITCODE -ne 0) { throw 'Windows Zig compiler driver build failed' }
& cmd.exe /d /c '.\zig-out\bin\cyna.exe version 2>&1'
$versionExitCode = $LASTEXITCODE
if ($versionExitCode -ne 0) { throw 'Cyna Windows executable failed' }
& buildkite-agent artifact upload 'zig-out/bin/cyna.exe'
if ($LASTEXITCODE -ne 0) { throw 'Could not upload Windows compiler' }
}

function Invoke-Package {
if ($releaseMode -eq 'preflight') { return }
Write-Host '--- Package distribution'
& python .buildkite/scripts/windows-package.py
if ($LASTEXITCODE -ne 0) { throw 'Windows distribution packaging failed' }
& buildkite-agent artifact upload "dist/distributions/$releaseVersion/*.zip"
if ($LASTEXITCODE -ne 0) { throw 'Could not upload Windows distribution' }

$stage = Join-Path (Get-Location) "dist\distributions\$releaseVersion\x86_64-pc-windows-gnu"
$smokeHome = Join-Path (Get-Location) 'dist\windows-smoke-home'
if (Test-Path $smokeHome) { Remove-Item $smokeHome -Recurse -Force }
$installed = Join-Path $smokeHome ".cyna\$releaseVersion"
New-Item -ItemType Directory -Force $installed | Out-Null
Copy-Item "$stage\*" $installed -Recurse -Force
$env:HOME = $smokeHome
$env:PATH = "$(Join-Path $installed 'bin');$(Join-Path $installed 'llvm\bin');$env:PATH"
$versionCommand = '"{0}" version 2>&1' -f (Join-Path $installed 'bin\cyna.exe')
& cmd.exe /d /c $versionCommand
$versionExitCode = $LASTEXITCODE
if ($versionExitCode -ne 0) { throw 'Packaged Cyna version check failed' }
$simpleSource = Join-Path (Get-Location) 'dist\windows-smoke-simple.cy'
$simpleExe = Join-Path (Get-Location) 'dist\windows-smoke-simple.exe'
Set-Content -Path $simpleSource -Value 'fn main(): i32 { return 42; }' -Encoding Ascii
& (Join-Path $installed 'bin\cyna.exe') build $simpleSource --verbose --output $simpleExe
if ($LASTEXITCODE -ne 0) { throw "Packaged Windows simple build returned $LASTEXITCODE" }
& $simpleExe
if ($LASTEXITCODE -ne 42) { throw "Packaged Windows simple executable returned $LASTEXITCODE, expected 42" }
# Exercise LG-104 through the installed driver, including the GNU headers/CRT.
$gnuProject = Join-Path (Get-Location) 'dist\windows-smoke-gnu'
New-Item -ItemType Directory -Force $gnuProject | Out-Null
Set-Content -Path (Join-Path $gnuProject 'main.cy') -Encoding Ascii -Value @'
extern c("gnu_helper") fn gnu_helper(): c_int;
fn main(): i32 { return gnu_helper() as i32; }
'@
Set-Content -Path (Join-Path $gnuProject 'helper.c') -Encoding Ascii -Value @'
#include <math.h>
#include <stdlib.h>
#ifndef __MINGW32__
#error Expected Windows GNU headers
#endif
extern int asm_helper(void);
int gnu_helper(void) {
    volatile double value = 4.0;
    void *allocation = malloc(16);
    if (!allocation) return 1;
    free(allocation);
    return (int)sqrt(value) + asm_helper();
}
'@
Set-Content -Path (Join-Path $gnuProject 'helper.S') -Encoding Ascii -Value @'
.text
.globl asm_helper
asm_helper:
    movl $40, %eax
    ret
'@
foreach ($gnuTarget in @('native', 'x86_64-pc-windows-gnu')) {
    Set-Content -Path (Join-Path $gnuProject 'cyna.toml') -Encoding Ascii -Value @"
name = "gnu-smoke"
entry = "main.cy"
[build]
target = "$gnuTarget"
[c]
sources = ["helper.c"]
[asm]
sources = ["helper.S"]
"@
    $gnuExe = Join-Path $gnuProject "$gnuTarget.exe"
    & (Join-Path $installed 'bin\cyna.exe') build $gnuProject --jobs 1 --verbose --output $gnuExe
    if ($LASTEXITCODE -ne 0) { throw "Packaged Windows GNU build failed for $gnuTarget" }
    & $gnuExe
    if ($LASTEXITCODE -ne 42) { throw "Packaged Windows GNU executable returned $LASTEXITCODE for $gnuTarget" }
}
$readInput = Join-Path (Get-Location) 'dist\windows-smoke-input.txt'
[System.IO.File]::WriteAllText($readInput, 'ok')
$readSource = Join-Path (Get-Location) 'dist\windows-smoke-read.cy'
Set-Content -Path $readSource -Encoding Ascii -Value @'
import std.fs;
fn main(): i32 {
    const value = fs.read_file("dist/windows-smoke-input.txt") catch (code) { return 1; };
    if value == "ok" { return 42; }
    return 2;
}
'@
$readExe = Join-Path (Get-Location) 'dist\windows-smoke-read.exe'
& (Join-Path $installed 'bin\cyna.exe') build $readSource --output $readExe
if ($LASTEXITCODE -ne 0) { throw 'Packaged Windows file read build failed' }
& $readExe
if ($LASTEXITCODE -ne 42) { throw "Packaged Windows file read returned $LASTEXITCODE, expected 42" }
$smokeFailures = @()
foreach ($case in @('list_copy', 'map_owned', 'set_owned', 'milestone_app')) {
    $source = Join-Path (Get-Location) "examples\$case.cy"
    $output = Join-Path (Get-Location) "dist\windows-smoke-$case.exe"
    & (Join-Path $installed 'bin\cyna.exe') build $source --output $output
    if ($LASTEXITCODE -ne 0) { throw "Packaged Windows $case build returned $LASTEXITCODE" }
    & $output
    Write-Host "Windows $case exit code: $LASTEXITCODE"
    if ($LASTEXITCODE -ne 42) { $smokeFailures += $case }
}
$planner = Join-Path (Get-Location) 'examples\planner_app\main.cy'
$plannerExe = Join-Path (Get-Location) 'dist\windows-smoke-planner.exe'
& (Join-Path $installed 'bin\cyna.exe') build $planner --verbose --output $plannerExe
if ($LASTEXITCODE -ne 0) { throw "Packaged Windows planner build returned $LASTEXITCODE" }
& $plannerExe
Write-Host "Windows planner exit code: $LASTEXITCODE"
if ($LASTEXITCODE -ne 42) { $smokeFailures += 'planner_app' }
if ($smokeFailures.Count -ne 0) { throw "Packaged Windows smoke failed: $($smokeFailures -join ', ')" }
}

$declaredVersion = (& python .buildkite/scripts/current-version.py).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Could not read the declared Cyna version' }
$releaseVersion = (& buildkite-agent meta-data get release_version --default $declaredVersion).Trim()
$releaseMode = (& buildkite-agent meta-data get release_mode --default full).Trim()
if ($Stage -in @('build', 'package', 'all')) {
    if ($releaseVersion -ne $declaredVersion) { throw "Windows release version $releaseVersion differs from declared version $declaredVersion" }
    if ($releaseMode -notin @('full', 'preflight')) { throw "Invalid release mode: $releaseMode" }
}

switch ($Stage) {
    dependencies { Invoke-Dependencies }
    tools { Invoke-Tools }
    build { Invoke-Build }
    package { Invoke-Package }
    all {
        Invoke-Dependencies
        Invoke-Tools
        Invoke-Build
        Invoke-Package
    }
}
