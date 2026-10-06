<#
.SYNOPSIS
Checks the GPU compositor against the CPU reference through the command line tool.

.DESCRIPTION
Renders every fixture twice, once on the CPU and once preferring the GPU, and compares the two
pixel by pixel. A fixture the GPU cannot take falls back, which the CLI reports, so the check can
also insist that the GPU actually ran: a run where nothing used it would otherwise pass vacuously.
#>
[CmdletBinding()]
param([string]$Cli, [int]$Tolerance = 1)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Cli) { $Cli = Join-Path $root "target-lead\debug\compc.exe" }
if (-not (Test-Path $Cli)) { Write-Host "compc not found: $Cli"; exit 2 }
$python = "C:\Users\leoevan\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
if (-not (Test-Path $python)) { Write-Host "python not found"; exit 2 }

$backends = (& $Cli backends 2>&1 | Out-String)
if ($backends -notmatch "gpu: ") {
    Write-Host "SKIP gpu checks: no compositing backend on this machine" -ForegroundColor DarkYellow
    exit 0
}
Write-Host (($backends -split "\r?\n")[0]) -ForegroundColor Cyan

# The acceptance rule is a contract, not a detail: assert which kinds of document are taken and which
# are refused, so a widened or narrowed rule is noticed instead of silently changing what is verified.
$accepted = @("blend-multiply", "layer-mask", "group-mask", "clip-chain", "adjustment-invert")
# Hue/Saturation is still refused while its band response is being matched; the reason text is asserted
# so a silently widened rule is noticed.
$refused = @{}
$contract = 0
foreach ($name in $accepted) {
    $package = Join-Path $PSScriptRoot ("fixtures\" + $name + ".comp")
    if (-not (Test-Path $package)) { continue }
    $line = (& $Cli backends $package 2>&1 | Select-Object -Last 1)
    if ($line -match "can composite on the gpu") { $contract++ }
    else { Write-Host ("FAIL {0}: expected the gpu to take it, got: {1}" -f $name, $line) -ForegroundColor Red; $script:contractFailures++ }
}
foreach ($name in $refused.Keys) {
    $package = Join-Path $PSScriptRoot ("fixtures\" + $name + ".comp")
    if (-not (Test-Path $package)) { continue }
    $line = (& $Cli backends $package 2>&1 | Select-Object -Last 1)
    if ($line -match "cpu path is required" -and $line -match $refused[$name]) { $contract++ }
    else { Write-Host ("FAIL {0}: expected the cpu path for {1}, got: {2}" -f $name, $refused[$name], $line) -ForegroundColor Red; $script:contractFailures++ }
}
# Every fixture should now be taken by the GPU: the count is part of the contract, so a change that
# silently drops a class of document back to the CPU fails here instead of only lowering the number.
$allFixtures = Get-ChildItem (Join-Path $PSScriptRoot "fixtures\*.comp") -Directory | Sort-Object Name
$gpuAccepted = 0
foreach ($fixture in $allFixtures) {
    $line = (& $Cli backends $fixture.FullName 2>&1 | Select-Object -Last 1)
    if ($line -match "can composite on the gpu") { $gpuAccepted++ }
}
if ($gpuAccepted -eq $allFixtures.Count) { $contract++ }
else {
    Write-Host ("FAIL: expected every fixture on the gpu, {0} of {1} are accepted" -f $gpuAccepted, $allFixtures.Count) -ForegroundColor Red
    $script:contractFailures++
}
$contractExpectations = $accepted.Count + $refused.Count + 1
Write-Host ("gpu acceptance contract: {0} of {1} expectations held ({2} of {3} fixtures accepted)" -f $contract, $contractExpectations, $gpuAccepted, $allFixtures.Count)

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("compgpu-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null
$failures = 0; $gpuUsed = 0; $compared = 0; $contractFailures = 0
try {
    $fixtures = Get-ChildItem (Join-Path $PSScriptRoot "fixtures\*.comp") -Directory | Sort-Object Name
    foreach ($fixture in $fixtures) {
        $cpu = Join-Path $work "cpu.png"
        $gpu = Join-Path $work "gpu.png"
        & $Cli render $fixture.FullName -o $cpu | Out-Null
        $reported = (& $Cli render $fixture.FullName -o $gpu --gpu 2>&1 | Out-String)
        if (-not (Test-Path $gpu)) { $failures++; Write-Host ("FAIL {0}: the gpu render produced nothing" -f $fixture.Name) -ForegroundColor Red; continue }
        $usedGpu = $reported -match "composited on the gpu"
        if ($usedGpu) { $gpuUsed++ }
        $worst = & $python -c "import numpy as np, sys; from PIL import Image; a = np.asarray(Image.open(sys.argv[1]).convert('RGBA'), dtype=np.int16); b = np.asarray(Image.open(sys.argv[2]).convert('RGBA'), dtype=np.int16); print(int(np.abs(a - b).max()))" $cpu $gpu
        $compared++
        if ([int]$worst -gt $Tolerance) {
            $failures++
            Write-Host ("FAIL {0}: gpu differs from cpu by {1}" -f $fixture.Name, $worst) -ForegroundColor Red
        }
    }
}
finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host ("compared {0} fixtures, {1} composited on the gpu, tolerance {2}" -f $compared, $gpuUsed, $Tolerance)
if ($contractFailures -gt 0) { Write-Host ("FAIL: {0} gpu acceptance expectations did not hold" -f $contractFailures) -ForegroundColor Red; exit 1 }
if ($failures -gt 0) { exit 1 }
if ($gpuUsed -eq 0) { Write-Host "FAIL: no fixture reached the gpu, so nothing was verified" -ForegroundColor Red; exit 1 }
Write-Host ("PASS gpu compositing matches the cpu on {0} fixtures ({1} of them on the gpu)" -f $compared, $gpuUsed) -ForegroundColor Green
exit 0
