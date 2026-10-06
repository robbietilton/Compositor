<#
.SYNOPSIS
Exercises the release and update tooling end to end.

.DESCRIPTION
Builds a fake release directory, hashes it, then checks every path the updater depends on: a newer
manifest is offered, an equal or older one is not, tampering is caught by the hash, applying parks
the previous build, and cleanup removes it. Exit code 1 when any step misbehaves.
#>
[CmdletBinding()]
param([string]$Cli)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Cli) { $Cli = Join-Path $root "target-lead\debug\compc.exe" }
if (-not (Test-Path $Cli)) { Write-Host "compc not found: $Cli"; exit 2 }

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("comprelease-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null
$failures = 0
function Check($name, $ok, $detail) {
    if ($ok) { Write-Host ("PASS {0,-24} {1}" -f $name, $detail) -ForegroundColor Green }
    else { Write-Host ("FAIL {0,-24} {1}" -f $name, $detail) -ForegroundColor Red; $script:failures++ }
}

try {
    Set-Content (Join-Path $work "compc.exe") "binary-one"
    Set-Content (Join-Path $work "compositor.exe") "binary-two"
    $manifest = Join-Path $work "update.json"
    & $Cli update describe --dir $work --version 0.2.0 -o $manifest | Out-Null
    Check "describe" (Test-Path $manifest) "wrote a manifest"

    $json = Get-Content $manifest -Raw | ConvertFrom-Json
    Check "manifest shape" ($json.files.Count -eq 2 -and $json.files[0].sha256.Length -eq 64) "$($json.files.Count) files hashed"

    $out = & $Cli update check $manifest --current 0.1.0
    Check "newer offered" ($out -match "update available") $out
    $out = & $Cli update check $manifest --current 0.2.0
    Check "equal is current" ($out -match "up to date") $out
    $out = & $Cli update check $manifest --current 0.1.0 --channel beta
    Check "channel respected" ($out -match "another channel") $out

    & $Cli update verify $manifest --dir $work | Out-Null
    Check "verify passes" ($LASTEXITCODE -eq 0) "clean payload"
    Set-Content (Join-Path $work "compc.exe") "binary-ONE"
    $null = & $Cli update verify $manifest --dir $work 2>&1
    Check "tampering caught" ($LASTEXITCODE -ne 0) "same length, different bytes"
    Set-Content (Join-Path $work "compc.exe") "binary-one"

    $target = Join-Path $work "installed.exe"
    $staged = Join-Path $work "staged.exe"
    Set-Content $target "old-build"
    Set-Content $staged "new-build"
    & $Cli update apply --staged $staged --target $target | Out-Null
    Check "apply swaps" ((Get-Content $target -Raw).Trim() -eq "new-build") "new build in place"
    $out = & $Cli update status --target $target
    Check "interrupted reported" ($out -match "parked") $out
    & $Cli update status --target $target --cleanup | Out-Null
    Check "cleanup" (-not (Test-Path ($target + ".previous"))) "previous build removed"
}
finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

if ($failures -gt 0) { exit 1 }
exit 0
