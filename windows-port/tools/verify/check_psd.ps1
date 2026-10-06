<#
.SYNOPSIS
Checks PSD import against PSD files written by this repository's own generator.

.DESCRIPTION
PSD import used to be covered only by its own unit tests. psd_oracle.py writes real PSD bytes from
scratch -- header, colour mode, layer records, channel data with raw and RLE compression, layer masks --
and computes the composite it expects. Every case is imported through the CLI and rendered, so the
importer has to agree with a second implementation of the format. Note that the macOS app has no PSD
export at all, so parity here means import.
#>
[CmdletBinding()]
param([string]$Cli)

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Cli) { $Cli = Join-Path $root "target-lead\debug\compc.exe" }
if (-not (Test-Path $Cli)) { Write-Host "compc not found: $Cli"; exit 2 }
$python = "C:\Users\leoevan\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
$report = (& $python (Join-Path $PSScriptRoot "verify_psd.py") --cli $Cli 2>&1 | Out-String)
$failed = (($report -split "\r?\n") | Where-Object { $_ -match "^FAIL" })
foreach ($line in $failed) { Write-Host "    $line" -ForegroundColor Red }
$summary = (($report -split "\r?\n") | Where-Object { $_ -match "^\d+ PSD files" }) -join " "
if ($failed.Count -gt 0) { Write-Host ("FAIL " + $summary.Trim()) -ForegroundColor Red; exit 1 }
Write-Host ("PASS " + $summary.Trim()) -ForegroundColor Green
exit 0
