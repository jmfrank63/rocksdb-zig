#!/usr/bin/env pwsh
# Build RocksDB with MSVC from vendor/rocksdb submodule

param(
    [ValidateSet("Debug", "Release")]
    [string]$BuildType = "Debug",

    [switch]$KeepObjects
)

$ErrorActionPreference = "Stop"

# Determine project root (one level up from scripts directory)
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

# Check if rocksdb source exists
$RocksDBPath = Join-Path $ProjectRoot "vendor\rocksdb"
if (-not (Test-Path $RocksDBPath)) {
    Write-Host "ERROR: RocksDB source not found" -ForegroundColor Red
    Write-Host "Expected location: $RocksDBPath" -ForegroundColor Yellow
    Write-Host "" 
    Write-Host "Please ensure the RocksDB submodule is initialized:" -ForegroundColor Yellow
    Write-Host "  git submodule update --init --recursive" -ForegroundColor Gray
    Write-Host "Or clone manually:" -ForegroundColor Yellow
    Write-Host "  git clone --depth 1 --branch v10.9.1 https://github.com/facebook/rocksdb.git vendor/rocksdb" -ForegroundColor Gray
    exit 1
}

Write-Host "Using RocksDB source: $RocksDBPath" -ForegroundColor Cyan

# Store BuildType in a variable that won't be affected by scope changes
$ConfigType = $BuildType

# Build directory under build/
$buildDir = Join-Path $ProjectRoot "build\rocksdb_$ConfigType"

Write-Host "=== Building RocksDB $ConfigType with MSVC ===" -ForegroundColor Cyan
Write-Host ""

# Create build directory
if (Test-Path $buildDir) {
    Write-Host "Using existing build directory: $buildDir" -ForegroundColor Yellow
} else {
    Write-Host "Creating build directory: $buildDir" -ForegroundColor Green
    New-Item -ItemType Directory -Path $buildDir | Out-Null
}

Set-Location $buildDir

# Configure with CMake
Write-Host "Configuring RocksDB..." -ForegroundColor Cyan

# Setup MSVC environment for Ninja (PowerShell version)
Write-Host "Setting up MSVC environment..." -ForegroundColor Cyan

# VsDevCmd.bat honours a pre-set VSINSTALLDIR and resolves its extension scripts
# (core\msbuild.bat, ext\cmake.bat, ...) against it. When the parent environment
# carries a stale value - e.g. a VS install that has since been removed, which
# editors and terminals happily inherit - those extensions fail with
# "init:FAILED code:1", VsDevCmd reports errors, and the VC environment is never
# exported: cl.exe never lands on PATH. Clear the inherited VS/compiler variables
# so initialisation starts from a clean slate.
foreach ($stale in @(
    'VSINSTALLDIR', 'VCINSTALLDIR', 'VCToolsInstallDir', 'DevEnvDir',
    'INCLUDE', 'LIB', 'LIBPATH', 'CommandPromptType',
    'VSCMD_VER', 'VSCMD_ARG_HOST_ARCH', 'VSCMD_ARG_TGT_ARCH'
)) {
    if (Test-Path "Env:$stale") {
        Write-Host "  clearing inherited $stale" -ForegroundColor DarkGray
        Remove-Item "Env:$stale" -ErrorAction SilentlyContinue
    }
}
$preferredVsPath = "C:\Program Files\Microsoft Visual Studio\18\Insiders"
$vsPath = if (Test-Path $preferredVsPath) { $preferredVsPath } else { $null }

if (-not $vsPath) {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        Write-Host "ERROR: vswhere.exe not found. Install Visual Studio Build Tools." -ForegroundColor Red
        Set-Location $ProjectRoot
        exit 1
    }

    # -prerelease so Preview / Insiders installs are discovered too; without it
    # vswhere reports nothing on machines that only have a prerelease VS.
    $vsPath = & $vswhere -prerelease -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vsPath) {
        Write-Host "ERROR: Visual Studio with C++ tools not found." -ForegroundColor Red
        Set-Location $ProjectRoot
        exit 1
    }
}

$vsDevShell = Join-Path $vsPath "Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
$vcvars64 = Join-Path $vsPath "VC\Auxiliary\Build\vcvars64.bat"

if (Test-Path $vsDevShell) {
    Import-Module $vsDevShell
    Enter-VsDevShell -VsInstallPath $vsPath -SkipAutomaticLocation -DevCmdArguments "-arch=x64 -host_arch=x64"
    Write-Host "MSVC environment configured (DevShell)" -ForegroundColor Green
} elseif (Test-Path $vcvars64) {
    $envDump = cmd /c "call `"$vcvars64`" -arch=x64 -host_arch=x64 >nul && set"
    foreach ($line in $envDump) {
        $idx = $line.IndexOf('=')
        if ($idx -gt 0) {
            $name = $line.Substring(0, $idx)
            $value = $line.Substring($idx + 1)
            Set-Item -Path "Env:$name" -Value $value
        }
    }
    Write-Host "MSVC environment configured (vcvars64.bat)" -ForegroundColor Green
} else {
    Write-Host "ERROR: vcvars64.bat not found under Visual Studio." -ForegroundColor Red
    Set-Location $ProjectRoot
    exit 1
}

# /FS is only needed for Debug builds (which generate PDB files with /Zi)
# Release builds don't generate PDBs, so /FS is unnecessary and slows down parallel compilation
if ($BuildType -eq 'Debug') {
    $env:_CL_ = "/FS"
    Write-Host "Debug mode: Using /FS to prevent PDB conflicts" -ForegroundColor Yellow
} else {
    $env:_CL_ = ""
    Write-Host "Release mode: /FS disabled for maximum parallelism" -ForegroundColor Green
}
$env:_LINK_ = ""

# Release: No debug symbols (/O2 /Ob2 /DEBUG:NONE /MT, no /Zi)
# Debug: Full debug symbols (/Zi /Ob0 /Od /RTC1 /MTd)
# /MP enables multi-processor compilation within a single source file
# /W4 = high warning level (matches RocksDB's default)
# Note: /MT is set via CMAKE_MSVC_RUNTIME_LIBRARY + CMP0091=NEW, RTTI via USE_RTTI=ON
$ReleaseFlags = "/O2 /Ob2 /DEBUG:NONE /W4 /MP"
$DebugFlags = "/Zi /Ob0 /Od /RTC1 /W4 /MP"

cmake "$RocksDBPath" `
    -G "Ninja" `
    -DCMAKE_BUILD_TYPE="$ConfigType" `
    -DCMAKE_POLICY_DEFAULT_CMP0091=NEW `
    -DCMAKE_MSVC_RUNTIME_LIBRARY="MultiThreaded$( if ($ConfigType -eq 'Debug') { 'Debug' } )" `
    -DWITH_MD_LIBRARY=OFF `
    -DUSE_RTTI=ON `
    -DCMAKE_CXX_FLAGS="/W4 /MP" `
    -DCMAKE_C_FLAGS="/W4 /MP" `
    -DCMAKE_CXX_FLAGS_RELEASE="$ReleaseFlags" `
    -DCMAKE_C_FLAGS_RELEASE="$ReleaseFlags" `
    -DCMAKE_EXE_LINKER_FLAGS_RELEASE="/INCREMENTAL:NO /DEBUG:NONE" `
    -DCMAKE_SHARED_LINKER_FLAGS_RELEASE="/INCREMENTAL:NO /DEBUG:NONE" `
    -DCMAKE_CXX_FLAGS_DEBUG="$DebugFlags" `
    -DCMAKE_C_FLAGS_DEBUG="$DebugFlags" `
    -DROCKSDB_BUILD_SHARED=OFF `
    -DWITH_TESTS=OFF `
    -DWITH_TOOLS=OFF `
    -DWITH_CORE_TOOLS=OFF `
    -DWITH_BENCHMARK_TOOLS=OFF `
    -DWITH_GFLAGS=OFF `
    -DWITH_SNAPPY=OFF `
    -DWITH_LZ4=OFF `
    -DWITH_ZLIB=OFF `
    -DWITH_ZSTD=OFF `
    -DFAIL_ON_WARNINGS=OFF

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: CMake configuration failed" -ForegroundColor Red
    Set-Location $ProjectRoot
    exit 1
}

# RocksDB's own CMakeLists appends /Zi /d2Zi+ to CMAKE_CXX_FLAGS for MSVC
# (CMakeLists.txt:219-220), after our *_FLAGS_RELEASE are applied, so there is
# no cmake variable that removes them. A Release build has no use for them and
# they dominate the object size. Ninja's command lines are the only place left
# to take them out.
if ($ConfigType -eq "Release") {
    $ninjaFile = "build.ninja"
    if (Test-Path $ninjaFile) {
        $ninja = Get-Content $ninjaFile -Raw
        $ninja = $ninja -replace ' /Zi(?= )', '' -replace ' /d2Zi\+(?= )', ''
        Set-Content $ninjaFile $ninja -NoNewline
        Write-Host "Stripped /Zi and /d2Zi+ from the Release command lines" -ForegroundColor Gray
    }
}

# Build only the library. cmake --build with no target builds every target the
# configure step produced, which is how ldb.exe and db_bench.exe were being
# compiled and linked for a consumer that never runs them.
Write-Host "Building RocksDB (this may take several minutes)..." -ForegroundColor Cyan
Write-Host "Using parallel build with all available CPU cores..." -ForegroundColor Cyan
cmake --build . --target rocksdb --parallel

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Build failed" -ForegroundColor Red
    Set-Location $ProjectRoot
    exit 1
}

# Wait for MSBuild processes to complete and release file locks
Write-Host "Waiting for build processes to release file locks..." -ForegroundColor Yellow
Start-Sleep -Milliseconds 500

# Kill lingering mspdbsrv.exe (PDB server) that keeps PDB files locked
Get-Process mspdbsrv -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

# Give Windows time to release file handles
Start-Sleep -Milliseconds 500

# The archive carries a copy of every object, so keeping both doubles the cost
# for nothing. Dropping them costs the next incremental build, which does not
# happen anyway -- build.zig only reruns this script when rocksdb.lib is absent.
if (-not $KeepObjects) {
    $objDir = Join-Path $buildDir "CMakeFiles"
    if (Test-Path $objDir) {
        $before = (Get-ChildItem $objDir -Recurse -Filter *.obj -ErrorAction SilentlyContinue |
                   Measure-Object -Property Length -Sum).Sum
        Get-ChildItem $objDir -Recurse -Filter *.obj -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
        if ($before) {
            Write-Host ("Removed {0:N0} MB of object files already archived into rocksdb.lib" -f ($before / 1MB)) -ForegroundColor Gray
        }
    }
}

Set-Location $ProjectRoot

# Verify the library was created (Ninja puts output directly in build dir, not in Debug/Release subdir)
$libPath = "$buildDir\rocksdb.lib"
if (Test-Path $libPath) {
    $libSize = (Get-Item $libPath).Length / 1MB
    $relativePath = "build\rocksdb_$ConfigType\rocksdb.lib"
    Write-Host ""
    Write-Host "=== SUCCESS ===" -ForegroundColor Green
    Write-Host ""
    Write-Host "RocksDB library built successfully!" -ForegroundColor Green
    Write-Host "  Location: $relativePath" -ForegroundColor Cyan
    Write-Host "  Size: $([math]::Round($libSize, 2)) MB" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "You can now build with:" -ForegroundColor Yellow
    Write-Host "  zig build -Dtarget=native-windows-msvc" -ForegroundColor Gray
} else {
    Write-Host ""
    Write-Host "WARNING: Library file not found at build\rocksdb_$ConfigType\rocksdb.lib" -ForegroundColor Yellow
    Write-Host "Build may have succeeded but library is in unexpected location" -ForegroundColor Yellow
}
