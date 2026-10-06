<#
.SYNOPSIS
    Builds libjpeg-turbo and LibRaw into target-raw-pipeline/libraw/build.

.DESCRIPTION
    1. libjpeg-turbo, static, no SIMD (no NASM needed): the IJG-compatible jpeg.lib that LibRaw links
       against for DNG lossy JPEG (compression 34892).
    2. LibRaw, static libraw_r.lib, using tools/libraw/CMakeLists.txt.
    3. Optionally the LibRaw DLL (LIBRAW_BUILD_SHARED=ON), which is the artifact whose redistribution
       obligations are simplest to satisfy for a closed-source product; the build prints the size of
       everything it produces so the packaging decision is made on numbers.

    Run tools/libraw/fetch-libraw.ps1 first.

.EXAMPLE
    pwsh -File tools/libraw/build-libraw.ps1
    pwsh -File tools/libraw/build-libraw.ps1 -Shared
#>
[CmdletBinding()]
param(
    [string]$Destination = "",
    [string]$Configuration = "Release",
    [switch]$Shared,
    [switch]$Tools,
    [switch]$Force,
    [switch]$Ninja
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if (-not $Destination) {
    $Destination = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "target-raw-pipeline\libraw"
}
$librawRoot = Join-Path $Destination "LibRaw-0.21.4"
$jpegRoot = Join-Path $Destination "libjpeg-turbo-3.1.2"
foreach ($required in @($librawRoot, $jpegRoot)) {
    if (-not (Test-Path $required)) {
        throw "$required is missing; run tools/libraw/fetch-libraw.ps1 first"
    }
}

function Find-Tool {
    param([string]$Name, [string]$WingetPattern)
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $found = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\$WingetPattern" -Recurse -Filter "$Name.exe" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($found) { return $found.FullName }
    throw "$Name was not found; see docs/TOOLCHAIN.md"
}

$cmake = Find-Tool -Name "cmake" -WingetPattern "Kitware.CMake_*"
$generator = "Visual Studio 17 2022"
$generatorArgs = @("-G", $generator, "-A", "x64")
if ($Ninja) {
    $ninja = Find-Tool -Name "ninja" -WingetPattern "Ninja-build.Ninja_*"
    $env:CMAKE_MAKE_PROGRAM = $ninja
    $generator = "Ninja"
    $generatorArgs = @("-G", "Ninja", "-DCMAKE_BUILD_TYPE=$Configuration")
}
Write-Host "cmake $((& $cmake --version | Select-Object -First 1)) with $generator"

function Invoke-CMake {
    param([string]$Source, [string]$Build, [string[]]$Arguments)
    if ($Force -and (Test-Path $Build)) { Remove-Item $Build -Recurse -Force }
    Write-Host "==> configuring $Build"
    & $cmake -S $Source -B $Build @generatorArgs @Arguments
    if ($LASTEXITCODE -ne 0) { throw "cmake configure failed for $Source" }
    Write-Host "==> building $Build"
    & $cmake --build $Build --config $Configuration --parallel
    if ($LASTEXITCODE -ne 0) { throw "cmake build failed for $Source" }
}

# 1. libjpeg-turbo: static, no SIMD (that is the part that would need NASM).
# Rust links the dynamic CRT, so both libraries must use it too: mixing /MT and /MD in one process
# means two heaps and two sets of globals, which the linker warns about and which breaks in ways that
# are hard to trace.
$runtime = "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL"
$jpegBuild = Join-Path $Destination "build\jpeg"
Invoke-CMake -Source $jpegRoot -Build $jpegBuild -Arguments @(
    $runtime,
    # libjpeg-turbo overrides CMAKE_MSVC_RUNTIME_LIBRARY from its own WITH_CRT_DLL option, and its
    # default is the static CRT, which cannot be mixed with Rust's dynamic one.
    "-DWITH_CRT_DLL=ON",
    "-DENABLE_SHARED=OFF",
    "-DWITH_SIMD=OFF",
    "-DWITH_TURBOJPEG=OFF",
    "-DWITH_TOOLS=OFF",
    "-DWITH_TESTS=OFF",
    "-DWITH_JAVA=OFF",
    "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
)

# 2. LibRaw static.
$librawBuild = Join-Path $Destination "build\libraw-static"
Invoke-CMake -Source (Join-Path $PSScriptRoot ".") -Build $librawBuild -Arguments @(
    $runtime,
    "-DLIBRAW_ROOT=$librawRoot",
    # jpeglib.h lives in the source's src/ directory, jconfig.h is generated into the build directory.
    "-DLIBRAW_JPEG_SRC=$(Join-Path $jpegRoot 'src')",
    "-DLIBRAW_JPEG_BUILD=$jpegBuild",
    "-DLIBRAW_BUILD_SHARED=OFF",
    "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
)

# 3. Optionally the DLL, for the packaging decision.
if ($Shared) {
    # The DLL links libjpeg in rather than leaving it to the consumer, so a program that uses the DLL
    # only has to ship raw.dll.
    $jpegLib = Join-Path $jpegBuild "$Configuration\jpeg-static.lib"
    $sharedBuild = Join-Path $Destination "build\libraw-shared"
    Invoke-CMake -Source (Join-Path $PSScriptRoot ".") -Build $sharedBuild -Arguments @(
        $runtime,
        "-DLIBRAW_ROOT=$librawRoot",
        "-DLIBRAW_JPEG_SRC=$(Join-Path $jpegRoot 'src')",
        "-DLIBRAW_JPEG_BUILD=$jpegBuild",
        "-DLIBRAW_JPEG_LIB=$jpegLib",
        "-DLIBRAW_BUILD_SHARED=ON",
        "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
    )
}

# LibRaw's own tools, for telling an upstream decoder problem apart from a mistake in the way
# compositor calls the library.
if ($Tools) {
    $toolsBuild = Join-Path $Destination "build\tools"
    Invoke-CMake -Source (Join-Path $PSScriptRoot ".") -Build $toolsBuild -Arguments @(
        $runtime,
        "-DLIBRAW_ROOT=$librawRoot",
        "-DLIBRAW_JPEG_SRC=$(Join-Path $jpegRoot 'src')",
        "-DLIBRAW_JPEG_BUILD=$jpegBuild",
        "-DLIBRAW_JPEG_LIB=$(Join-Path $jpegBuild "$Configuration\jpeg-static.lib")",
        "-DLIBRAW_BUILD_TOOLS=ON",
        "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
    )
}

Write-Host ""
Write-Host "Artifacts under $Destination\build:"
Get-ChildItem (Join-Path $Destination "build") -Recurse -Include *.lib, *.dll, *.exp -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch "CMakeFiles" } |
    Sort-Object FullName |
    ForEach-Object { Write-Host ("  {0,12:N0}  {1}" -f $_.Length, $_.FullName.Substring($Destination.Length + 1)) }
