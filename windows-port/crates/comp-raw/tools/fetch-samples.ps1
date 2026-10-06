<#
.SYNOPSIS
    Downloads the CC0 camera raw samples the comp-raw tests use.

.DESCRIPTION
    The samples come from raw.pixls.us, whose archive is CC0. They are deliberately not committed:
    they are large, and the tests that use them skip themselves with a note when the directory is
    absent. Point COMP_RAW_SAMPLES at the destination, or let it default to
    target-raw-pipeline/comp-raw-samples, which is what tests/vendor.rs looks for.

    Every file is checked against the SHA256 recorded here, so a re-download is verifiable and a
    changed upstream file is caught rather than silently changing what the tests prove.

.EXAMPLE
    pwsh -File crates/comp-raw/tools/fetch-samples.ps1
    pwsh -File crates/comp-raw/tools/fetch-samples.ps1 -IncludeCr3
#>
[CmdletBinding()]
param(
    [string]$Destination = "",
    [switch]$IncludeCr3,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if (-not $Destination) {
    $Destination = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) "target-raw-pipeline\comp-raw-samples"
}
New-Item -ItemType Directory -Force -Path $Destination | Out-Null

$base = "https://raw.pixls.us/data"
$samples = @(
    @{ Name = "RAW_KODAK_DC50.KDC"; Url = "$base/Kodak/DC50/RAW_KODAK_DC50.KDC"; Sha256 = "37E290DBD0053F00E508D02A6B3A2A990432DAD1EB74C40A52CA899F0F225ECC"; Note = "an unknown-camera KDC: rawloader refuses it, LibRaw decodes it" },
    @{ Name = "kodak-dcs760c.DCR"; Url = "$base/Kodak/DCS760C/86L57188.DCR"; Sha256 = "D0E6BD0A3339DAFF884E73A08FED8E75B20FE05BBA438FC185E3F0BD019D0DA8"; Note = "a decodable raw with no as-shot white balance" },
    @{ Name = "nikon-1j2.DSC_0451.NEF"; Url = "$base/Nikon/1%20J2/DSC_0451.NEF"; Sha256 = "81051EE36135883ACEA55BD1E609D6D31212C0BF03640B7AE9FE177A1CA51219"; Note = "a decodable raw with as-shot white balance and a camera matrix" },
    @{ Name = "canon-5d3-compressed-lossy.DNG"; Url = "$base/Adobe%20DNG%20Converter/Canon%20EOS%205D%20Mark%20III/5G4A9395-compressed-lossy.DNG"; Sha256 = "B22F1E36331F679ABB8B13E433B9BBDE3988723ADF10FEE7AA0DDA6381016A98"; Note = "DNG with lossy JPEG sensor data (compression 34892)" },
    @{ Name = "blackmagic-micro-linear.dng"; Url = "$base/Blackmagic/Micro%20Cinema%20Camera/CAM1_2000-01-01_1707_C0003_000100.dng"; Sha256 = "4C65B8CDA205087CFB94D8931811E53E15EB4DF538AD67C1B4A3E76C1185B277"; Note = "a linear DNG whose tiled lossy JPEG data trips rawloader" }
)

# Canon CR3: rawloader has no CR3 decoder at all, LibRaw does. The smallest sample in the archive is
# a 5 MB C-RAW file, which is also the hardest kind (lossy compressed sensor data), so it is optional.
if ($IncludeCr3) {
    $samples += @{
        Name = "canon-eos-r6-craw.CR3"
        Url = "$base/Canon/EOS%20R6/Canon_EOS_R6_CRAW_ISO_100_crop_nodual.CR3"
        Sha256 = ""
        Note = "CR3 container with C-RAW data: the case only LibRaw reads"
    }
}

foreach ($sample in $samples) {
    $path = Join-Path $Destination $sample.Name
    if ((Test-Path $path) -and -not $Force) {
        Write-Host ("  {0} already present" -f $sample.Name)
        continue
    }
    Write-Host ("  downloading {0}  ({1})" -f $sample.Name, $sample.Note)
    Invoke-WebRequest -Uri $sample.Url -OutFile $path -UseBasicParsing -TimeoutSec 900
    if (-not $sample.Sha256) {
        Write-Host ("  {0}  {1:N0} bytes  sha256 {2}" -f $sample.Name, (Get-Item $path).Length, (Get-FileHash $path -Algorithm SHA256).Hash)
        continue
    }
    if ($sample.Sha256) {
        $actual = (Get-FileHash $path -Algorithm SHA256).Hash
        if ($actual -ne $sample.Sha256) {
            Remove-Item $path -Force
            throw "checksum mismatch for $($sample.Name): expected $($sample.Sha256), got $actual"
        }
    }
    Write-Host ("  {0}  {1:N0} bytes  sha256 ok" -f $sample.Name, (Get-Item $path).Length)
}

Write-Host ""
Write-Host "Samples in $Destination"
