<#
.SYNOPSIS
Runs the full acceptance pass for the Windows port.

.DESCRIPTION
1. cargo test for every crate, with a dedicated target directory so it never fights an editor build.
2. Builds compc and renders every .comp fixture.
3. Compares each render against the independent Python oracle, pixel by pixel.
4. Checks that the Rust writer reproduces Python-written manifests field for field.

Prints one summary table and exits non-zero if any step failed.
#>
[CmdletBinding()]
param(
    [int]$Tolerance = 1,
    [switch]$SkipCargo
)

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
# Tie the run to a revision: an acceptance result without one cannot be reproduced.
$revision = "no repository"
Push-Location $root
try {
    if (Test-Path (Join-Path $root ".git")) {
        $commit = (git rev-parse --short HEAD 2>&1 | Out-String).Trim()
        $dirty = (git status --porcelain 2>&1 | Out-String).Trim()
        $revision = if ($dirty) { "$commit with uncommitted changes" } else { $commit }
    }
}
finally { Pop-Location }
Write-Host "acceptance run against revision: $revision" -ForegroundColor Cyan
$target = Join-Path $root "target-lead"
$env:CARGO_TARGET_DIR = $target
$python = "C:\\Users\\leoevan\\.dsh\\dsh-runtimes\\dsh-primary-runtime\\dependencies\\python\\python.exe"
$newline = [string][char]10

$results = [ordered]@{}

function Record($name, $ok, $detail) {
    $script:results[$name] = [pscustomobject]@{ Ok = $ok; Detail = $detail }
    $colour = if ($ok) { "Green" } else { "Red" }
    $state = if ($ok) { "PASS" } else { "FAIL" }
    Write-Host ("{0,-30} {1}  {2}" -f $name, $state, $detail) -ForegroundColor $colour
}

Push-Location $root
try {
    if (-not $SkipCargo) {
        foreach ($crate in @("comp-core", "comp-render", "comp-io", "comp-brush", "comp-cli", "comp-text", "comp-raw", "comp-release", "comp-gui")) {
            $output = (cargo test -p $crate 2>&1 | Out-String)
            $passed = ([regex]::Matches($output, "test result: ok\. (\d+) passed") | ForEach-Object { [int]$_.Groups[1].Value } | Measure-Object -Sum).Sum
            $failed = ([regex]::Matches($output, "test result: FAILED") | Measure-Object).Count
            if (-not $passed) { $passed = 0 }
            # A crate that fails to compile reports no test results at all, which must never read as a pass.
            $compiled = ($output -notmatch "could not compile") -and ($output -notmatch "error\[E\d+\]")
            $ok = $compiled -and $failed -eq 0 -and $passed -gt 0
            $detail = if (-not $compiled) { "did not compile" } else { "$passed tests passed, $failed suites failed" }
            Record "cargo test -p $crate" $ok $detail
        }
    }

    $null = (cargo build -p comp-cli 2>&1 | Out-String)
    $cli = Join-Path $target "debug\\compc.exe"
    Record "build compc" (Test-Path $cli) $cli

    if (Test-Path $cli) {
        $roundTrip = (& $python (Join-Path $PSScriptRoot "manifest_roundtrip.py") $cli 2>&1 | Out-String)
        $summary = (($roundTrip -split "\r?\n") | Where-Object { $_ -match "manifests reproduced" }) -join " "
        Record "manifest fidelity" ($LASTEXITCODE -eq 0) $summary.Trim()

        $release = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot "check_release.ps1") -Cli $cli 2>&1 | Out-String)
        $releaseFails = (($release -split "\r?\n") | Where-Object { $_ -match "^FAIL" }).Count
        Record "release tooling" ($LASTEXITCODE -eq 0 -and $releaseFails -eq 0) "$((($release -split "\r?\n") | Where-Object { $_ -match "^PASS" }).Count) checks passed"

        $perf = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot "check_perf.ps1") 2>&1 | Out-String)
        $perfLine = (($perf -split "\r?\n") | Where-Object { $_ -match "^best of" }) -join " "
        Record "interaction budget" ($LASTEXITCODE -eq 0) $perfLine.Trim()
        if ($LASTEXITCODE -ne 0) { ($perf -split "\r?\n") | Select-Object -Last 4 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow } }

        $regions = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot "check_regions.ps1") -Cli $cli 2>&1 | Out-String)
        $regionFails = (($regions -split "\r?\n") | Where-Object { $_ -match "^FAIL" }).Count
        $regionLine = (($regions -split "\r?\n") | Where-Object { $_ -match "^PASS" }) -join " "
        Record "region rendering" ($LASTEXITCODE -eq 0 -and $regionFails -eq 0) $regionLine.Trim()
        foreach ($line in (($regions -split "\r?\n") | Where-Object { $_ -match "^FAIL" })) { Write-Host "    $line" -ForegroundColor DarkYellow }

        $python = "C:\Users\leoevan\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
        $fuzz = (& $python (Join-Path $PSScriptRoot "fuzz_differential.py") --cli $cli --count 40 --seed 20250101 --roundtrip 2>&1 | Out-String)
        $fuzzLine = (($fuzz -split "\r?\n") | Where-Object { $_ -match "^(PASS|FAIL) \d" }) -join " "
        Record "random differential" ($LASTEXITCODE -eq 0) $fuzzLine.Trim()
        if ($LASTEXITCODE -ne 0) { ($fuzz -split "\r?\n") | Where-Object { $_ -match "^FAIL" } | Select-Object -First 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow } }

        $meta = (& $python (Join-Path $PSScriptRoot "verify_checks.py") --quick --cli $cli 2>&1 | Out-String)
        $metaLine = (($meta -split "\r?\n") | Where-Object { $_ -match "^\d+ checks exercised" }) -join " "
        Record "checks catch sabotage" ($LASTEXITCODE -eq 0) $metaLine.Trim()
        if ($LASTEXITCODE -ne 0) { ($meta -split "\r?\n") | Where-Object { $_ -match "^FAIL" } | Select-Object -First 4 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow } }

        $codecs = (& $python (Join-Path $PSScriptRoot "verify_codecs.py") --cli $cli 2>&1 | Out-String)
        $codecNotes = (($codecs -split "\r?\n") | Where-Object { $_ -match "^note" }) -join " | "
        $codecLine = (($codecs -split "\r?\n") | Where-Object { $_ -match "^\d+ codec" }) -join " "
        if ($codecNotes) { $codecLine = $codecLine + " (gaps: " + $codecNotes + ")" }
        Record "png/jpeg codecs" ($LASTEXITCODE -eq 0) $codecLine.Trim()
        if ($LASTEXITCODE -ne 0) { ($codecs -split "\r?\n") | Where-Object { $_ -match "^FAIL" } | Select-Object -First 4 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow } }

        $psd = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot "check_psd.ps1") -Cli $cli 2>&1 | Out-String)
        $psdLine = (($psd -split "\r?\n") | Where-Object { $_ -match "^(PASS|FAIL) \d+ PSD" }) -join " "
        Record "psd import" ($LASTEXITCODE -eq 0) $psdLine.Trim()
        if ($LASTEXITCODE -ne 0) { ($psd -split "\r?\n") | Where-Object { $_ -match "^    FAIL" } | Select-Object -First 4 | ForEach-Object { Write-Host "$_" -ForegroundColor DarkYellow } }

        $hostile = (& $python (Join-Path $PSScriptRoot "fuzz_hostile.py") --cli $cli --per-fixture 2 2>&1 | Out-String)
        $hostileLine = (($hostile -split "\r?\n") | Where-Object { $_ -match "damaged packages fed" }) -join " "
        Record "damaged packages" ($LASTEXITCODE -eq 0) $hostileLine.Trim()
        if ($LASTEXITCODE -ne 0) { ($hostile -split "\r?\n") | Where-Object { $_ -match "^FAIL" } | Select-Object -First 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow } }

        $versions = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot "check_versions.ps1") -Cli $cli 2>&1 | Out-String)
        $versionFails = (($versions -split "\r?\n") | Where-Object { $_ -match "^FAIL" }).Count
        $versionLine = (($versions -split "\r?\n") | Where-Object { $_ -match "^PASS " }) -join " "
        Record "format versions 1-11" ($LASTEXITCODE -eq 0 -and $versionFails -eq 0) $versionLine.Trim()
        foreach ($line in (($versions -split "\r?\n") | Where-Object { $_ -match "^FAIL" })) { Write-Host "    $line" -ForegroundColor DarkYellow }

        $entry = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot "check_entrypoints.ps1") -Cli $cli 2>&1 | Out-String)
        $entryFails = (($entry -split "\r?\n") | Where-Object { $_ -match "^FAIL" }).Count
        $entryLine = (($entry -split "\r?\n") | Where-Object { $_ -match "^PASS the editor" }) -join " "
        if (-not $entryLine) { $entryLine = (($entry -split "\r?\n") | Where-Object { $_ -match "." } | Select-Object -Last 1) }
        Record "editor vs cli" ($LASTEXITCODE -eq 0 -and $entryFails -eq 0) $entryLine.Trim()
        foreach ($line in (($entry -split "\r?\n") | Where-Object { $_ -match "^FAIL" })) { Write-Host "    $line" -ForegroundColor DarkYellow }

        $gpu = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot "check_gpu.ps1") -Cli $cli 2>&1 | Out-String)
        $gpuFails = (($gpu -split "\r?\n") | Where-Object { $_ -match "^FAIL" }).Count
        $gpuLine = (($gpu -split "\r?\n") | Where-Object { $_ -match "^(PASS gpu|SKIP|compared)" }) -join " "
        Record "gpu compositing" ($LASTEXITCODE -eq 0 -and $gpuFails -eq 0) $gpuLine.Trim()
        foreach ($line in (($gpu -split "\r?\n") | Where-Object { $_ -match "^FAIL" })) { Write-Host "    $line" -ForegroundColor DarkYellow }

        $filters = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot "check_filters.ps1") -Cli $cli 2>&1 | Out-String)
        $filterFails = (($filters -split "\r?\n") | Where-Object { $_ -match "^FAIL" }).Count
        Record "filter kernels" ($LASTEXITCODE -eq 0 -and $filterFails -eq 0) "$((($filters -split "\r?\n") | Where-Object { $_ -match "^PASS" }).Count) checks passed"

        $surface = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot "check_cli.ps1") -Cli $cli 2>&1 | Out-String)
        $surfaceFails = (($surface -split "\r?\n") | Where-Object { $_ -match "^FAIL" }).Count
        $surfaceLine = (($surface -split "\r?\n") | Where-Object { $_ -match "^PASS \d+ subcommand" }) -join " "
        Record "cli subcommands" ($LASTEXITCODE -eq 0 -and $surfaceFails -eq 0) $surfaceLine.Trim()
        foreach ($line in (($surface -split "\r?\n") | Where-Object { $_ -match "^FAIL" })) { Write-Host "    $line" -ForegroundColor DarkYellow }

        $brush = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot "check_brush.ps1") -Cli $cli 2>&1 | Out-String)
        $brushFails = (($brush -split "\r?\n") | Where-Object { $_ -match "^FAIL" }).Count
        $brushLine = (($brush -split "\r?\n") | Where-Object { $_ -match "^PASS brush" }) -join " "
        Record "brush vs oracle" ($LASTEXITCODE -eq 0 -and $brushFails -eq 0) $brushLine.Trim()
        foreach ($line in (($brush -split "\r?\n") | Where-Object { $_ -match "^FAIL" })) { Write-Host "    $line" -ForegroundColor DarkYellow }

        $packages = @(Get-ChildItem (Join-Path $PSScriptRoot "fixtures\\*.comp") -Directory | ForEach-Object { $_.FullName })
        $packages += (Join-Path $PSScriptRoot "..\\..\\dist\\sample.comp")
        $interop = (& $python (Join-Path $PSScriptRoot "macos_interop.py") @packages 2>&1 | Out-String)
        $summary = (($interop -split "\r?\n") | Where-Object { $_ -match "would load in the macOS app" }) -join " "
        $rejected = (($interop -split "\r?\n") | Where-Object { $_ -match "^REJECT" })
        Record "macOS interop" ($LASTEXITCODE -eq 0 -and $rejected.Count -eq 0) $summary.Trim()
        foreach ($line in $rejected) { Write-Host "    $line" -ForegroundColor DarkYellow }

        $acceptance = (& $python (Join-Path $PSScriptRoot "acceptance.py") $cli --tolerance $Tolerance 2>&1 | Out-String)
        $summary = (($acceptance -split "\r?\n") | Where-Object { $_ -match "fixtures matched" }) -join " "
        Record "pixel acceptance" ($LASTEXITCODE -eq 0) $summary.Trim()
        if ($acceptance -notmatch "fixtures matched") {
            ($acceptance -split "\r?\n" | Select-Object -Last 10) | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow }
        }
    }
    else {
        Record "manifest fidelity" $false "compc.exe not found"
        Record "pixel acceptance" $false "compc.exe not found"
    }
}
finally {
    Pop-Location
}

Write-Host ""
$failed = ($results.Values | Where-Object { -not $_.Ok }).Count
$state = if ($failed) { "Red" } else { "Green" }
Write-Host ("acceptance: {0} of {1} checks passed" -f ($results.Count - $failed), $results.Count) -ForegroundColor $state
exit $(if ($failed) { 1 } else { 0 })
