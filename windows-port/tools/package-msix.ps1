<#
.SYNOPSIS
Builds an MSIX package for Compositor for Windows, and optionally signs it.

.DESCRIPTION
MSIX is the Windows counterpart of the macOS app's signed, notarized DMG: one file, a declared
identity, and a signature Windows checks before installing. This script stages the release layout,
packs it with the Windows SDK's makeappx, and can sign it with a self-signed certificate.

A self-signed certificate is enough to install on a machine that trusts it, and enough for how this
build is handed out: development and internal distribution. Nothing here needs a purchased certificate,
and this build is not going to the Store. The -CertificatePath and -CertificatePassword parameters exist
for a future release that does need one; leave them off and the script signs with the self-signed
certificate it keeps in the current user's store, exporting a .cer beside the package to trust.

.EXAMPLE
pwsh -File tools/package-msix.ps1
pwsh -File tools/package-msix.ps1 -Sign
pwsh -File tools/package-msix.ps1 -Sign -CertificatePath my.pfx -CertificatePassword secret
#>
[CmdletBinding()]
param(
    [string]$Version,
    [string]$Configuration = "release",
    [switch]$Sign,
    [string]$CertificatePath,
    [string]$CertificatePassword,
    [string]$Subject = "CN=Compositor Dev"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$msixDir = Join-Path $root "tools\msix"

function Find-SdkTool([string]$name) {
    $kits = "C:\Program Files (x86)\Windows Kits\10\bin"
    if (-not (Test-Path $kits)) { return $null }
    $candidates = Get-ChildItem $kits -Directory | Sort-Object Name -Descending | ForEach-Object {
        Join-Path $_.FullName ("x64\" + $name)
    }
    foreach ($candidate in $candidates) { if (Test-Path $candidate) { return $candidate } }
    return $null
}

$makeappx = Find-SdkTool "makeappx.exe"
$signtool = Find-SdkTool "signtool.exe"
if (-not $makeappx) { throw "makeappx.exe was not found. Install the Windows SDK (Windows App Certification Kit)." }

if (-not $Version) {
    $Version = (Select-String -Path (Join-Path $root "Cargo.toml") -Pattern '^version = "(.+)"' | Select-Object -First 1).Matches.Groups[1].Value
    if (-not $Version) { $Version = "0.1.0" }
}
# MSIX versions have four parts.
$packageVersion = $Version
while (($packageVersion -split "\.").Count -lt 4) { $packageVersion = $packageVersion + ".0" }

Write-Host "==> building $Configuration binaries" -ForegroundColor Cyan
Push-Location $root
try {
    cargo build --$Configuration -p comp-cli -p comp-gui
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }
}
finally { Pop-Location }

$layout = Join-Path $root "dist\msix-layout"
if (Test-Path $layout) { Remove-Item -Recurse -Force $layout }
New-Item -ItemType Directory -Path (Join-Path $layout "Assets") -Force | Out-Null

$profile = if ($Configuration -eq "release") { "release" } else { "debug" }
$gui = Join-Path $root "target\$profile\comp-gui.exe"
if (-not (Test-Path $gui)) { $gui = Join-Path $root "target\$profile\compositor.exe" }
if (-not (Test-Path $gui)) { throw "the editor binary was not built" }
Copy-Item $gui (Join-Path $layout "comp-gui.exe")
Copy-Item (Join-Path $root "target\$profile\compc.exe") $layout
Copy-Item (Join-Path $root "README.md") $layout -ErrorAction SilentlyContinue
Copy-Item (Join-Path $root "LICENSE") $layout -ErrorAction SilentlyContinue

Write-Host "==> assets" -ForegroundColor Cyan
$python = "C:\Users\leoevan\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
if (Test-Path $python) { & $python (Join-Path $msixDir "make-assets.py") (Join-Path $layout "Assets") | Out-Null }
else { throw "the bundled Python was not found; run make-assets.py yourself" }

Write-Host "==> manifest" -ForegroundColor Cyan
$manifest = Get-Content (Join-Path $msixDir "AppxManifest.xml") -Raw
$manifest = $manifest.Replace('Version="0.1.0.0"', 'Version="' + $packageVersion + '"')
$manifest = $manifest.Replace('Publisher="CN=Compositor Dev"', 'Publisher="' + $Subject + '"')
Set-Content -Path (Join-Path $layout "AppxManifest.xml") -Value $manifest -Encoding UTF8

$msix = Join-Path $root ("dist\compositor-" + $Version + "-win-x64.msix")
if (Test-Path $msix) { Remove-Item -Force $msix }
Write-Host "==> packing" -ForegroundColor Cyan
& $makeappx pack /d $layout /p $msix /o
if ($LASTEXITCODE -ne 0) { throw "makeappx pack failed" }
Write-Host ("packaged {0} ({1:N1} MB)" -f $msix, ((Get-Item $msix).Length / 1MB)) -ForegroundColor Green

if ($Sign) {
    if (-not $signtool) { throw "signtool.exe was not found; install the Windows SDK" }
    $signArgs = @("sign", "/fd", "SHA256", "/debug")
    if ($CertificatePath) {
        $signArgs += @("/f", $CertificatePath)
        if ($CertificatePassword) { $signArgs += @("/p", $CertificatePassword) }
    }
    else {
        Write-Host "==> self-signed certificate for $Subject" -ForegroundColor Cyan
        $existing = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq $Subject -and $_.HasPrivateKey } | Select-Object -First 1
        if (-not $existing) {
            $existing = New-SelfSignedCertificate -Type Custom -Subject $Subject `
                -KeyUsage DigitalSignature -FriendlyName "Compositor package signing" `
                -CertStoreLocation "Cert:\CurrentUser\My" `
                -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3", "2.5.29.19={text}")
        }
        $cer = Join-Path $root ("dist\compositor-selfsigned.cer")
        Export-Certificate -Cert $existing -FilePath $cer -Force | Out-Null
        Write-Host "exported $cer (trust it to install this package)" -ForegroundColor DarkYellow
        $signArgs += @("/sha1", $existing.Thumbprint)
    }
    $signArgs += @($msix)
    & $signtool @signArgs
    if ($LASTEXITCODE -ne 0) { throw "signtool sign failed" }
    Write-Host "==> verifying the signature" -ForegroundColor Cyan
    & $signtool verify /pa /v $msix
    if ($LASTEXITCODE -ne 0) {
        Write-Host "the signature is present but the chain is not trusted on this machine; trust the exported .cer to install" -ForegroundColor DarkYellow
    }
}

Write-Host ""
Write-Host "package: $msix" -ForegroundColor Green
Write-Host ('install with: Add-AppxPackage "' + $msix + '"') -ForegroundColor DarkYellow
