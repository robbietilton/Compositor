# Rebuilds the oracle's fixtures and compares every one of them with the Windows engine.
#
#   pwsh -File tools/verify/oracle/run_all.ps1
#
# Set COMPC to a different compc build, or -SkipBuild to reuse target-lead.
param(
    [switch]$SkipBuild,
    [string]$Compc = ""
)
$ErrorActionPreference = "Stop"
$oracle = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Resolve-Path (Join-Path $oracle "..\..\..")
$python = "C:\Users\leoevan\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"

if (-not $Compc) { $Compc = Join-Path $root "target-lead\debug\compc.exe" }
if (-not $SkipBuild -and -not (Test-Path $Compc)) {
    Write-Host "building compc into target-lead"
    $env:CARGO_TARGET_DIR = Join-Path $root "target-lead"
    Push-Location $root
    cargo build -p comp-cli
    Pop-Location
}

& $python (Join-Path $oracle "build_fixtures.py")
& $python (Join-Path $oracle "compare.py") --compc $Compc
exit $LASTEXITCODE
