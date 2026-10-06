<#
.SYNOPSIS
Builds, tests and packages Compositor for Windows.

.DESCRIPTION
Runs each crate's test suite, builds release binaries, and stages a portable distribution under
dist/ with a version manifest the updater can poll. Every step reports its own result so a failure
does not hide the rest of the run.

.EXAMPLE
pwsh -File tools/build.ps1
pwsh -File tools/build.ps1 -SkipTests
#>
[CmdletBinding()]
param(
    [switch]$SkipTests,
    [switch]$SkipPackage,
    [string]$Configuration = "release"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$crates = @("comp-core", "comp-render", "comp-io", "comp-brush", "comp-cli", "comp-gui")
$failures = @()

Push-Location $root
try {
    if (-not $SkipTests) {
        foreach ($crate in $crates) {
            Write-Host "==> cargo test -p $crate" -ForegroundColor Cyan
            cargo test -p $crate --quiet
            if ($LASTEXITCODE -ne 0) { $failures += $crate }
        }
        if ($failures.Count -gt 0) {
            throw "tests failed for: $($failures -join ', ')"
        }
    }

    Write-Host "==> cargo build --$Configuration" -ForegroundColor Cyan
    cargo build --$Configuration -p comp-cli -p comp-gui
    if ($LASTEXITCODE -ne 0) { throw "release build failed" }

    if (-not $SkipPackage) {
        $profile = if ($Configuration -eq "release") { "release" } else { "debug" }
        $version = (Select-String -Path "Cargo.toml" -Pattern '^version = "(.+)"' | Select-Object -First 1).Matches.Groups[1].Value
        if (-not $version) { $version = "0.1.0" }
        $stage = Join-Path $root "dist\compositor-$version-win-x64"
        if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
        New-Item -ItemType Directory -Path $stage -Force | Out-Null

        Copy-Item (Join-Path $root "target\$profile\compc.exe") $stage
        $gui = Join-Path $root "target\$profile\compositor.exe"
        if (-not (Test-Path $gui)) { $gui = Join-Path $root "target\$profile\comp-gui.exe" }
        if (Test-Path $gui) { Copy-Item $gui $stage } else { Write-Warning "GUI binary not found; packaging the CLI only" }
        Copy-Item (Join-Path $root "README.md") $stage
        Copy-Item (Join-Path $root "LICENSE") $stage -ErrorAction SilentlyContinue

        # The CLI hashes the payload: one implementation of the manifest format, so the updater and
        # the build can never disagree about what a release contains.
        $stagedCompc = Join-Path $stage "compc.exe"
        if (Test-Path $stagedCompc) {
            & $stagedCompc update describe --dir $stage --version $version --channel portable -o (Join-Path $stage "update.json")
            if ($LASTEXITCODE -ne 0) { throw "writing update.json failed" }
        }
        else {
            Write-Warning "compc.exe was not staged; update.json was not written"
        }

        $zip = "$stage.zip"
        if (Test-Path $zip) { Remove-Item -Force $zip }
        Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zip
        Write-Host "packaged $zip" -ForegroundColor Green
    }
}
finally {
    Pop-Location
}
