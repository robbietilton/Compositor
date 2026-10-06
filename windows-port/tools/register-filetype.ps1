<#
.SYNOPSIS
Associates .comp projects with the editor for the current user.

.DESCRIPTION
The macOS app registers a document type, so a project opens with a double click and shows its own
icon. Windows does the same through the registry, and doing it under HKCU means no administrator
rights and no machine-wide side effects.

A .comp package is a directory, which Explorer treats as a folder, so Windows cannot hand it to an
application the way it hands over a file. The script therefore registers the type and its icon, and
the editor accepts a package path on its command line and through drag and drop.

The script is idempotent and can be undone with -Unregister.

.EXAMPLE
pwsh -File tools/register-filetype.ps1
pwsh -File tools/register-filetype.ps1 -Unregister
#>
[CmdletBinding()]
param(
    [string]$ExePath,
    [switch]$Unregister
)

$ErrorActionPreference = "Stop"
$progId = "Compositor.Project"
$extension = ".comp"

if ($Unregister) {
    Remove-Item -Path "HKCU:\Software\Classes\$extension" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Classes\$progId" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "removed the .comp association" -ForegroundColor Green
    return
}

if (-not $ExePath) {
    $repo = Split-Path -Parent $PSScriptRoot
    foreach ($candidate in @("target\release\comp-gui.exe", "target\release\compositor.exe", "target\debug\comp-gui.exe")) {
        $path = Join-Path $repo $candidate
        if (Test-Path $path) { $ExePath = $path; break }
    }
}
if (-not $ExePath -or -not (Test-Path $ExePath)) {
    throw "The editor executable was not found; build it first (cargo build --release -p comp-gui) or pass -ExePath."
}
$ExePath = (Resolve-Path $ExePath).Path
$quoted = [char]34 + $ExePath + [char]34
$openCommand = $quoted + " " + [char]34 + "%1" + [char]34

New-Item -Path "HKCU:\Software\Classes\$progId" -Force | Out-Null
New-Item -Path "HKCU:\Software\Classes\$progId\DefaultIcon" -Force | Out-Null
New-Item -Path "HKCU:\Software\Classes\$progId\shell\open\command" -Force | Out-Null
Set-ItemProperty -Path "HKCU:\Software\Classes\$progId" -Name "(Default)" -Value "Compositor Project"
Set-ItemProperty -Path "HKCU:\Software\Classes\$progId\DefaultIcon" -Name "(Default)" -Value ($ExePath + ",0")
Set-ItemProperty -Path "HKCU:\Software\Classes\$progId\shell\open\command" -Name "(Default)" -Value $openCommand

New-Item -Path "HKCU:\Software\Classes\$extension" -Force | Out-Null
Set-ItemProperty -Path "HKCU:\Software\Classes\$extension" -Name "(Default)" -Value $progId
Set-ItemProperty -Path "HKCU:\Software\Classes\$extension" -Name "PerceivedType" -Value "document"

Write-Host "registered $extension -> $ExePath" -ForegroundColor Green
Write-Host "Open a project with: comp-gui.exe <path to .comp>" -ForegroundColor DarkYellow
