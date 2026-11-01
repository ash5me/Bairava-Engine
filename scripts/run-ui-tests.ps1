<#
.SYNOPSIS
    Runs the text and widget C harnesses through the Zig build.

.PARAMETER FontPath
    Font file the harnesses bake. Defaults to assets\font.ttf.
#>
param(
    [string]$FontPath = "assets\font.ttf"
)

$ErrorActionPreference = "Stop"
Set-Location -Path (Join-Path $PSScriptRoot "..")

if (-not (Get-Command zig -ErrorAction SilentlyContinue)) {
    Write-Error "zig is not on PATH."
    exit 1
}
if (-not (Test-Path $FontPath)) {
    Write-Error "Font not found at '$FontPath'."
    exit 1
}

$zigArgs = @("build", "test-ui", "--", $FontPath)
& zig @zigArgs
exit $LASTEXITCODE
