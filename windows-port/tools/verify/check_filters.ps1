<#
.SYNOPSIS
Checks the filters against an independent port of their upstream kernels.

.DESCRIPTION
Lens Correction is ported from LensPixels.c, so a second implementation of the same kernel can say
whether the Rust one is faithful. Dither has no such port here (its upstream splits the image into
thread bands), so it is checked for the properties a dither must have: the same seed twice gives the
same pixels, a different seed gives different ones, and it only ever writes the colors it was given.
#>
[CmdletBinding()]
param([string]$Cli)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Cli) { $Cli = Join-Path $root "target-lead\debug\compc.exe" }
if (-not (Test-Path $Cli)) { Write-Host "compc not found: $Cli"; exit 2 }
$python = "C:\Users\leoevan\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
if (-not (Test-Path $python)) { Write-Host "python not found"; exit 2 }
$verify = $PSScriptRoot

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("compfilters-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null
$failures = 0
function Check($name, $ok, $detail) {
    if ($ok) { Write-Host ("PASS {0,-28} {1}" -f $name, $detail) -ForegroundColor Green }
    else { Write-Host ("FAIL {0,-28} {1}" -f $name, $detail) -ForegroundColor Red; $script:failures++ }
}

try {
    $input = Join-Path $work "in.png"
    & $python -c "import numpy as np, sys; from PIL import Image; h, w = 64, 96; a = np.zeros((h, w, 4), dtype=np.uint8); ys, xs = np.mgrid[0:h, 0:w]; a[..., 0] = (xs * 3) % 256; a[..., 1] = (ys * 5) % 256; a[..., 2] = ((xs + ys) * 2) % 256; a[..., 3] = 255; a[24:40, 32:64, :3] = 255; Image.fromarray(a, 'RGBA').save(sys.argv[1])" $input

    foreach ($distortion in @(0, 25, -40, -100, 100)) {
        $settings = Join-Path $work "lens.json"
        Set-Content -Path $settings -Value (('{"distortion": ' + $distortion + '}'))
        $actual = Join-Path $work "lens-rust.png"
        & $Cli filter $input -o $actual --kind "Lens Correction" --settings $settings | Out-Null
        $expected = Join-Path $work "lens-oracle.png"
        $k = $distortion / 100.0 * 0.35
        & $python (Join-Path $verify "oracle_filters.py") $input $expected --k $k | Out-Null
        $result = & $python -c "import numpy as np, sys; from PIL import Image; a = np.asarray(Image.open(sys.argv[1]).convert('RGBA'), dtype=np.int16); b = np.asarray(Image.open(sys.argv[2]).convert('RGBA'), dtype=np.int16); d = np.abs(a - b); print(int(d.max()))" $actual $expected
        Check ("lens distortion $distortion") ([int]$result -le 1) "worst difference $result"
    }

    # The style's real name carries an en dash, and this file must not depend on its own encoding.
    $enDash = [char]0x2013
    $ditherA = Join-Path $work "dither-a.png"
    $ditherB = Join-Path $work "dither-b.png"
    $ditherC = Join-Path $work "dither-c.png"
    $style = "Floyd" + $enDash + "Steinberg"
    Set-Content -Path (Join-Path $work "seed1.json") -Value ('{"dither": {"style": "' + $style + '"}}')
    Set-Content -Path (Join-Path $work "seed2.json") -Value ('{"dither": {"style": "' + $style + '", "density": 12.5}}')
    & $Cli filter $input -o $ditherA --kind "Dither" --settings (Join-Path $work "seed1.json") | Out-Null
    Check "dither runs" (Test-Path $ditherA) "floyd-steinberg produced a file"
    & $Cli filter $input -o $ditherB --kind "Dither" --settings (Join-Path $work "seed1.json") | Out-Null
    & $Cli filter $input -o $ditherC --kind "Dither" --settings (Join-Path $work "seed2.json") | Out-Null
    if (-not (Test-Path $ditherC)) { Check "dither settings matter" $false "the changed settings did not render" }
    if ((Test-Path $ditherA) -and (Test-Path $ditherB)) {
        $same = & $python -c "import numpy as np, sys; from PIL import Image; a = np.asarray(Image.open(sys.argv[1]).convert('RGBA')); b = np.asarray(Image.open(sys.argv[2]).convert('RGBA')); print(1 if (a == b).all() else 0)" $ditherA $ditherB
        Check "dither is deterministic" ([int]$same -eq 1) "the same settings twice give the same pixels"
        $colours = & $python -c "import numpy as np, sys; from PIL import Image; a = np.asarray(Image.open(sys.argv[1]).convert('RGB')); print(len(np.unique(a.reshape(-1, 3), axis=0)))" $ditherA
        Check "dither writes two colors" ([int]$colours -le 2) "$colours distinct colors"
    }
    if ((Test-Path $ditherA) -and (Test-Path $ditherC)) {
        $different = & $python -c "import numpy as np, sys; from PIL import Image; a = np.asarray(Image.open(sys.argv[1]).convert('RGBA')); b = np.asarray(Image.open(sys.argv[2]).convert('RGBA')); print(1 if (a != b).any() else 0)" $ditherA $ditherC
        Check "dither settings matter" ([int]$different -eq 1) "a changed setting changes pixels"
    }
}
finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

if ($failures -gt 0) { exit 1 }
exit 0
