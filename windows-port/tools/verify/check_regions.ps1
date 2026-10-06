<#
.SYNOPSIS
Checks that compositing a rectangle equals compositing everything and cropping.

.DESCRIPTION
The editor redraws only the area a stroke changed, so a region render that differs from a full one
shows up as a seam on screen. This renders every fixture in full, then renders three regions of it
and compares each against the corresponding crop. Equality is exact: a blurred layer needs pixels
from outside the rectangle, and a noise pattern is anchored to the document, so an implementation
that translates the document instead of rendering a frame differs here and nowhere else.
#>
[CmdletBinding()]
param([string]$Cli)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Cli) { $Cli = Join-Path $root "target-lead\debug\compc.exe" }
if (-not (Test-Path $Cli)) { Write-Host "compc not found: $Cli"; exit 2 }
$python = "C:\Users\leoevan\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
if (-not (Test-Path $python)) { Write-Host "python not found"; exit 2 }

$compare = @'
import numpy as np, sys
from PIL import Image
full = np.asarray(Image.open(sys.argv[1]).convert("RGBA"), dtype=np.int16)
part = np.asarray(Image.open(sys.argv[2]).convert("RGBA"), dtype=np.int16)
x, y, w, h = [int(v) for v in sys.argv[3].split(",")]
canvas = np.zeros((h, w, 4), dtype=np.int16)
sx, sy = max(0, x), max(0, y)
dx, dy = max(0, -x), max(0, -y)
cw = max(0, min(w - dx, full.shape[1] - sx))
ch = max(0, min(h - dy, full.shape[0] - sy))
if cw and ch:
    canvas[dy:dy + ch, dx:dx + cw] = full[sy:sy + ch, sx:sx + cw]
print(int(np.abs(canvas - part).max()))
'@

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("compregions-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null
$failures = 0; $checked = 0
try {
    # Two sets: the pixel fixtures, and packages built only to stress region rendering (blur halos,
    # document-anchored noise, effects that reach outside their layer).
    $fixtures = @()
    $fixtures += Get-ChildItem (Join-Path $PSScriptRoot "fixtures\*.comp") -Directory -ErrorAction SilentlyContinue
    $fixtures += Get-ChildItem (Join-Path $PSScriptRoot "fixtures-regions\*.comp") -Directory -ErrorAction SilentlyContinue
    $fixtures = $fixtures | Sort-Object Name
    foreach ($fixture in $fixtures) {
        $full = Join-Path $work "full.png"
        & $Cli render $fixture.FullName -o $full | Out-Null
        if ($LASTEXITCODE -ne 0) { $failures++; Write-Host ("FAIL {0}: the full render failed" -f $fixture.Name) -ForegroundColor Red; continue }
        $size = & $python -c "from PIL import Image; import sys; im = Image.open(sys.argv[1]); print(im.width, im.height)" $full
        $parts = $size -split " "
        $w = [int]$parts[0]; $h = [int]$parts[1]
        $regions = @(
            ("{0},{1},{2},{3}" -f 0, 0, [int]($w / 2), [int]($h / 2)),
            ("{0},{1},{2},{3}" -f [int]($w / 4), [int]($h / 4), [int]($w / 2), [int]($h / 2)),
            "-40,-30,64,64"
        )
        foreach ($region in $regions) {
            $checked++
            $part = Join-Path $work "region.png"
            if (Test-Path $part) { Remove-Item -Force $part }
            & $Cli render $fixture.FullName -o $part "--region=$region" | Out-Null
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path $part)) {
                $failures++
                Write-Host ("FAIL {0} region {1}: the region render failed" -f $fixture.Name, $region) -ForegroundColor Red
                continue
            }
            $worst = & $python -c $compare $full $part $region
            if ($worst -notmatch "^[0-9]+$") {
                $failures++
                Write-Host ("FAIL {0} region {1}: the comparison did not run" -f $fixture.Name, $region) -ForegroundColor Red
                continue
            }
            if ([int]$worst -ne 0) {
                $failures++
                Write-Host ("FAIL {0} region {1}: differs from the crop by {2}" -f $fixture.Name, $region, $worst) -ForegroundColor Red
            }
        }
    }
}
finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

if ($checked -eq 0) { Write-Host "FAIL: nothing was compared" -ForegroundColor Red; exit 1 }
if ($failures -gt 0) { Write-Host ("{0} of {1} region renders differed" -f $failures, $checked) -ForegroundColor Red; exit 1 }
Write-Host ("PASS {0} region renders equal the cropped full render exactly" -f $checked) -ForegroundColor Green
exit 0
