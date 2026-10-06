<#
.SYNOPSIS
    Runs the Compositor for Windows editor.

.DESCRIPTION
    Builds and starts comp-gui from the workspace root with its own target directory, so it never
    blocks another agent or developer building the same workspace.

.PARAMETER Test
    Smoke test: start the editor, paint 40 frames and exit. Useful before a commit and in CI.

.PARAMETER Arguments
    Anything else is passed to comp-gui, for example a .comp package folder.

.EXAMPLE
    .\tools\run-gui.ps1
    .\tools\run-gui.ps1 tools\verify\fixtures\demo.comp
    .\tools\run-gui.ps1 -Test
#>
[CmdletBinding()]
param(
    [switch]$Test,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments = @()
)

$ErrorActionPreference = "Stop"
$workspace = Split-Path -Parent $PSScriptRoot
$env:CARGO_TARGET_DIR = Join-Path $workspace "target-gui-shell"
if ($Test) {
    $env:COMP_GUI_EXIT_AFTER_FRAMES = "40"
}

Push-Location $workspace
try {
    if ($Arguments.Count -gt 0) {
        & cargo run -q -p comp-gui -- @Arguments
    } else {
        & cargo run -q -p comp-gui
    }
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
