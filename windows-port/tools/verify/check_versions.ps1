<#
.SYNOPSIS
Checks that every format version from 1 to 11 is read, and that a feature used too early is refused.

.DESCRIPTION
The port claims to read .comp v1..v11. Each version added something: opacity and blend modes in 3,
layer masks in 4, clipping links in 5, folder masks in 6, adjustment layers in 7, folder opacity in 8,
neighbour-reading adjustments in 9, per-letter colours in 10, per-letter faces in 11. This validates
and renders one package per version and compares it against the independent compositor, then checks
that a package using a feature one version too early is refused -- by both readers.
#>
[CmdletBinding()]
param([string]$Cli)

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Cli) { $Cli = Join-Path $root "target-lead\debug\compc.exe" }
if (-not (Test-Path $Cli)) { Write-Host "compc not found: $Cli"; exit 2 }
$python = "C:\Users\leoevan\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
if (-not (Test-Path $python)) { Write-Host "python not found"; exit 2 }

$fixtures = Join-Path $PSScriptRoot "fixtures-versions"
if (-not (Test-Path $fixtures)) {
    Write-Host "generating the version fixtures" -ForegroundColor Cyan
    & $python (Join-Path $PSScriptRoot "make_version_fixtures.py") | Out-Null
}
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("compversions-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null
$failures = 0; $accepted = 0; $refused = 0
try {
    $versions = Get-ChildItem (Join-Path $fixtures "v*.comp") -Directory | Sort-Object { [int]($_.Name -replace "\D", "") }
    foreach ($package in $versions) {
        $stem = $package.Name -replace "\.comp$", ""
        $valid = & $Cli validate $package.FullName 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            $failures++
            Write-Host ("FAIL {0}: the validator refuses a legitimate package ({1})" -f $stem, ($valid.Trim() -split "`n")[0]) -ForegroundColor Red
            continue
        }
        $render = Join-Path $work ($stem + ".png")
        & $Cli render $package.FullName -o $render | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $render)) {
            $failures++
            Write-Host ("FAIL {0}: it does not render" -f $stem) -ForegroundColor Red
            continue
        }
        $accepted++
    }
    $validReport = & $python (Join-Path $PSScriptRoot "verify_versions.py") valid $fixtures $work 2>&1 | Out-String
    foreach ($line in ($validReport -split "`r?`n")) { if ($line -match "^FAIL") { Write-Host "    $line" -ForegroundColor Red; $failures++ } }

    $invalidDir = Join-Path $fixtures "invalid"
    if (Test-Path $invalidDir) {
        $tooEarly = Get-ChildItem (Join-Path $invalidDir "*.comp") -Directory | Sort-Object Name
        foreach ($package in $tooEarly) {
            $output = & $Cli validate $package.FullName 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0) {
                $failures++
                Write-Host ("FAIL {0}: accepted although the feature is too new for its version" -f $package.Name) -ForegroundColor Red
            }
            else { $refused++ }
        }
        $invalidReport = & $python (Join-Path $PSScriptRoot "verify_versions.py") invalid $invalidDir 2>&1 | Out-String
        foreach ($line in ($invalidReport -split "`r?`n")) { if ($line -match "^FAIL") { Write-Host "    $line" -ForegroundColor Red; $failures++ } }
    }
}
finally { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }

if ($failures -gt 0) { Write-Host ("FAIL: {0} version problems" -f $failures) -ForegroundColor Red; exit 1 }
Write-Host ("PASS {0} format versions read and rendered, {1} too-early packages refused by both readers" -f $accepted, $refused) -ForegroundColor Green
exit 0
