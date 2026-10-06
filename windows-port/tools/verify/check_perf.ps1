<#
.SYNOPSIS
Guards the interaction budget: one pointer sample to updated pixels.

.DESCRIPTION
The feasibility report called brush latency the project's biggest risk, and it measured 120 ms per
sample before the brush and region-compositing work brought it to about 8 ms. This runs the release
benchmark three times and takes the best run, because the machine is shared with other builds and a
loaded run can read many times slower than a quiet one. The gate is deliberately loose (25 ms against
a 16 ms budget): it is there to catch a regression to the old order of magnitude, not to police noise.
#>
[CmdletBinding()]
param([string]$Cli, [int]$BudgetMs = 25)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Cli) {
    $Cli = Join-Path $root "target-lead\release\compc.exe"
    if (-not (Test-Path $Cli)) {
        Write-Host "building the release CLI for a meaningful measurement" -ForegroundColor Cyan
        Push-Location $root
        $previous = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $env:CARGO_TARGET_DIR = Join-Path $root "target-lead"
            cargo build --release -p comp-cli *>&1 | Out-Null
        }
        finally {
            $ErrorActionPreference = $previous
            Pop-Location
        }
    }
}
if (-not (Test-Path $Cli)) { Write-Host "compc not found: $Cli"; exit 2 }

$best = [double]::MaxValue
$attempts = @()
for ($i = 1; $i -le 3; $i++) {
    $output = (& $Cli bench --canvas 4000 --brush 800 --samples 30 2>&1 | Out-String)
    $match = [regex]::Match($output, "sample to pixels:\s+([0-9.]+) ms")
    if (-not $match.Success) { Write-Host "FAIL: the benchmark did not report a figure" -ForegroundColor Red; exit 1 }
    $value = [double]$match.Groups[1].Value
    $attempts += $value
    if ($value -lt $best) { $best = $value }
    $brush = [regex]::Match($output, "brush sample\s+min\s+([0-9.]+) ms\s+median\s+([0-9.]+) ms")
    if ($brush.Success) { Write-Host ("attempt {0}: brush median {1} ms, sample to pixels {2} ms" -f $i, $brush.Groups[2].Value, $value) }
}

Write-Host ("best of {0}: {1:N2} ms per sample to pixels (budget 16 ms, gate {2} ms)" -f $attempts.Count, $best, $BudgetMs)
if ($best -gt $BudgetMs) {
    Write-Host "FAIL: the interaction budget regressed" -ForegroundColor Red
    exit 1
}
Write-Host "PASS interaction budget held" -ForegroundColor Green
exit 0
