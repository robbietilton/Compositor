<#
.SYNOPSIS
Runs every compc subcommand, once on the way in and once on the way out.

.DESCRIPTION
compc is the non-GUI surface of the format: a script or an agent builds, inspects, extracts from,
rasterizes and exports projects with it, and the editor's own save path is the same code. Most
commands are driven by some other check in this directory for its own subject; this one exists for
the commands none of them touch (create, extract, sample, rasterize, info, layers, filters, raw)
and, for *every* subcommand, for the failure path: a missing argument, a bad value, a file that is
not there, a project that is damaged. A command that answers a broken call with exit code 0 is
worse than one that prints nothing, because a script cannot tell the two apart.

Each check asserts the exit code and either a line of standard output or a file on disk. The
success semantics of render/export/import/psd/bench/resave and the update tooling are covered in
depth by check_regions.ps1, check_filters.ps1, check_psd.ps1, check_perf.ps1 and check_release.ps1;
here they are smoke-tested and, more to the point, their argument surface is.

Exit code 1 when any check fails, 2 when compc is not built.
#>
[CmdletBinding()]
param([string]$Cli)

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Cli) { $Cli = Join-Path $root "target-lead\debug\compc.exe" }
if (-not (Test-Path $Cli)) { Write-Host "compc not found: $Cli"; exit 2 }
$python = "C:\Users\leoevan\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
if (-not (Test-Path $python)) { Write-Host "python not found: $python"; exit 2 }

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("compcli-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null

$script:checks = 0
$script:failures = 0
function Check($name, $ok, $detail) {
    $script:checks++
    if ($ok) { Write-Host ("PASS {0,-30} {1}" -f $name, $detail) -ForegroundColor Green }
    else { Write-Host ("FAIL {0,-30} {1}" -f $name, $detail) -ForegroundColor Red; $script:failures++ }
}

function Invoke-Cli {
    param([string[]]$Arguments)
    $output = (& $Cli @Arguments 2>&1 | Out-String)
    [pscustomobject]@{ Code = $LASTEXITCODE; Output = $output }
}

function First-Line($text) {
    return (($text -split "\r?\n") | Where-Object { $_.Trim() } | Select-Object -First 1)
}

function Expect-Pass($name, $result, $pattern) {
    $ok = $result.Code -eq 0
    $detail = "exit $($result.Code)"
    if ($pattern) {
        $matched = $result.Output -match $pattern
        $ok = $ok -and $matched
        if ($matched) { $detail = "$detail, matched /$pattern/" }
        else { $detail = "$detail, no /$pattern/ in: $(First-Line $result.Output)" }
    }
    Check $name $ok $detail
}

function Expect-Fail($name, $result) {
    # A refusal must also be a refusal and not a crash.
    $crashed = $result.Output -match "panicked at|RUST_BACKTRACE"
    Check $name ($result.Code -ne 0 -and -not $crashed) ("exit $($result.Code): " + (First-Line $result.Output))
}

function Assert-File($name, $path) {
    Check $name (Test-Path $path) $path
}

function Read-Png($path) {
    return (& $python -c "import sys; from PIL import Image; im = Image.open(sys.argv[1]).convert('RGBA'); print(im.size[0], im.size[1], im.getpixel((im.size[0] // 2, im.size[1] // 2)))" $path | Out-String).Trim()
}

try {
    # ---------------------------------------------------------------- create
    $base = Join-Path $work "base.comp"
    $created = Invoke-Cli @("create", $base, "--width", "8", "--height", "8", "--color", "ff8800")
    Expect-Pass "create" $created "created"
    $valid = Invoke-Cli @("validate", $base)
    Expect-Pass "create/validate" $valid "ok: 1 layers, 8x8, digest"
    $rendered = Join-Path $work "base.png"
    $render = Invoke-Cli @("render", $base, "-o", $rendered)
    Expect-Pass "create/render" $render "rendered"
    Check "create/render pixels" ((Read-Png $rendered) -eq "8 8 (255, 136, 0, 255)") (Read-Png $rendered)

    $named = Join-Path $work "named.comp"
    $null = Invoke-Cli @("create", $named, "--width", "12", "--height", "7", "--color", "ff880080", "--name", "Sky", "--resolution", "300")
    $info = Invoke-Cli @("info", $named)
    Expect-Pass "create/--name/--resolution" $info "canvas     12 x 7 at 300 ppi"
    $layerList = Invoke-Cli @("layers", $named)
    Check "create/--name reaches layers" ($layerList.Output -match "Sky \[raster\]") (First-Line $layerList.Output)

    Expect-Fail "create/bad color" (Invoke-Cli @("create", (Join-Path $work "bad.comp"), "--width", "4", "--height", "4", "--color", "zz"))
    Expect-Fail "create/missing --height" (Invoke-Cli @("create", (Join-Path $work "half.comp"), "--width", "4"))
    Expect-Fail "create/zero size" (Invoke-Cli @("create", (Join-Path $work "zero.comp"), "--width", "0", "--height", "4"))

    # ---------------------------------------------------------------- info / layers
    $json = Invoke-Cli @("info", $named, "--json")
    Expect-Pass "info --json" $json '"format"'
    $parsed = $null
    try { $parsed = $json.Output | ConvertFrom-Json } catch { }
    Check "info --json parses" ($null -ne $parsed -and $parsed.width -eq 12 -and $parsed.height -eq 7) "width/height from the manifest"
    Expect-Fail "info/missing package" (Invoke-Cli @("info", (Join-Path $work "gone.comp")))
    Expect-Fail "layers/missing package" (Invoke-Cli @("layers", (Join-Path $work "gone.comp")))
    Expect-Fail "info/no package argument" (Invoke-Cli @("info"))

    # a damaged package: an asset cut in half, which every reader must refuse
    $damaged = Join-Path $work "damaged.comp"
    Copy-Item $base $damaged -Recurse
    $asset = Get-ChildItem (Join-Path $damaged "images") | Select-Object -First 1
    $bytes = [System.IO.File]::ReadAllBytes($asset.FullName)
    [System.IO.File]::WriteAllBytes($asset.FullName, $bytes[0..([int]($bytes.Length / 2))])
    Expect-Fail "validate/damaged package" (Invoke-Cli @("validate", $damaged))
    Expect-Fail "info/damaged package" (Invoke-Cli @("info", $damaged))
    Expect-Fail "validate/missing package" (Invoke-Cli @("validate", (Join-Path $work "gone.comp")))

    # ---------------------------------------------------------------- extract
    $assetName = (Get-ChildItem (Join-Path $base "images") | Select-Object -First 1).Name
    $extracted = Join-Path $work "layer.png"
    $extract = Invoke-Cli @("extract", $base, "--layer", "Background", "-o", $extracted)
    Expect-Pass "extract" $extract "wrote"
    $same = (Get-FileHash $extracted).Hash -eq (Get-FileHash (Join-Path $base "images\$assetName")).Hash
    Check "extract matches the asset" $same "byte for byte against images/$assetName"

    $samplePkg = Join-Path $work "sample.comp"
    $null = Invoke-Cli @("sample", $samplePkg)
    $maskOut = Join-Path $work "mask.png"
    $maskResult = Invoke-Cli @("extract", $samplePkg, "--layer", "Folder", "--mask", "-o", $maskOut)
    Expect-Pass "extract --mask" $maskResult "wrote"
    Check "extract --mask size" ((Read-Png $maskOut) -like "320 200 *") (Read-Png $maskOut)
    Expect-Fail "extract/unknown layer" (Invoke-Cli @("extract", $base, "--layer", "NoSuchLayer", "-o", (Join-Path $work "x.png")))
    Expect-Fail "extract/no --output" (Invoke-Cli @("extract", $base, "--layer", "Background"))
    Expect-Fail "extract/no --layer" (Invoke-Cli @("extract", $base, "-o", (Join-Path $work "x.png")))
    Expect-Fail "extract/mask where there is none" (Invoke-Cli @("extract", $base, "--layer", "Background", "--mask", "-o", (Join-Path $work "y.png")))

    # ---------------------------------------------------------------- render / resave / backends
    $region = Join-Path $work "region.png"
    Expect-Pass "render --region" (Invoke-Cli @("render", $base, "-o", $region, "--region", "2,2,4,4")) "rendered"
    Check "render --region size" ((Read-Png $region) -like "4 4 *") (Read-Png $region)
    Expect-Fail "render/no --output" (Invoke-Cli @("render", $base))
    Expect-Fail "render/bad region" (Invoke-Cli @("render", $base, "-o", (Join-Path $work "r2.png"), "--region", "2,2"))
    Expect-Fail "render/missing package" (Invoke-Cli @("render", (Join-Path $work "gone.comp"), "-o", (Join-Path $work "r3.png")))

    $resaved = Join-Path $work "resaved.comp"
    Expect-Pass "resave" (Invoke-Cli @("resave", $named, $resaved)) "resaved"
    Expect-Pass "resave/validate" (Invoke-Cli @("validate", $resaved)) "ok: 1 layers, 12x7"
    Expect-Fail "resave/missing source" (Invoke-Cli @("resave", (Join-Path $work "gone.comp"), (Join-Path $work "r4.comp")))
    # A save makes the folder it needs; what it cannot do is write inside a file.
    $nested = Join-Path $work "made\up\r5.comp"
    Expect-Pass "resave/creates the folder" (Invoke-Cli @("resave", $named, $nested)) "resaved"
    Expect-Pass "resave/creates the folder (reads back)" (Invoke-Cli @("validate", $nested)) "ok: 1 layers, 12x7"
    Expect-Fail "resave/output inside a file" (Invoke-Cli @("resave", $named, (Join-Path $rendered "r6.comp")))

    $backends = Invoke-Cli @("backends")
    Expect-Pass "backends" $backends "cpu: always available"
    Expect-Pass "backends with a project" (Invoke-Cli @("backends", $base)) "this project:"
    Expect-Fail "backends/missing project" (Invoke-Cli @("backends", (Join-Path $work "gone.comp")))

    # ---------------------------------------------------------------- export / import / psd
    $jpeg = Join-Path $work "out.jpg"
    Expect-Pass "export" (Invoke-Cli @("export", $base, "-o", $jpeg)) "exported"
    $magic = [System.IO.File]::ReadAllBytes($jpeg)[0..1]
    Check "export is a JPEG" ($magic[0] -eq 0xFF -and $magic[1] -eq 0xD8) ("first bytes " + ($magic -join " "))
    Expect-Fail "export/quality 0" (Invoke-Cli @("export", $base, "-o", (Join-Path $work "q0.jpg"), "--quality", "0"))
    Expect-Fail "export/quality 250" (Invoke-Cli @("export", $base, "-o", (Join-Path $work "q250.jpg"), "--quality", "250"))
    Expect-Fail "export/missing package" (Invoke-Cli @("export", (Join-Path $work "gone.comp"), "-o", (Join-Path $work "q.jpg")))

    $imported = Join-Path $work "imported.comp"
    Expect-Pass "import" (Invoke-Cli @("import", $rendered, $imported, "--name", "Imported")) "imported"
    Expect-Pass "import/validate" (Invoke-Cli @("validate", $imported)) "ok: 1 layers, 8x8"
    $bigger = Join-Path $work "bigger.comp"
    $null = Invoke-Cli @("import", $rendered, $bigger, "--width", "16", "--height", "20")
    Expect-Pass "import/--width/--height" (Invoke-Cli @("info", $bigger)) "canvas     16 x 20"
    Expect-Fail "import/missing image" (Invoke-Cli @("import", (Join-Path $work "gone.png"), (Join-Path $work "i2.comp")))
    Expect-Fail "import/no package argument" (Invoke-Cli @("import", $rendered))

    $psd = Join-Path $work "oracle.psd"
    $writePsd = "import sys; sys.path.insert(0, sys.argv[2]); import verify_psd as V, psd_oracle as P; n, w, h, layers, kw = V.cases()[0]; P.write_psd(sys.argv[1], w, h, layers, **kw)"
    $null = (& $python -c $writePsd $psd $PSScriptRoot 2>&1 | Out-String)
    if (Test-Path $psd) {
        $psdPkg = Join-Path $work "psd.comp"
        Expect-Pass "psd" (Invoke-Cli @("psd", $psd, $psdPkg)) "read .* \(2 layers, 32x24\)"
        Expect-Pass "psd/validate" (Invoke-Cli @("validate", $psdPkg)) "ok: 2 layers, 32x24"
    }
    else { Check "psd fixture" $false "psd_oracle.py could not write a PSD" }
    Expect-Fail "psd/not a Photoshop file" (Invoke-Cli @("psd", $rendered, (Join-Path $work "notpsd.comp")))
    Expect-Fail "psd/missing file" (Invoke-Cli @("psd", (Join-Path $work "gone.psd"), (Join-Path $work "p2.comp")))

    # ---------------------------------------------------------------- sample / rasterize
    Expect-Pass "sample" (Invoke-Cli @("sample", $samplePkg)) "wrote sample"
    $sampleInfo = Invoke-Cli @("info", $samplePkg)
    Expect-Pass "sample canvas" $sampleInfo "canvas     320 x 200"
    $sampleLayers = Invoke-Cli @("layers", $samplePkg)
    Check "sample has text and shape layers" ($sampleLayers.Output -match "Title \[raster\]" -and $sampleLayers.Output -match "Shape \[raster\]") "Title and Shape present"
    Expect-Pass "sample/creates the folder" (Invoke-Cli @("sample", (Join-Path $work "made\sample.comp"))) "wrote sample"
    Expect-Fail "sample/output inside a file" (Invoke-Cli @("sample", (Join-Path $rendered "s.comp")))

    $rasterized = Join-Path $work "rasterized.comp"
    $raster = Invoke-Cli @("rasterize", $samplePkg, "-o", $rasterized)
    Expect-Pass "rasterize" $raster "rasterized"
    Expect-Pass "rasterize/validate" (Invoke-Cli @("validate", $rasterized)) "ok:"
    $inPlace = Join-Path $work "inplace.comp"
    Copy-Item $samplePkg $inPlace -Recurse
    Expect-Pass "rasterize in place" (Invoke-Cli @("rasterize", $inPlace)) "wrote"
    Expect-Fail "rasterize/nothing to rasterize" (Invoke-Cli @("rasterize", $base))
    Expect-Fail "rasterize/missing package" (Invoke-Cli @("rasterize", (Join-Path $work "gone.comp")))

    # ---------------------------------------------------------------- filters
    $filters = Invoke-Cli @("filters")
    Expect-Pass "filters" $filters "Lens Correction"
    $filterCount = (($filters.Output -split "\r?\n") | Where-Object { $_.Trim() }).Count
    Check "filters lists the whole set" ($filterCount -ge 10) "$filterCount filters"
    $filtered = Join-Path $work "filtered.png"
    $blur = Invoke-Cli @("filter", $rendered, "-o", $filtered, "--kind", "Gaussian Blur")
    Expect-Pass "filter --kind" $blur "filtered"
    Check "filter/keeps the size" ((Read-Png $filtered) -like "8 8 *") (Read-Png $filtered)
    Expect-Fail "filter/unknown kind" (Invoke-Cli @("filter", $rendered, "-o", (Join-Path $work "f2.png"), "--kind", "No Such Filter"))
    Expect-Fail "filter/no --kind" (Invoke-Cli @("filter", $rendered, "-o", (Join-Path $work "f3.png")))
    Expect-Fail "filter/missing input" (Invoke-Cli @("filter", (Join-Path $work "gone.png"), "-o", (Join-Path $work "f4.png"), "--kind", "Gaussian Blur"))
    Expect-Fail "filter/bad settings file" (Invoke-Cli @("filter", $rendered, "-o", (Join-Path $work "f5.png"), "--kind", "Gaussian Blur", "--settings", (Join-Path $work "gone.json")))

    # ---------------------------------------------------------------- raw
    $developed = Join-Path $work "developed.png"
    Expect-Pass "raw on an image" (Invoke-Cli @("raw", $rendered, "-o", $developed)) "developed"
    Check "raw/keeps the size" ((Read-Png $developed) -like "8 8 *") (Read-Png $developed)
    $neutral = Join-Path $work "neutral.json"
    Set-Content $neutral "{}"
    Expect-Pass "raw --settings" (Invoke-Cli @("raw", $rendered, "-o", (Join-Path $work "developed2.png"), "--settings", $neutral)) "developed"
    $unknown = Join-Path $work "unknown.json"
    Set-Content $unknown '{ "exposureBogus": 1 }'
    Expect-Fail "raw/unknown setting" (Invoke-Cli @("raw", $rendered, "-o", (Join-Path $work "developed3.png"), "--settings", $unknown))
    Expect-Fail "raw/missing input" (Invoke-Cli @("raw", (Join-Path $work "gone.dng"), "-o", (Join-Path $work "d4.png")))
    Expect-Fail "raw/not an image" (Invoke-Cli @("raw", $neutral, "-o", (Join-Path $work "d5.png")))

    # ---------------------------------------------------------------- stroke
    # The brush *semantics* are judged against an independent implementation by check_brush.ps1;
    # this is the command's own surface: it paints, it writes a PNG, and it refuses nonsense.
    $stroked = Join-Path $work "stroke.png"
    Expect-Pass "stroke" (Invoke-Cli @("stroke", $stroked, "--width", "48", "--height", "32", "--brush", "16", "--path", "line", "--from", "8,16", "--to", "40,16")) "stroked"
    Check "stroke/paints the middle" ((Read-Png $stroked) -eq "48 32 (0, 0, 0, 255)") (Read-Png $stroked)
    $arcStroke = Join-Path $work "stroke-arc.png"
    Expect-Pass "stroke --path arc" (Invoke-Cli @("stroke", $arcStroke, "--width", "64", "--height", "64", "--brush", "12", "--hardness", "0.5", "--path", "arc", "--center", "32,32", "--radius", "20", "--start-deg", "-40", "--sweep-deg", "300", "--samples", "9")) "stroked"
    Check "stroke/arc keeps the size" ((Read-Png $arcStroke) -like "64 64 *") (Read-Png $arcStroke)
    Expect-Fail "stroke/bad path" (Invoke-Cli @("stroke", (Join-Path $work "s2.png"), "--brush", "16", "--path", "spiral"))
    Expect-Fail "stroke/bad colour" (Invoke-Cli @("stroke", (Join-Path $work "s3.png"), "--brush", "16", "--color", "zz"))
    Expect-Fail "stroke/bad point" (Invoke-Cli @("stroke", (Join-Path $work "s4.png"), "--brush", "16", "--from", "8"))
    Expect-Fail "stroke/no --brush" (Invoke-Cli @("stroke", (Join-Path $work "s5.png")))
    Expect-Fail "stroke/tip of no size" (Invoke-Cli @("stroke", (Join-Path $work "s6.png"), "--brush", "0"))

    # ---------------------------------------------------------------- bench
    $bench = Invoke-Cli @("bench", "--canvas", "400", "--brush", "60", "--samples", "5")
    Expect-Pass "bench" $bench "sample to pixels"
    Expect-Fail "bench/--samples not a number" (Invoke-Cli @("bench", "--samples", "many"))
    Expect-Fail "bench/--canvas not a number" (Invoke-Cli @("bench", "--canvas", "big"))

    # ---------------------------------------------------------------- update
    $release = Join-Path $work "release"
    New-Item -ItemType Directory -Path $release | Out-Null
    Set-Content (Join-Path $release "compc.exe") "binary-one"
    $updateJson = Join-Path $work "update.json"
    Expect-Pass "update describe" (Invoke-Cli @("update", "describe", "--dir", $release, "--version", "9.9.9", "-o", $updateJson)) "wrote"
    Assert-File "update describe writes" $updateJson
    Expect-Pass "update check" (Invoke-Cli @("update", "check", $updateJson, "--current", "0.0.1")) "update available"
    Expect-Pass "update verify" (Invoke-Cli @("update", "verify", $updateJson, "--dir", $release)) "verified"
    Set-Content (Join-Path $release "compc.exe") "binary-ONE"
    Expect-Fail "update verify/tampered" (Invoke-Cli @("update", "verify", $updateJson, "--dir", $release))
    Set-Content (Join-Path $release "compc.exe") "binary-one"
    $installed = Join-Path $work "installed.exe"
    $staged = Join-Path $work "staged.exe"
    Set-Content $installed "old-build"
    Set-Content $staged "new-build"
    Expect-Pass "update apply" (Invoke-Cli @("update", "apply", "--staged", $staged, "--target", $installed)) "applied"
    Check "update apply swapped" ((Get-Content $installed -Raw).Trim() -eq "new-build") "new build in place"
    Expect-Pass "update status" (Invoke-Cli @("update", "status", "--target", $installed)) "parked"
    Expect-Pass "update status --cleanup" (Invoke-Cli @("update", "status", "--target", $installed, "--cleanup")) "removed the parked build"
    Check "update cleanup removed the parked build" (-not (Test-Path ($installed + ".previous"))) "no .previous left"
    $garbage = Join-Path $work "garbage.json"
    Set-Content $garbage "this is not a manifest"
    Expect-Fail "update check/garbage manifest" (Invoke-Cli @("update", "check", $garbage))
    Expect-Fail "update verify/missing manifest" (Invoke-Cli @("update", "verify", (Join-Path $work "gone.json"), "--dir", $release))
    Expect-Fail "update verify/no --dir" (Invoke-Cli @("update", "verify", $updateJson))
    Expect-Fail "update apply/missing staged" (Invoke-Cli @("update", "apply", "--staged", (Join-Path $work "gone.exe"), "--target", $installed))
    Expect-Fail "update describe/no --version" (Invoke-Cli @("update", "describe", "--dir", $release, "-o", (Join-Path $work "u2.json")))
    Expect-Fail "update/unknown action" (Invoke-Cli @("update", "frobnicate"))
    Expect-Fail "update/no action" (Invoke-Cli @("update"))

    # ---------------------------------------------------------------- the argument surface itself
    Expect-Fail "no subcommand" (Invoke-Cli @())
    Expect-Fail "unknown subcommand" (Invoke-Cli @("frobnicate"))
    Expect-Pass "help" (Invoke-Cli @("--help")) "Usage: compc"
    $help = Invoke-Cli @("--help")
    $missing = @()
    $documented = @("info", "layers", "validate", "create", "extract", "render", "resave", "backends", "export", "import", "psd", "sample", "filter", "filters", "bench", "update", "rasterize", "raw", "stroke")
    foreach ($command in $documented) {
        if ($help.Output -notmatch ("(?m)^\s+" + [regex]::Escape($command) + "\b")) { $missing += $command }
    }
    Check "every subcommand is documented" ($missing.Count -eq 0) $(if ($missing.Count) { "missing from --help: " + ($missing -join ", ") } else { "$($documented.Count) subcommands listed" })
}
finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

if ($script:checks -eq 0) { Write-Host "FAIL: nothing was checked" -ForegroundColor Red; exit 1 }
if ($script:failures -gt 0) { Write-Host ("FAIL: {0} of {1} subcommand checks failed" -f $script:failures, $script:checks) -ForegroundColor Red; exit 1 }
Write-Host ("PASS {0} subcommand checks against {1}" -f $script:checks, $Cli) -ForegroundColor Green
