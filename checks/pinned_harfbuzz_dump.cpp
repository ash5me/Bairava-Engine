#include "hb.h"

#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static bool read_file(const char* path, std::vector<unsigned char>& bytes) {
    FILE* file = std::fopen(path, "rb");
    if (!file) return false;
    std::fseek(file, 0, SEEK_END);
    long length = std::ftell(file);
    std::rewind(file);
    if (length < 0) {
        std::fclose(file);
        return false;
    }
    bytes.resize(static_cast<size_t>(length));
    if (length > 0 && std::fread(bytes.data(), 1, bytes.size(), file) != bytes.size()) {
        std::fclose(file);
        return false;
    }
    std::fclose(file);
    return true;
}

static void dump_run(const char* font_path, const char* script, const char* language,
                     const char* text, const char* label) {
    std::vector<unsigned char> bytes;
    if (!read_file(font_path, bytes)) {
        std::printf("ERROR font=%s label=%s read_failed\n", font_path, label);
        return;
    }

    stbtt_fontinfo stb;
    if (!stbtt_InitFont(&stb, bytes.data(), 0)) {
        std::printf("ERROR font=%s label=%s invalid_stb_font\n", font_path, label);
        return;
    }
    int ascent = 0;
    int descent = 0;
    int line_gap = 0;
    stbtt_GetFontVMetrics(&stb, &ascent, &descent, &line_gap);

    hb_blob_t* blob = hb_blob_create(reinterpret_cast<const char*>(bytes.data()),
                                     static_cast<unsigned int>(bytes.size()),
                                     HB_MEMORY_MODE_READONLY, nullptr, nullptr);
    hb_face_t* face = hb_face_create(blob, 0);
    hb_font_t* font = hb_font_create(face);
    unsigned upem = hb_face_get_upem(face);
    float em_px = 16.0f * static_cast<float>(upem) / static_cast<float>(ascent - descent);
    int hb_scale = static_cast<int>(std::round(em_px * 64.0f));
    hb_font_set_scale(font, hb_scale, hb_scale);

    hb_buffer_t* buffer = hb_buffer_create();
    hb_buffer_set_direction(buffer, HB_DIRECTION_LTR);
    hb_buffer_set_script(buffer, hb_script_from_string(script, -1));
    hb_buffer_set_language(buffer, hb_language_from_string(language, -1));
    hb_buffer_set_cluster_level(buffer, HB_BUFFER_CLUSTER_LEVEL_MONOTONE_GRAPHEMES);
    hb_buffer_add_utf8(buffer, text, -1, 0, -1);
    hb_shape(font, buffer, nullptr, 0);

    unsigned count = 0;
    hb_glyph_info_t* infos = hb_buffer_get_glyph_infos(buffer, &count);
    hb_glyph_position_t* positions = hb_buffer_get_glyph_positions(buffer, &count);

    std::printf("%s font=%s script=%s language=%s hb_scale=%d count=%u ", label, font_path,
                script, language, hb_scale, count);
    float width = 0.0f;
    for (unsigned i = 0; i < count; ++i) {
        float x_advance = static_cast<float>(positions[i].x_advance) / 64.0f;
        float y_advance = -static_cast<float>(positions[i].y_advance) / 64.0f;
        float x_offset = static_cast<float>(positions[i].x_offset) / 64.0f;
        float y_offset = -static_cast<float>(positions[i].y_offset) / 64.0f;
        width += x_advance;
        std::printf("%s{id=%u,cluster=%u,x_advance=%.8f,y_advance=%.8f,x_offset=%.8f,y_offset=%.8f}",
                    i == 0 ? "" : ",", infos[i].codepoint, infos[i].cluster,
                    x_advance, y_advance, x_offset, y_offset);
    }
    std::printf(" width=%.8f\n", width);

    hb_buffer_destroy(buffer);
    hb_font_destroy(font);
    hb_face_destroy(face);
    hb_blob_destroy(blob);
}

int main() {
    std::printf("HarfBuzz %s\n", hb_version_string());

    dump_run("assets/font.ttf", "Latn", "en", "A", "latin_A");
    dump_run("assets/font.ttf", "Latn", "en", "AV", "latin_AV");
    dump_run("assets/font.ttf", "Latn", "en", "AVATAR", "latin_AVATAR");
    dump_run("assets/font.ttf", "Latn", "en", "a\u0305", "latin_overline");

    const char* kssa = "\u0b95\u0bcd\u0bb7";
    const char* vowel_o = "\u0b95\u0bca";
    const char* anusvara = "\u0b95\u0b82";
    const char* tamil = "\u0ba4\u0bae\u0bbf\u0bb4\u0bcd";

    dump_run("tests/fixtures/NotoSansTamil.ttf", "Taml", "ta", kssa, "noto_kssa");
    dump_run("tests/fixtures/NotoSansTamil.ttf", "Latn", "en", kssa, "noto_latn_kssa");
    dump_run("tests/fixtures/NotoSansTamil.ttf", "Taml", "ta", vowel_o, "noto_vowel_o");
    dump_run("tests/fixtures/NotoSansTamil.ttf", "Taml", "ta", anusvara, "noto_anusvara");
    dump_run("tests/fixtures/NotoSansTamil.ttf", "Taml", "ta", tamil, "noto_tamil");

    dump_run("tests/fixtures/ChemmozhiParanar.ttf", "Taml", "ta", kssa, "chemmozhi_kssa");
    dump_run("tests/fixtures/ChemmozhiParanar.ttf", "Latn", "en", kssa, "chemmozhi_latn_kssa");
    dump_run("tests/fixtures/ChemmozhiParanar.ttf", "Taml", "ta", vowel_o, "chemmozhi_vowel_o");
    dump_run("tests/fixtures/ChemmozhiParanar.ttf", "Taml", "ta", anusvara, "chemmozhi_anusvara");
    dump_run("tests/fixtures/ChemmozhiParanar.ttf", "Taml", "ta", tamil, "chemmozhi_tamil");
    return 0;
}
