# Renders every fixture and compares it against the oracle's own pixels.
# Usage:  pwsh -File compositor_win\tools\verify\oracle\run_oracle.ps1 [-Compc PATH]
param(
    [string]$Compc = ""
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$python = "C:\Users\leoevan\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
Push-Location $here
try {
    if ($Compc -ne "") {
        & $python make_fixtures.py
        & $python run_oracle.py --compc $Compc
    } else {
        & $python make_fixtures.py
        & $python run_oracle.py
    }
} finally {
    Pop-Location
}
