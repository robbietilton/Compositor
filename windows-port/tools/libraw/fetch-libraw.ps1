<#
.SYNOPSIS
    Downloads the exact LibRaw and libjpeg-turbo source tarballs this port builds against.

.DESCRIPTION
    Every tarball is verified against the SHA256 recorded in this file before it is unpacked, so the
    build is reproducible and an unexpected upstream change cannot slip in silently. Sources and build
    products land under target-raw-pipeline/libraw/, which is a build directory: nothing here belongs
    in git.

    LibRaw needs libjpeg for one specific job: DNG files whose sensor data is stored as lossy JPEG
    (compression 34892) cannot be unpacked without it. libjpeg-turbo is BSD-3-Clause and IJG licensed,
    so it adds no copyleft obligation of its own.

.EXAMPLE
    pwsh -File tools/libraw/fetch-libraw.ps1
#>
[CmdletBinding()]
param(
    [string]$Destination = "",
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$LibRawVersion = "0.21.4"
$LibRawUrl = "https://www.libraw.org/data/LibRaw-$LibRawVersion.tar.gz"
$LibRawSha256 = "6BE43F19397E43214FF56AAB056BF3FF4925CA14012CE5A1538A172406A09E63"

$JpegVersion = "3.1.2"
$JpegUrl = "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$JpegVersion/libjpeg-turbo-$JpegVersion.tar.gz"
$JpegSha256 = "8F0012234B464CE50890C490F18194F913A7B1F4E6A03D6644179FA0F867D0CF"

if (-not $Destination) {
    $Destination = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "target-raw-pipeline\libraw"
}
New-Item -ItemType Directory -Force -Path $Destination | Out-Null

function Get-Source {
    param([string]$Url, [string]$Name, [string]$Sha256, [string]$UnpackedName)
    $archive = Join-Path $Destination $Name
    if ((Test-Path $archive) -and -not $Force) {
        $actual = (Get-FileHash $archive -Algorithm SHA256).Hash
        if ($actual -ne $Sha256) {
            Write-Host "  $Name is present but its hash differs; downloading again"
            Remove-Item $archive -Force
        }
    }
    if (-not (Test-Path $archive)) {
        Write-Host "  downloading $Url"
        Invoke-WebRequest -Uri $Url -OutFile $archive -UseBasicParsing -TimeoutSec 600
    }
    $actual = (Get-FileHash $archive -Algorithm SHA256).Hash
    if ($actual -ne $Sha256) {
        throw "checksum mismatch for $Name'': expected $Sha256, got $actual"
    }
    Write-Host "  $Name  sha256 ok  $([math]::Round((Get-Item $archive).Length / 1KB)) KB"
    $unpacked = Join-Path $Destination $UnpackedName
    if (-not (Test-Path $unpacked)) {
        Write-Host "  unpacking into $unpacked"
        tar -xzf $archive -C $Destination
        if ($LASTEXITCODE -ne 0) { throw "tar failed for $Name with exit $LASTEXITCODE" }
    }
    return $unpacked
}

Write-Host "LibRaw $LibRawVersion and libjpeg-turbo $JpegVersion into $Destination"
$librawRoot = Get-Source -Url $LibRawUrl -Name "LibRaw-$LibRawVersion.tar.gz" -Sha256 $LibRawSha256 -UnpackedName "LibRaw-$LibRawVersion"
$jpegRoot = Get-Source -Url $JpegUrl -Name "libjpeg-turbo-$JpegVersion.tar.gz" -Sha256 $JpegSha256 -UnpackedName "libjpeg-turbo-$JpegVersion"

$versionHeader = Join-Path $librawRoot "libraw\libraw_version.h"
$major = (Select-String -Path $versionHeader -Pattern "#define LIBRAW_MAJOR_VERSION (\d+)").Matches[0].Groups[1].Value
$minor = (Select-String -Path $versionHeader -Pattern "#define LIBRAW_MINOR_VERSION (\d+)").Matches[0].Groups[1].Value
$patch = (Select-String -Path $versionHeader -Pattern "#define LIBRAW_PATCH_VERSION (\d+)").Matches[0].Groups[1].Value

Write-Host ""
Write-Host "LibRaw source:       $librawRoot  (version $major.$minor.$patch)"
Write-Host "libjpeg-turbo source: $jpegRoot"
Write-Host "Next: pwsh -File tools/libraw/build-libraw.ps1"
