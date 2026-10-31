# find-dxil.ps1
#
# Builds the project with DXIL shaders enabled, then checks that the two DXIL
# outputs of shaders/default.slang were written. Run it from the project root
# or from the scripts folder.
#
# The output names come from shader_entries in build.zig: "default.vert" and
# "default.frag", each with the "dxil" extension.

$ErrorActionPreference = "Continue"

# The project root is the folder that contains build.zig. This script may sit in
# the root or in scripts\, so check both places.
$root = $null
foreach ($candidate in @($PSScriptRoot, (Split-Path -Parent $PSScriptRoot))) {
    if ($candidate -and (Test-Path (Join-Path $candidate "build.zig"))) {
        $root = $candidate
        break
    }
}
if (-not $root) {
    Write-Host "ERROR: build.zig not found next to this script or in its parent folder." -ForegroundColor Red
    exit 1
}
Set-Location -Path $root

if (-not (Get-Command zig -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: zig is not on PATH." -ForegroundColor Red
    exit 1
}
if (-not (Get-Command slangc -ErrorAction SilentlyContinue)) {
    Write-Host "WARNING: slangc is not on PATH. The build will fail without it." -ForegroundColor Yellow
}

Write-Host "== 1. Build with DXIL enabled ==" -ForegroundColor Cyan
zig build -Ddxil=true
$buildExit = $LASTEXITCODE
Write-Host "zig build exit code: $buildExit"
if ($buildExit -ne 0) {
    # An earlier build may have left .dxil files in .zig-cache, so don't search
    # after a failed build. That would report stale files as present.
    Write-Host "The build failed. Fix the error above, then run this script again." -ForegroundColor Red
    exit 1
}

Write-Host "`n== 2. Check the DXIL outputs ==" -ForegroundColor Cyan
$expected = @("default.vert.dxil", "default.frag.dxil")
$found = @(Get-ChildItem -Path ".zig-cache", "zig-out" -Recurse -File -Include "*.dxil" -ErrorAction SilentlyContinue)

$missing = 0
foreach ($name in $expected) {
    # If a name appears more than once, use the newest copy.
    $hit = $found |
        Where-Object { $_.Name -eq $name } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($hit) {
        Write-Host ("FOUND    {0}  ->  {1}  ({2} bytes, written {3})" -f $name, $hit.FullName, $hit.Length, $hit.LastWriteTime) -ForegroundColor Green
    }
    else {
        Write-Host "MISSING  $name" -ForegroundColor Red
        $missing++
    }
}

if ($missing -gt 0) {
    Write-Host "`n$missing DXIL output(s) missing, although the build succeeded. Check the slangc step in build.zig." -ForegroundColor Red
    exit 1
}

Write-Host "`nBoth DXIL outputs exist." -ForegroundColor Green
exit 0
