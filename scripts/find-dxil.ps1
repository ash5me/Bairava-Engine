# find-dxil.ps1
# Run from the project root (D:\repo\Bairava-Engine).

$ErrorActionPreference = "Continue"

Write-Host "== 1. Build with DXIL enabled ==" -ForegroundColor Cyan
zig build -Ddxil=true
$buildExit = $LASTEXITCODE
Write-Host "zig build exit code: $buildExit"
if ($buildExit -ne 0) {
    Write-Host "The build failed. The error above is the reason the .dxil files are missing." -ForegroundColor Red
}

Write-Host "`n== 2. Search for DXIL and SPIR-V outputs ==" -ForegroundColor Cyan
$found = Get-ChildItem -Path ".zig-cache", "zig-out" -Recurse -File `
    -Include "*.dxil", "*.spv" -ErrorAction SilentlyContinue

if (-not $found) {
    Write-Host "No .dxil or .spv files found anywhere in .zig-cache or zig-out." -ForegroundColor Yellow
} else {
    $found | Sort-Object LastWriteTime |
        Select-Object FullName, Length, LastWriteTime |
        Format-Table -AutoSize -Wrap
}

Write-Host "`n== 3. Check that the DXIL outputs exist by name ==" -ForegroundColor Cyan
foreach ($name in "triangle.vert.dxil", "triangle.frag.dxil") {
    $hit = $found | Where-Object { $_.Name -eq $name }
    if ($hit) {
        Write-Host "FOUND    $name  ->  $($hit[0].FullName)" -ForegroundColor Green
    } else {
        Write-Host "MISSING  $name" -ForegroundColor Red
    }
}
