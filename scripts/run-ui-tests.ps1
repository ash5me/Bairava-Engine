<#
.SYNOPSIS
    Builds and runs the text and widget C harnesses (tests/ui) on Windows.

.DESCRIPTION
    The harnesses are not part of "zig build test", and their include paths and
    FreeType flags live inside build.zig. This script gets those flags from the
    real build: it deletes the local .zig-cache, runs "zig build --verbose-cc" so
    Zig prints every C compile command, copies the -I and -D flags and the
    FreeType source list from those commands, then compiles and runs both
    harnesses with "zig cc".

    Save this file in the project root (the folder that contains build.zig), then run:
        powershell -ExecutionPolicy Bypass -File .\run-ui-tests.ps1

.PARAMETER FontPath
    Font file the harnesses bake. Defaults to assets\font.ttf.
#>
param(
    [string]$FontPath = "assets\font.ttf"
)

Set-Location -Path $PSScriptRoot

function Fail([string]$message) {
    Write-Host "ERROR: $message" -ForegroundColor Red
    exit 1
}

function Get-Tokens([string]$line) {
    @($line -split '\s+' | ForEach-Object { $_.Trim('"') } | Where-Object { $_ -ne '' })
}

# Keeps only include (-I) and macro (-D) flags. Handles both "-Ipath" and "-I path".
# The comparisons are case-sensitive (-ceq, -cmatch). PowerShell's -eq and -match ignore
# case by default, so lowercase flags such as -inline-asm-use-gpr32 would match -I.
function Get-IncludeAndMacroFlags([string[]]$tokens) {
    $result = @()
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $t = $tokens[$i]
        if ($t -ceq '-I' -or $t -ceq '-D') {
            if ($i + 1 -lt $tokens.Count) {
                $result += ($t + $tokens[$i + 1])
                $i++
            }
        }
        elseif ($t -cmatch '^-[ID]\S') {
            $result += $t
        }
    }
    return $result
}

# --- 0. Sanity checks --------------------------------------------------------

if (-not (Test-Path "build.zig")) {
    Fail "build.zig not found. Save this script in the project root, next to build.zig."
}
if (-not (Get-Command zig -ErrorAction SilentlyContinue)) {
    Fail "zig is not on PATH."
}

$requiredFiles = @(
    "tests\ui\test_text.c",
    "tests\ui\test_imgui.c",
    "src\engine\ui\text.c",
    "src\engine\ui\imgui.c",
    "vendor\stb_truetype_impl.c"
)
foreach ($file in $requiredFiles) {
    if (-not (Test-Path $file)) {
        Fail "Missing $file"
    }
}
if (-not (Test-Path $FontPath)) {
    Fail "Font not found at '$FontPath'. Copy a .ttf or .otf file there (fonts are not included), or pass -FontPath."
}

# --- 1. Run the real build with verbose C commands ---------------------------

Write-Host "Clearing the local Zig cache so every C file is compiled and printed..."
Remove-Item -Recurse -Force ".zig-cache" -ErrorAction SilentlyContinue

New-Item -ItemType Directory -Force "ui-tests" | Out-Null
$buildOutput = cmd /c "zig build --verbose-cc 2>&1"
$buildExit = $LASTEXITCODE
$buildOutput | Set-Content "ui-tests\zig-build-log.txt"

if ($buildExit -ne 0) {
    $buildOutput | Select-Object -Last 25 | ForEach-Object { Write-Host $_ }
    Fail "zig build failed. The full log is in ui-tests\zig-build-log.txt. Fix the build first."
}

$lines = @($buildOutput | ForEach-Object { "$_" })

# --- 2. Read include paths, macros and FreeType sources from those commands ---

$textLine = $lines | Where-Object { $_ -match '[\\/]text\.c(\s|"|$)' } | Select-Object -First 1
$imguiLine = $lines | Where-Object { $_ -match '[\\/]imgui\.c(\s|"|$)' } | Select-Object -First 1
$stbLine = $lines | Where-Object { $_ -match 'stb_truetype_impl\.c' } | Select-Object -First 1
$freetypeLines = @($lines | Where-Object { $_ -match 'vendor[\\/]freetype' })

if (-not $textLine) {
    Fail "No compile command for text.c in the build output. Send ui-tests\zig-build-log.txt to get help."
}

$freetypeSources = @()
foreach ($line in $freetypeLines) {
    foreach ($token in (Get-Tokens $line)) {
        if ($token -match 'vendor[\\/]freetype.*\.c$') {
            $freetypeSources += $token
        }
    }
}
$freetypeSources = @($freetypeSources | Select-Object -Unique)

$flagLines = @(@($textLine, $imguiLine, $stbLine) + $freetypeLines | Where-Object { $_ })
$flags = @()
foreach ($line in $flagLines) {
    $flags += Get-IncludeAndMacroFlags (Get-Tokens $line)
}
$flags = @($flags | Select-Object -Unique)

Write-Host ("Found {0} include/macro flags and {1} FreeType source files." -f $flags.Count, $freetypeSources.Count)
if ($freetypeSources.Count -eq 0) {
    Write-Host "Warning: no FreeType sources found in the build output. Linking may fail." -ForegroundColor Yellow
}

# --- 3. Compile the harnesses ------------------------------------------------

function Build-Harness([string]$name, [string[]]$sources) {
    $exe = "ui-tests\$name.exe"
    Write-Host ""
    Write-Host "Compiling $name..."
    & zig cc @flags -o $exe @sources @freetypeSources
    if ($LASTEXITCODE -ne 0) {
        Fail "Compiling $name failed. The compiler errors are above."
    }
    return $exe
}

$textExe = Build-Harness "test_text" @(
    "tests\ui\test_text.c",
    "src\engine\ui\text.c",
    "vendor\stb_truetype_impl.c"
)

$imguiExe = Build-Harness "test_imgui" @(
    "tests\ui\test_imgui.c",
    "src\engine\ui\imgui.c",
    "src\engine\ui\text.c",
    "vendor\stb_truetype_impl.c"
)

# --- 4. Run the harnesses ----------------------------------------------------

function Run-Harness([string]$exe, [string]$expected) {
    Write-Host ""
    Write-Host "=== $exe ==="
    $output = & $exe $FontPath 2>&1 | ForEach-Object { "$_" }
    $exitCode = $LASTEXITCODE
    $output | ForEach-Object { Write-Host $_ }
    $found = ($output -join "`n") -match [regex]::Escape($expected)
    return ($exitCode -eq 0 -and $found)
}

$textPassed = Run-Harness $textExe "text: all checks passed"
$imguiPassed = Run-Harness $imguiExe "imgui: all checks passed"

Write-Host ""
if ($textPassed -and $imguiPassed) {
    Write-Host "Both harnesses passed." -ForegroundColor Green
}
else {
    $failed = @()
    if (-not $textPassed) { $failed += "test_text" }
    if (-not $imguiPassed) { $failed += "test_imgui" }
    Write-Host ("Failed: " + ($failed -join ", ")) -ForegroundColor Red
    exit 1
}
