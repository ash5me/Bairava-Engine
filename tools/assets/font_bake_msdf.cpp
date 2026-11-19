#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_OUTLINE_H

#include "font_bake.h"

#define STB_RECT_PACK_IMPLEMENTATION
#include "../../vendor/stb_rect_pack.h"
#include "../../vendor/msdfgen-1.13/core/Bitmap.h"
#include "../../vendor/msdfgen-1.13/core/Projection.h"
#include "../../vendor/msdfgen-1.13/core/Shape.h"
#include "../../vendor/msdfgen-1.13/core/edge-coloring.h"
#include "../../vendor/msdfgen-1.13/core/generator-config.h"
#include "../../vendor/msdfgen-1.13/msdfgen.h"
#include "../../vendor/msdfgen-1.13/ext/import-font.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <vector>

namespace {

const unsigned kHeaderSize = 64;
const unsigned kRecordSize = 28;
const int kMaxAtlasSize = UI_MSDF_MAX_ATLAS_SIZE;
const double kPixelRange = 4;

struct Glyph {
    float left = 0;
    float bottom = 0;
    float right = 0;
    float top = 0;
    float advance = 0;
    unsigned width = 0;
    unsigned height = 0;
    unsigned x = 0;
    unsigned y = 0;
    msdfgen::Shape shape;
};

void writeU16(unsigned char *out, uint16_t value) {
    out[0] = static_cast<unsigned char>(value);
    out[1] = static_cast<unsigned char>(value >> 8);
}

void writeU32(unsigned char *out, uint32_t value) {
    out[0] = static_cast<unsigned char>(value);
    out[1] = static_cast<unsigned char>(value >> 8);
    out[2] = static_cast<unsigned char>(value >> 16);
    out[3] = static_cast<unsigned char>(value >> 24);
}

void writeF32(unsigned char *out, float value) {
    uint32_t bits = 0;
    std::memcpy(&bits, &value, sizeof bits);
    writeU32(out, bits);
}

unsigned char quantize(float value) {
    return static_cast<unsigned char>(std::max(0.0f, std::min(255.0f, std::floor(value * 255.0f + 0.5f))));
}

bool copyCoverage(const FT_Bitmap &bitmap, unsigned char *target, unsigned atlas_width, unsigned atlas_height,
                  unsigned x, unsigned y, int bitmap_left, int bitmap_top, float plane_left, float plane_top) {
    if (bitmap.width == 0 || bitmap.rows == 0) return true;
    if (bitmap.pixel_mode != FT_PIXEL_MODE_GRAY && bitmap.pixel_mode != FT_PIXEL_MODE_MONO) return false;
    const int pitch = bitmap.pitch < 0 ? -bitmap.pitch : bitmap.pitch;
    const int origin_x = static_cast<int>(std::floor(bitmap_left - plane_left + 0.5f));
    const int origin_y = static_cast<int>(std::floor(plane_top - bitmap_top + 0.5f));
    for (unsigned row = 0; row < bitmap.rows; ++row) {
        const unsigned source_row = bitmap.pitch >= 0 ? row : bitmap.rows - 1 - row;
        const unsigned char *src = bitmap.buffer + static_cast<size_t>(source_row) * pitch;
        const int dst_y = static_cast<int>(y) + origin_y + static_cast<int>(row);
        if (dst_y < 0 || dst_y >= static_cast<int>(atlas_height)) return false;
        for (unsigned col = 0; col < bitmap.width; ++col) {
            const int dst_x = static_cast<int>(x) + origin_x + static_cast<int>(col);
            if (dst_x < 0 || dst_x >= static_cast<int>(atlas_width)) return false;
            unsigned char alpha;
            if (bitmap.pixel_mode == FT_PIXEL_MODE_MONO) {
                alpha = (src[col >> 3] & (0x80u >> (col & 7))) ? 255 : 0;
            } else if (bitmap.num_grays > 1 && bitmap.num_grays != 256) {
                alpha = static_cast<unsigned char>(static_cast<unsigned>(src[col]) * 255u / (bitmap.num_grays - 1));
            } else {
                alpha = src[col];
            }
            target[static_cast<size_t>(dst_y) * atlas_width + static_cast<unsigned>(dst_x)] = alpha;
        }
    }
    return true;
}

bool packGlyphs(std::vector<Glyph> &glyphs, unsigned &side) {
    std::vector<stbrp_rect> rects;
    rects.reserve(glyphs.size());
    for (unsigned i = 0; i < glyphs.size(); ++i) {
        Glyph &glyph = glyphs[i];
        if (!glyph.width || !glyph.height) continue;
        if (glyph.width + 2 > std::numeric_limits<stbrp_coord>::max() ||
            glyph.height + 2 > std::numeric_limits<stbrp_coord>::max()) return false;
        stbrp_rect rect = {};
        rect.id = static_cast<int>(i);
        rect.w = static_cast<stbrp_coord>(glyph.width + 2);
        rect.h = static_cast<stbrp_coord>(glyph.height + 2);
        rects.push_back(rect);
    }
    if (rects.empty()) {
        side = 128;
        return true;
    }
    for (side = 128; side <= kMaxAtlasSize; side *= 2) {
        std::vector<stbrp_rect> trial = rects;
        std::vector<stbrp_node> nodes(side);
        stbrp_context context;
        stbrp_init_target(&context, static_cast<int>(side), static_cast<int>(side), nodes.data(), static_cast<int>(nodes.size()));
        if (!stbrp_pack_rects(&context, trial.data(), static_cast<int>(trial.size()))) continue;
        for (const stbrp_rect &rect : trial) {
            if (!rect.was_packed) break;
            Glyph &glyph = glyphs[static_cast<unsigned>(rect.id)];
            glyph.x = static_cast<unsigned>(rect.x) + 1;
            glyph.y = static_cast<unsigned>(rect.y) + 1;
        }
        bool all_packed = true;
        for (const stbrp_rect &rect : trial) all_packed = all_packed && rect.was_packed;
        if (all_packed) return true;
    }
    return false;
}

int bake(const unsigned char *font_data, size_t font_size, float pixel_height, unsigned fallback_codepoint, const char *path) {
    if (!font_data || font_size == 0 || font_size > static_cast<size_t>(std::numeric_limits<FT_Long>::max()) ||
        font_size > std::numeric_limits<uint32_t>::max() || !(pixel_height > 0) || !path) return UI_MSDF_BAKE_FAILED;

    FT_Library library = nullptr;
    FT_Face face = nullptr;
    if (FT_Init_FreeType(&library) != 0) return UI_MSDF_BAKE_FAILED;
    if (FT_New_Memory_Face(library, font_data, static_cast<FT_Long>(font_size), 0, &face) != 0) {
        FT_Done_FreeType(library);
        return UI_MSDF_BAKE_FAILED;
    }
    bool ok = false;
    bool atlas_too_large = false;
    if (FT_Set_Char_Size(face, 0, static_cast<FT_F26Dot6>(pixel_height * 64.0f + 0.5f), 72, 72) != 0 ||
        face->num_glyphs <= 0 || static_cast<unsigned long>(face->num_glyphs) > std::numeric_limits<uint32_t>::max()) goto done;

    {
        const unsigned glyph_count = static_cast<unsigned>(face->num_glyphs);
        std::vector<Glyph> glyphs(glyph_count);
        for (unsigned id = 0; id < glyph_count; ++id) {
            if (FT_Load_Glyph(face, id, FT_LOAD_NO_BITMAP | FT_LOAD_NO_HINTING) != 0) goto done;
            Glyph &glyph = glyphs[id];
            glyph.advance = static_cast<float>(face->glyph->advance.x) / 64.0f;
            if (face->glyph->format != FT_GLYPH_FORMAT_OUTLINE || face->glyph->outline.n_contours == 0) continue;
            if (msdfgen::readFreetypeOutline(glyph.shape, &face->glyph->outline, 1.0 / 64.0) != 0) goto done;
            glyph.shape.normalize();
            if (!glyph.shape.validate()) goto done;
            const msdfgen::Shape::Bounds bounds = glyph.shape.getBounds();
            const double left = std::floor(bounds.l);
            const double bottom = std::floor(bounds.b);
            const double right = std::ceil(bounds.r);
            const double top = std::ceil(bounds.t);
            glyph.left = static_cast<float>(left - kPixelRange);
            glyph.bottom = static_cast<float>(bottom - kPixelRange);
            glyph.width = static_cast<unsigned>(right - left + 2 * kPixelRange);
            glyph.height = static_cast<unsigned>(top - bottom + 2 * kPixelRange);
            glyph.right = glyph.left + static_cast<float>(glyph.width);
            glyph.top = glyph.bottom + static_cast<float>(glyph.height);
        }

        unsigned atlas_side = 0;
        if (!packGlyphs(glyphs, atlas_side)) {
            atlas_too_large = true;
            goto done;
        }
        const size_t texels = static_cast<size_t>(atlas_side) * atlas_side;
        if (texels > std::numeric_limits<size_t>::max() / 4 ||
            texels * 4 > std::numeric_limits<uint32_t>::max()) goto done;
        std::vector<unsigned char> coverage(texels, 0);
        std::vector<unsigned char> rgba(texels * 4, 0);

        for (unsigned id = 0; id < glyph_count; ++id) {
            Glyph &glyph = glyphs[id];
            if (!glyph.width || !glyph.height) continue;
            if (FT_Load_Glyph(face, id, FT_LOAD_NO_BITMAP | FT_LOAD_NO_HINTING) != 0) goto done;
            msdfgen::edgeColoringSimple(glyph.shape, 3.0, id);
            msdfgen::Bitmap<float, 3> field(static_cast<int>(glyph.width), static_cast<int>(glyph.height), msdfgen::Y_UPWARD);
            const msdfgen::Vector2 translation(-glyph.left, -glyph.bottom);
            msdfgen::generateMSDF(field, glyph.shape, msdfgen::Projection(msdfgen::Vector2(1.0), translation),
                                  msdfgen::Range(kPixelRange), msdfgen::MSDFGeneratorConfig());
            for (unsigned y = 0; y < glyph.height; ++y) {
                for (unsigned x = 0; x < glyph.width; ++x) {
                    const float *sample = field(static_cast<int>(x), static_cast<int>(glyph.height - 1 - y));
                    const size_t dst = (static_cast<size_t>(glyph.y + y) * atlas_side + glyph.x + x) * 4;
                    rgba[dst + 0] = quantize(sample[0]);
                    rgba[dst + 1] = quantize(sample[1]);
                    rgba[dst + 2] = quantize(sample[2]);
                    rgba[dst + 3] = 255;
                }
            }
            if (FT_Render_Glyph(face->glyph, FT_RENDER_MODE_NORMAL) != 0 ||
                !copyCoverage(face->glyph->bitmap, coverage.data(), atlas_side, atlas_side, glyph.x, glyph.y,
                              face->glyph->bitmap_left, face->glyph->bitmap_top, glyph.left, glyph.top)) goto done;
        }

        FILE *output = std::fopen(path, "wb");
        if (!output) goto done;
        unsigned char header[kHeaderSize] = {};
        std::memcpy(header, "MFNT", 4);
        writeU16(header + 4, 1);
        writeU16(header + 6, kHeaderSize);
        writeF32(header + 8, pixel_height);
        writeF32(header + 12, static_cast<float>(kPixelRange));
        writeU32(header + 16, glyph_count);
        writeU32(header + 20, fallback_codepoint);
        writeU32(header + 24, FT_Get_Char_Index(face, fallback_codepoint));
        writeF32(header + 28, static_cast<float>(face->size->metrics.ascender) / 64.0f);
        writeF32(header + 32, static_cast<float>(face->size->metrics.height) / 64.0f);
        writeU32(header + 36, atlas_side);
        writeU32(header + 40, atlas_side);
        writeU32(header + 44, static_cast<uint32_t>(font_size));
        writeU32(header + 48, static_cast<uint32_t>(texels));
        writeU32(header + 52, static_cast<uint32_t>(texels * 4));
        writeU32(header + 56, glyph_count * kRecordSize);
        bool write_ok = std::fwrite(header, 1, sizeof header, output) == sizeof header;
        for (const Glyph &glyph : glyphs) {
            unsigned char record[kRecordSize] = {};
            writeU16(record + 0, static_cast<uint16_t>(glyph.x));
            writeU16(record + 2, static_cast<uint16_t>(glyph.y));
            writeU16(record + 4, static_cast<uint16_t>(glyph.x + glyph.width));
            writeU16(record + 6, static_cast<uint16_t>(glyph.y + glyph.height));
            writeF32(record + 8, glyph.left);
            writeF32(record + 12, glyph.bottom);
            writeF32(record + 16, glyph.right);
            writeF32(record + 20, glyph.top);
            writeF32(record + 24, glyph.advance);
            write_ok = write_ok && std::fwrite(record, 1, sizeof record, output) == sizeof record;
        }
        write_ok = write_ok && std::fwrite(coverage.data(), 1, coverage.size(), output) == coverage.size();
        write_ok = write_ok && std::fwrite(rgba.data(), 1, rgba.size(), output) == rgba.size();
        write_ok = write_ok && std::fwrite(font_data, 1, font_size, output) == font_size;
        if (std::fclose(output) != 0) write_ok = false;
        if (!write_ok) std::remove(path);
        ok = write_ok;
    }

done:
    FT_Done_Face(face);
    FT_Done_FreeType(library);
    return ok ? UI_MSDF_BAKE_OK : (atlas_too_large ? UI_MSDF_BAKE_ATLAS_TOO_LARGE : UI_MSDF_BAKE_FAILED);
}

} // namespace

extern "C" int ui_msdf_bake(const unsigned char *font_data, size_t font_size, float pixel_height,
                            unsigned fallback_codepoint, const char *path) {
    try {
        return bake(font_data, font_size, pixel_height, fallback_codepoint, path);
    } catch (...) {
        return UI_MSDF_BAKE_FAILED;
    }
}
