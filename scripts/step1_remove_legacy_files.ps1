# Step 1 of migration.md: remove the 31 unreachable legacy files from src/engine/.
# Run this script from the repository root (the folder that contains src/main.zig):
#   .\step1_remove_legacy_files.ps1

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath "src/main.zig" -PathType Leaf) -or
    -not (Test-Path -LiteralPath "src/engine/platform" -PathType Container)) {
    Write-Error "Run this script from the repository root (the folder that contains src/main.zig)."
    exit 1
}

$files = @(
    "src/engine/animation.zig"
    "src/engine/asset_cache.zig"
    "src/engine/assets.zig"
    "src/engine/atlas.zig"
    "src/engine/audio.zig"
    "src/engine/audio_voices.zig"
    "src/engine/camera.zig"
    "src/engine/debug_overlay.zig"
    "src/engine/engine.zig"
    "src/engine/entity.zig"
    "src/engine/frame_history.zig"
    "src/engine/hash_map.zig"
    "src/engine/ima.zig"
    "src/engine/image.zig"
    "src/engine/input.zig"
    "src/engine/loaded_atlas.zig"
    "src/engine/log.zig"
    "src/engine/math.zig"
    "src/engine/profile.zig"
    "src/engine/renderer.zig"
    "src/engine/sdl.zig"
    "src/engine/settings.zig"
    "src/engine/shader.zig"
    "src/engine/sprite.zig"
    "src/engine/string.zig"
    "src/engine/texture.zig"
    "src/engine/tilemap.zig"
    "src/engine/tilemap_draw.zig"
    "src/engine/ui.zig"
    "src/engine/vector.zig"
    "src/engine/view.zig"
)

$removed = 0

foreach ($file in $files) {
    if (Test-Path -LiteralPath $file -PathType Leaf) {
        Remove-Item -LiteralPath $file -Force
        $removed++
        Write-Host "removed: $file"
    }
    else {
        Write-Host "already gone: $file"
    }
}

Write-Host "Removed $removed of $($files.Count) files."
