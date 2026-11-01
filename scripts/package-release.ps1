<#
.SYNOPSIS
    Builds and packages a release-ready Semkootru artifact for the current machine.

.DESCRIPTION
    This script keeps the release flow close to the engine's documented build steps:
    it builds the executable, copies the runtime assets next to it, and stages a
    small "release" tree that is easy to zip or ship. It intentionally avoids
    dev-only overlays, editor-only files, and source-only assets.
#>

param(
    [string]$OutputDir = "zig-out\release",
    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

function Fail([string]$message) {
    Write-Host "ERROR: $message" -ForegroundColor Red
    exit 1
}

function Ensure-Directory([string]$path) {
    if (Test-Path $path) {
        Remove-Item $path -Recurse -Force
    }
    New-Item -ItemType Directory -Path $path | Out-Null
}

function Assert-RequiredFiles([string[]]$paths) {
    foreach ($path in $paths) {
        if (-not (Test-Path $path)) {
            Fail "Required packaged file is missing: $path"
        }
    }
}

if (-not (Test-Path "build.zig")) {
    Fail "This script must run from the project root, next to build.zig."
}

if (-not $SkipBuild) {
    Write-Host "Building the executable and staged assets..."
    & zig build
    if ($LASTEXITCODE -ne 0) {
        Fail "zig build failed; fix the build before packaging a release artifact."
    }
}

$binDir = Join-Path $root "zig-out\bin"
$releaseDir = Join-Path $root $OutputDir
Ensure-Directory $releaseDir

$exeNames = @(
    "Semkootru.exe",
    "Semkootru"
)

$exe = $null
foreach ($name in $exeNames) {
    $candidate = Join-Path $binDir $name
    if (Test-Path $candidate) {
        $exe = $candidate
        break
    }
}

if (-not $exe) {
    Fail "No built Semkootru executable was found in zig-out\bin. Build it first or pass -SkipBuild only if the artifact already exists."
}

$destExe = Join-Path $releaseDir (Split-Path $exe -Leaf)
Copy-Item $exe $destExe -Force

$assetSourceDir = Join-Path $binDir "assets"
if (Test-Path $assetSourceDir) {
    Copy-Item $assetSourceDir (Join-Path $releaseDir "assets") -Recurse -Force
}

foreach ($path in @("settings.txt", "README.md")) {
    $source = Join-Path $root $path
    if (Test-Path $source) {
        Copy-Item $source (Join-Path $releaseDir (Split-Path $path -Leaf)) -Force
    }
}

Assert-RequiredFiles @($destExe, (Join-Path $releaseDir "assets"))

$commit = $null
try {
    $commit = (& git -C $root rev-parse --short HEAD 2>$null).Trim()
} catch {
    $commit = $null
}
if ($null -eq $commit -or $commit.Length -eq 0) {
    $commit = "unknown"
}

$manifestPath = Join-Path $releaseDir "release-manifest.txt"
$generatedAt = (Get-Date).ToUniversalTime().ToString("o")
$manifest = @(
    "project=Bairava Engine",
    "artifact_name=$((Split-Path $destExe -Leaf))",
    "generated_at_utc=$generatedAt",
    "git_commit=$commit",
    "runtime_assets=assets",
    "docs=README.md",
    "settings=settings.txt"
) -join [Environment]::NewLine
Set-Content -Path $manifestPath -Value $manifest -Encoding UTF8

Assert-RequiredFiles @($destExe, (Join-Path $releaseDir "assets"), $manifestPath)

Write-Host "Release package ready at: $releaseDir"
Write-Host "Includes the executable, packaged runtime assets, the shipped settings/docs, and a release manifest."
