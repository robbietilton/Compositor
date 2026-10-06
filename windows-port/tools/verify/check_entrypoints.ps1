<#
.SYNOPSIS
Checks that the editor and the command line composite a project identically.

.DESCRIPTION
Two entry points reach the same engine: compc render, and the editor in headless mode. They share the
CPU code path on purpose -- the editor fixes CPU for --flatten so a fixture comparison stays
reproducible -- so any difference means the two are not actually using the same code.
#>
[CmdletBinding()]
param([string]$Cli, [string]$Gui)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Cli) { $Cli = Join-Path $root "target-lead\debug\compc.exe" }
if (-not $Gui) {
    $Gui = Join-Path $root "target-lead\debug\comp-gui.exe"
    if (-not (Test-Path $Gui)) { $Gui = Join-Path $root "target-lead\debug\compositor.exe" }
}
if (-not (Test-Path $Cli)) { Write-Host "compc not found: $Cli"; exit 2 }
if (-not (Test-Path $Gui)) {
    Write-Host "the editor binary is not built in this target directory; building it" -ForegroundColor Cyan
    Push-Location $root
    # Cargo writes its progress to stderr; under $ErrorActionPreference = "Stop" that would abort the
    # script before the build even finished, so the stream is merged and the exit code is what counts.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $env:CARGO_TARGET_DIR = Join-Path $root "target-lead"
        cargo build -p comp-gui *>&1 | Out-Null
    }
    finally {
        $ErrorActionPreference = $previous
        Pop-Location
    }
}
if (-not (Test-Path $Gui)) { Write-Host "the editor binary could not be built"; exit 2 }
$python = "C:\Users\leoevan\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("compentry-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null
$failures = 0; $compared = 0
try {
    $fixtures = Get-ChildItem (Join-Path $PSScriptRoot "fixtures\*.comp") -Directory | Sort-Object Name
    foreach ($fixture in $fixtures) {
        $fromCli = Join-Path $work "cli.png"
        $fromGui = Join-Path $work "gui.png"
        & $Cli render $fixture.FullName -o $fromCli | Out-Null
        & $Gui --flatten $fixture.FullName $fromGui 2>&1 | Out-Null
        if (-not (Test-Path $fromGui)) { $failures++; Write-Host ("FAIL {0}: the editor produced nothing" -f $fixture.Name) -ForegroundColor Red; continue }
        $worst = & $python -c "import numpy as np, sys; from PIL import Image; a = np.asarray(Image.open(sys.argv[1]).convert('RGBA'), dtype=np.int16); b = np.asarray(Image.open(sys.argv[2]).convert('RGBA'), dtype=np.int16); print(int(np.abs(a - b).max()) if a.shape == b.shape else -1)" $fromCli $fromGui
        $compared++
        if ($worst -ne "0") { $failures++; Write-Host ("FAIL {0}: the editor and the cli differ by {1}" -f $fixture.Name, $worst) -ForegroundColor Red }
    }
}
finally { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }

if ($compared -eq 0) { Write-Host "FAIL: nothing was compared" -ForegroundColor Red; exit 1 }
if ($failures -gt 0) { Write-Host ("FAIL: {0} of {1} differed" -f $failures, $compared) -ForegroundColor Red; exit 1 }
Write-Host ("PASS the editor and the cli agree exactly on {0} fixtures" -f $compared) -ForegroundColor Green
exit 0
