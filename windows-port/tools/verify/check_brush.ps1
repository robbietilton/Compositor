<#
.SYNOPSIS
Checks the brush against an independent implementation of its model.

.DESCRIPTION
Every other brush check compares the engine with itself: an incremental stroke against a batch one,
the same pixels from two call shapes. This one paints a stroke with compc and recomputes it in
NumPy from the model in tools/verify/brush_oracle.py, so the tip shape, the density integral along a
swept segment, the profile and coverage tables and the source-over compositing are all judged by
something that was not written from the Rust code.

The cases cover both tip kinds (the swept silhouette of a hard tip, the integrated density of a soft
one) over the two paths the model can describe without a mouse (a straight line and a circular arc),
plus the shapes where a mistake would hide: sparse spacing, low flow, low opacity, a click that never
moved, a 1 px tip, a tip wider than the canvas, a path that crosses itself, and paint and canvas that
are not opaque, which is where source-over stops being a lerp.

Tolerance is one level per channel: the two implementations round the same arithmetic, so anything
larger is a difference in the model, not in the last bit. The tolerance is not to be raised to make a
case pass; a case that failed at 2 is a finding.

Exit code 1 when a case differs or a command misbehaves, 2 when compc or python is missing.
#>
[CmdletBinding()]
param([string]$Cli, [int]$Tolerance = 1)

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Cli) { $Cli = Join-Path $root "target-lead\debug\compc.exe" }
if (-not (Test-Path $Cli)) { Write-Host "compc not found: $Cli"; exit 2 }
$python = "C:\Users\leoevan\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
if (-not (Test-Path $python)) { Write-Host "python not found: $python"; exit 2 }
$oracle = Join-Path $PSScriptRoot "brush_oracle.py"
if (-not (Test-Path $oracle)) { Write-Host "the oracle is missing: $oracle"; exit 2 }

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("compbrush-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null
$script:checks = 0
$script:failures = 0
function Check($name, $ok, $detail) {
    $script:checks++
    if ($ok) { Write-Host ("PASS {0,-22} {1}" -f $name, $detail) -ForegroundColor Green }
    else { Write-Host ("FAIL {0,-22} {1}" -f $name, $detail) -ForegroundColor Red; $script:failures++ }
}

function Compare-Png($cli, $oracle, $tolerance) {
    $script = "import sys, numpy as np" + [char]10 +
        "from PIL import Image" + [char]10 +
        "a = np.asarray(Image.open(sys.argv[1]).convert('RGBA'), dtype=np.int64)" + [char]10 +
        "b = np.asarray(Image.open(sys.argv[2]).convert('RGBA'), dtype=np.int64)" + [char]10 +
        "d = np.abs(a - b)" + [char]10 +
        "print(int(d.max()), round(float(d.mean()), 5), int((d.max(axis=2) > 0).sum()), int((np.abs(a - a[0, 0]).max(axis=2) > 0).sum()))"
    $report = (& $python -c $script $cli $oracle | Out-String).Trim()
    $parts = $report -split "\s+"
    if ($parts.Count -lt 4) { return @{ Worst = -1; Mean = -1; Differing = -1; Painted = -1; Error = $report } }
    return @{ Worst = [int]$parts[0]; Mean = [double]$parts[1]; Differing = [int]$parts[2]; Painted = [int]$parts[3]; Error = "" }
}

try {
    # One entry per case: a label and the flags both implementations take.
    $cases = @(
        @{ Name = "hard line"; Args = @("--width","128","--height","64","--brush","24","--hardness","1","--path","line","--from","16,32","--to","112,32") },
        @{ Name = "soft line"; Args = @("--width","128","--height","64","--brush","30","--hardness","0.6","--path","line","--from","16,32","--to","112,32") },
        @{ Name = "hard arc"; Args = @("--width","128","--height","128","--brush","20","--hardness","1","--path","arc","--center","64,64","--radius","40","--start-deg","0","--sweep-deg","270","--samples","8") },
        @{ Name = "soft arc"; Args = @("--width","128","--height","128","--brush","26","--hardness","0.25","--flow","0.6","--path","arc","--center","64,64","--radius","34","--start-deg","-40","--sweep-deg","300","--samples","12") },
        @{ Name = "sparse spacing"; Args = @("--width","128","--height","64","--brush","18","--hardness","1","--spacing","0.6","--path","line","--from","12,32","--to","116,32","--samples","3") },
        @{ Name = "low flow"; Args = @("--width","96","--height","96","--brush","22","--hardness","0.9","--flow","0.2","--path","line","--from","16,48","--to","80,48") },
        @{ Name = "low opacity"; Args = @("--width","96","--height","96","--brush","28","--hardness","0.8","--opacity","0.35","--path","line","--from","16,32","--to","80,64") },
        @{ Name = "a click"; Args = @("--width","64","--height","64","--brush","20","--hardness","0.5","--path","line","--samples","1","--from","32,32") },
        @{ Name = "a one pixel tip"; Args = @("--width","64","--height","32","--brush","1","--hardness","1","--path","line","--from","8,16","--to","56,16") },
        @{ Name = "a two pixel soft tip"; Args = @("--width","64","--height","32","--brush","2","--hardness","0.1","--path","line","--from","8,16","--to","56,16") },
        # The --flag=value form, because both parsers would otherwise read "-10,32" as an option.
        @{ Name = "a tip off the edge"; Args = @("--width","64","--height","64","--brush","40","--hardness","0.7","--path","line","--from=-10,32","--to=74,32") },
        @{ Name = "a crossing path"; Args = @("--width","96","--height","96","--brush","16","--hardness","0.9","--opacity","0.5","--path","arc","--center","48,48","--radius","30","--start-deg","0","--sweep-deg","420","--samples","10") },
        @{ Name = "translucent paint"; Args = @("--width","96","--height","64","--brush","26","--hardness","0.5","--color","20602080","--background","103050ff","--path","line","--from","12,32","--to","84,32") },
        @{ Name = "a translucent canvas"; Args = @("--width","96","--height","64","--brush","26","--hardness","0.5","--color","e0e0e080","--background","00000000","--path","line","--from","12,32","--to","84,32") },
        @{ Name = "a wide soft tip"; Args = @("--width","96","--height","96","--brush","80","--hardness","0.15","--flow","0.8","--path","line","--from","48,20","--to","48,76","--samples","4") }
    )

    foreach ($case in $cases) {
        $name = $case.Name
        $from_cli = Join-Path $work ($name.Replace(" ", "-") + "-cli.png")
        $from_oracle = Join-Path $work ($name.Replace(" ", "-") + "-oracle.png")
        & $Cli stroke $from_cli @($case.Args) 2>&1 | Out-Null
        $cliCode = $LASTEXITCODE
        & $python $oracle --output $from_oracle @($case.Args) 2>&1 | Out-Null
        $oracleCode = $LASTEXITCODE
        if ($cliCode -ne 0 -or -not (Test-Path $from_cli)) {
            Check $name $false "compc stroke failed (exit $cliCode)"
            continue
        }
        if ($oracleCode -ne 0 -or -not (Test-Path $from_oracle)) {
            Check $name $false "the oracle failed (exit $oracleCode)"
            continue
        }
        $report = Compare-Png $from_cli $from_oracle $Tolerance
        if ($report.Error) { Check $name $false "comparison failed: $($report.Error)"; continue }
        # A blank image would pass a tolerance test, so the case has to have painted something.
        if ($report.Painted -lt 20) { Check $name $false "only $($report.Painted) pixels were painted"; continue }
        $ok = $report.Worst -le $Tolerance
        $detail = "worst $($report.Worst), mean $($report.Mean), $($report.Differing) of $($report.Painted) painted pixels differ"
        Check $name $ok $detail
    }

    # The command has to refuse nonsense as well as paint; check_cli.ps1 owns the argument surface.
    & $Cli stroke (Join-Path $work "bad.png") --brush 20 --path spiral 2>&1 | Out-Null
    Check "a path that is not one" ($LASTEXITCODE -ne 0) "exit $LASTEXITCODE"
    & $Cli stroke (Join-Path $work "bad2.png") --brush 20 --color zz 2>&1 | Out-Null
    Check "a colour that is not one" ($LASTEXITCODE -ne 0) "exit $LASTEXITCODE"
    & $Cli stroke (Join-Path $work "bad3.png") --brush 0 2>&1 | Out-Null
    Check "a tip of no size" ($LASTEXITCODE -ne 0) "exit $LASTEXITCODE"
    & $Cli stroke (Join-Path $work "bad4.png") --brush 20 --path arc --radius -4 2>&1 | Out-Null
    Check "an arc of no radius" ($LASTEXITCODE -ne 0) "exit $LASTEXITCODE"
}
finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

if ($script:checks -eq 0) { Write-Host "FAIL: nothing was compared" -ForegroundColor Red; exit 1 }
if ($script:failures -gt 0) { Write-Host ("FAIL: {0} of {1} brush checks failed" -f $script:failures, $script:checks) -ForegroundColor Red; exit 1 }
Write-Host ("PASS brush model verified against the NumPy oracle: {0} cases within {1} level(s)" -f $script:checks, $Tolerance) -ForegroundColor Green
