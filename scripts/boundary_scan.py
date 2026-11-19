#!/usr/bin/env python3
"""Platform-boundary scanner for engine/game migration (migration.md P0.5).

Finds SDL references under src/, classifies each hit against ALLOWLIST
(migration.md, decision D9), and reports three groups:

    * violations in files reachable from the build roots. These produce CI
        warnings; --fail makes the scan fail (Step 9).
  * allowed hits, listed separately so they do not read as problems.
  * hits in unreachable files. These are dead code that Step 1 removes, so
    they are reported as notices and never fail.

Categories
  sdl_name           an SDL_ or SDLK_ name, or a use of an SDL import alias, in code
  sdl_import         an import of platform/sdl/sdl.zig, or an SDL3 include
  backend_import     an import of another platform/sdl/ file from outside that folder
  engine_game_import an engine file imports a game implementation file
  private_engine_import a game file imports an engine implementation path directly
  game_sdl_import    a game file imports, aliases, names, or includes SDL

Scope:
  - Zig, C, and header files under src/ are scanned, based on reachability from
    src/main.zig, src/engine/core/engine.zig, src/tests.zig, and
    src/engine_api_test.zig.
  - Generated files, vendored dependencies, build scripts, and tools outside
    src/ are excluded unless explicitly added to a future build root.
  - scripts/boundary-fixtures/ contain isolated negative fixtures and are
    not part of the repository source reachability graph.
  - ALLOWLIST entries are narrow exceptions owned by migration.md D9.

Comments are removed, and string-literal bodies are blanked before matching,
so text in comments and strings does not count as a reference. SDL names that
appear only inside strings (for example a panic message) are listed as
information, not as violations.

D-21 (plan section 6.2): a second, text-based check. It follows the public root src/engine/bairava.zig through
its re-exports and flags a HarfBuzz name, or an internal font-resource name, where it appears on that surface:
in a re-export, a pub fn signature, or a field of a pub struct. Known exposures are listed in D21_DEBT by exact
line text. A new exposure, a stale debt entry, or a HarfBuzz name outside src/engine/text/ fails --fail. The
check does not compile Zig, and it does not follow a type through a name that is not itself forbidden.

Usage:
  python3 scripts/boundary_scan.py                 report; exit 0
  python3 scripts/boundary_scan.py --fail          exit 1 on reachable violations
  python3 scripts/boundary_scan.py --report FILE   also write the report to FILE
  python3 scripts/boundary_scan.py --self-test      run negative boundary fixtures
"""

import argparse
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
BUILD_ROOTS = ["src/main.zig", "src/engine/core/engine.zig", "src/tests.zig", "src/engine_api_test.zig"]
SDL_BACKEND_DIR = "src/engine/platform/sdl/"

ALL_CATEGORIES = {
    "sdl_name", "sdl_import", "backend_import",
    "engine_game_import", "private_engine_import", "game_sdl_import",
}

# (path or directory prefix ending in "/", allowed categories, reason).
# Source: migration.md D9. A file missing here must have no hits.
ALLOWLIST = [
    ("src/engine/platform/sdl/", ALL_CATEGORIES,
     "platform/sdl: the SDL implementation"),
    ("src/engine/platform/platform.zig", {"backend_import"},
     "platform facade: forwards engine-facing calls to the SDL backend"),
    ("src/engine/renderer/backends/sdl_gpu/", {"sdl_name", "sdl_import"},
     "SDL GPU backend: passes, shaders, textures, sprite pipelines and buffers"),
    ("src/tests.zig", {"backend_import"},
     "imports SDL backend modules so their platform tests are included"),
]

IMPORT_RE = re.compile(r'@import\("([^"]+)"\)')
DECL_IMPORT_RE = re.compile(r'(?:pub\s+)?const\s+(\w+)\s*=\s*@import\("([^"]+)"\)')
DECL_CIMPORT_RE = re.compile(r'(?:pub\s+)?const\s+(\w+)\s*=\s*@cImport\b')
SDL_NAME_RE = re.compile(r'\bSDLK?_[A-Za-z0-9_]+')
C_INCLUDE_SDL_RE = re.compile(r'#\s*include\s*[<"]SDL3/')


def classify_boundary_import(rel, resolved, target):
    """Return prohibited dependency categories for one Zig import."""
    cats = set()
    if rel.startswith("src/engine/") and resolved.startswith("src/game/"):
        cats.add("engine_game_import")
    if rel.startswith("src/game/"):
        if resolved.startswith("src/engine/"):
            cats.add("private_engine_import")
        if target in ("SDL", "sdl", "bairava_engine_sdl", "platform/sdl/sdl.zig"):
            cats.add("game_sdl_import")
        if resolved.startswith("src/engine/platform/sdl/"):
            cats.add("game_sdl_import")
    return cats


def allowed_for(rel):
    for key, cats, why in ALLOWLIST:
        if (key.endswith("/") and rel.startswith(key)) or rel == key:
            return set(cats), why
    return set(), None


def split_code(raw, is_c, in_block):
    """Return (code, strings, in_block). Comments are dropped; string bodies are blanked."""
    code, strings = [], []
    i, n = 0, len(raw)
    while i < n:
        if in_block:
            j = raw.find("*/", i)
            if j < 0:
                return "".join(code), strings, True
            i, in_block = j + 2, False
            continue
        if raw.startswith("//", i):
            break
        if is_c and raw.startswith("/*", i):
            in_block, i = True, i + 2
            continue
        ch = raw[i]
        if ch in ("'", '"'):
            j, buf = i + 1, []
            while j < n and raw[j] != ch:
                if raw[j] == "\\" and j + 1 < n:
                    buf.append(raw[j:j + 2])
                    j += 2
                else:
                    buf.append(raw[j])
                    j += 1
            strings.append("".join(buf))
            code.append(ch + ch)
            i = j + 1
            continue
        code.append(ch)
        i += 1
    return "".join(code), strings, in_block


def scan_file(path, rel):
    is_c = path.suffix in (".c", ".h")
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()

    parsed, in_block = [], False
    for raw in lines:
        if not is_c and raw.lstrip().startswith("\\\\"):  # Zig multi-line string
            parsed.append(("", [raw.lstrip()[2:]]))
            continue
        code, strings, in_block = split_code(raw, is_c, in_block)
        parsed.append((code, strings))

    all_strings = [s for _, ss in parsed for s in ss]
    file_is_sdl_cimport = any(s.startswith("SDL3/") for s in all_strings)

    sdl_aliases = set()
    if not is_c:
        for raw in lines:
            bare = raw.split("//", 1)[0]
            for m in DECL_IMPORT_RE.finditer(bare):
                name, target = m.group(1), m.group(2)
                base = target.rsplit("/", 1)[-1]
                if base == "sdl.zig":
                    sdl_aliases.add(name)
            if file_is_sdl_cimport:
                sdl_aliases.update(m.group(1) for m in DECL_CIMPORT_RE.finditer(bare))

    alias_use = {a: re.compile(r'(?<![\w.])' + re.escape(a) + r'\.[A-Za-z_]')
                 for a in sdl_aliases}

    hits, info = {}, []
    for lineno, (raw, (code, strings)) in enumerate(zip(lines, parsed), 1):
        cats = set()
        if is_c:
            if C_INCLUDE_SDL_RE.search(raw):
                cats.add("sdl_import")
                if rel.startswith("src/game/"):
                    cats.add("game_sdl_import")
        else:
            for m in IMPORT_RE.finditer(raw.split("//", 1)[0]):
                target = m.group(1)
                resolved = os.path.normpath(os.path.join(os.path.dirname(rel), target)).replace(os.sep, "/")
                base = os.path.basename(resolved)
                cats.update(classify_boundary_import(rel, resolved, target))
                if resolved.startswith(SDL_BACKEND_DIR) and not rel.startswith(SDL_BACKEND_DIR):
                    cats.add("sdl_import" if base == "sdl.zig" else "backend_import")
                    if rel.startswith("src/game/"):
                        cats.add("game_sdl_import")
                elif base == "sdl.zig":
                    cats.add("sdl_import")
            if "@cImport" in code and file_is_sdl_cimport:
                cats.add("sdl_import")
            if SDL_NAME_RE.search(code):
                cats.add("sdl_name")
                if rel.startswith("src/game/"):
                    cats.add("game_sdl_import")
            for a in sdl_aliases:
                if alias_use[a].search(code):
                    cats.add("sdl_name")
                    if rel.startswith("src/game/"):
                        cats.add("game_sdl_import")
        if cats:
            hits[lineno] = frozenset(cats)
        elif SDL_NAME_RE.search(" ".join(strings)):
            info.append(lineno)

    allowed, why = allowed_for(rel)
    return {"rel": rel, "is_c": is_c, "lines": lines, "hits": hits, "info": info,
            "allowed": allowed, "why": why}


def reachable_zig():
    seen, stack = set(), [ROOT / r for r in BUILD_ROOTS]
    while stack:
        p = stack.pop()
        if not p.is_file():
            continue
        rel = p.relative_to(ROOT).as_posix()
        if rel in seen:
            continue
        seen.add(rel)
        for raw in p.read_text(encoding="utf-8", errors="replace").splitlines():
            for m in IMPORT_RE.finditer(raw.split("//", 1)[0]):
                if not m.group(1).endswith(".zig"):
                    continue
                q = (p.parent / m.group(1)).resolve()
                try:
                    qrel = q.relative_to(ROOT).as_posix()
                except ValueError:
                    continue
                if qrel.startswith("src/"):
                    stack.append(q)
    return seen


# ---------------------------------------------------------------------------
# D-21 (plan section 6.2): no HarfBuzz name and no internal font-resource type on the public surface.
# Text-based: it follows the public root through its re-exports and does not compile Zig.
# ---------------------------------------------------------------------------

PUBLIC_ROOT = "src/engine/bairava.zig"
TEXT_PACKAGE = "src/engine/text/"

FONT_INTERNAL_RE = re.compile(
    r"\b(FontResource|Resources|font_resource|ui_font|Font|Fonts|Registry|font_mod)\b"
    r"|(?<!staging\.)(?<![A-Za-z0-9_])Staged\b"
)
HB_NAME_RE = re.compile(r"\b(hb_\w+|harfbuzz)\b")
HB_INCLUDE_RE = re.compile(r"#\s*include\s*[<\"][^>\"]*\bhb[^>\"]*[>\"]")

TOP_CONST_RE = re.compile(r"^(pub\s+)?const\s+(\w+)\s*=\s*(.*)$")
TOP_FN_RE = re.compile(r"^(pub\s+)?fn\s+(\w+)")
TOP_REEXPORT_RHS_RE = re.compile(
    r"^pub\s+const\s+\w+\s*=\s*(?!(?:packed\s+|extern\s+)?(?:struct|union|enum|opaque)\b)(.*);\s*$")
IMPORT_EXPR_RE = re.compile(r'@import\("([^"]+)"\)(?:\.(\w+))?')
ALIAS_RE = re.compile(r"^(\w+)\.(\w+)\s*;\s*$")
BARE_RE = re.compile(r"^(\w+)\s*;\s*$")
STRUCT_HDR_RE = re.compile(r"^\s*(pub\s+)?const\s+\w+\s*=\s*(?:packed\s+|extern\s+)?struct\b")
FN_HDR_RE = re.compile(r"^\s*(pub\s+)?fn\b")
TEST_HDR_RE = re.compile(r"^\s*test\b")
PUB_FN_RE = re.compile(r"^\s*pub\s+fn\b")
FIELD_RE = re.compile(r"^\s+(?:pub\s+)?[A-Za-z_]\w*\s*:\s*(.+?),?\s*$")

# Known D-21 exposures, as the upload stands on 2026-11-19. Each entry matches a line by its exact stripped
# text. Remove an entry when its exposure is fixed: an entry that matches nothing fails --fail as stale. A new
# exposure is not on this list, so it fails. Owner approval of this list is the open decision in the plan.
D21_DEBT = [
    ("src/engine/ui/ui.zig", 'pub const Font = @import("../text/font.zig").Font;',
     "ui.Font re-exports the BFNT Font, which holds the C ui_font"),
    ("src/engine/ui/ui.zig", "pub const Fonts = font_resource.Resources;",
     "ui.Fonts re-exports the internal font registry"),
    ("src/engine/ui/ui.zig", "fonts: *font_resource.Resources,",
     "Canvas.fonts field holds the internal font registry"),
    ("src/engine/ui/ui.zig",
     "pub fn create(allocator: std.mem.Allocator, fonts: *font_resource.Resources, font: FontHandle) Canvas {",
     "Canvas.create takes the internal font registry"),
    ("src/engine/ui/ui.zig",
     "pub fn init(allocator: std.mem.Allocator, fonts: *font_resource.Resources, font: FontHandle) Ui {",
     "Ui.init takes the internal font registry"),
    ("src/engine/core/context.zig", "fonts: *font_resource.Resources,",
     "Context.fonts field holds the internal font registry"),
    ("src/engine/core/context.zig",
     "pub fn fontOf(self: *const Context, font_handle: font_registry.FontHandle) font_registry.LookupError!*const font_resource.FontResource {",
     "Context.fontOf returns the internal FontResource"),
]


def _pairs_from_text(text, is_c=False):
    """One entry per line: (line without its // comment, code with comments and string bodies removed)."""
    out, in_block = [], False
    for raw in text.splitlines():
        if not is_c and raw.lstrip().startswith("\\\\"):  # Zig multi-line string
            out.append(("", ""))
            continue
        code, _strings, in_block = split_code(raw, is_c, in_block)
        out.append((raw.split("//", 1)[0], code))
    return out


def _pairs(path):
    return _pairs_from_text(path.read_text(encoding="utf-8", errors="replace"),
                            path.suffix in (".c", ".h"))


def _top_decls(pairs):
    """Top-level declarations: name -> (is_pub, first line index, right-hand side)."""
    decls = {}
    for i, (nc, _code) in enumerate(pairs):
        m = TOP_CONST_RE.match(nc)
        if m:
            decls.setdefault(m.group(2), (bool(m.group(1)), i, m.group(3).strip()))
            continue
        m = TOP_FN_RE.match(nc)
        if m:
            decls.setdefault(m.group(2), (bool(m.group(1)), i, ""))
    return decls


def _block_end(pairs, start):
    """Last line of the brace block that opens on or after `start`; `start` itself when no block opens."""
    depth, opened = 0, False
    for j in range(start, len(pairs)):
        for ch in pairs[j][1]:
            if ch == "{":
                depth += 1
                opened = True
            elif ch == "}":
                depth -= 1
        if opened and depth <= 0:
            return j
    return start


def _module(path, rel):
    target = (path.parent / rel).resolve()
    try:
        target.relative_to(SRC)
    except ValueError:
        return None
    return target if target.suffix == ".zig" and target.is_file() else None


def _surfaces(path, name, seen):
    """What the name `name` of the module at `path` puts on the public surface.

    Returns (kind, file, first line, last line): kind "file" for a whole module, "decl" for one declaration.
    """
    if (path, name) in seen:
        return []
    seen.add((path, name))
    pairs = _pairs(path)
    decls = _top_decls(pairs)
    if name not in decls:
        return []
    _is_pub, idx, rhs = decls[name]
    imp = IMPORT_EXPR_RE.search(rhs)
    if imp:
        target = _module(path, imp.group(1))
        if target is None:
            return []
        if imp.group(2) is None:
            return [("file", target, 0, 0)]
        return _surfaces(target, imp.group(2), seen)
    alias = ALIAS_RE.match(rhs)
    if alias and alias.group(1) in decls:
        owner_import = IMPORT_EXPR_RE.search(decls[alias.group(1)][2])
        if owner_import:
            target = _module(path, owner_import.group(1))
            return _surfaces(target, alias.group(2), seen) if target else []
        return _surfaces(path, alias.group(1), seen)
    bare = BARE_RE.match(rhs)
    if bare and bare.group(1) in decls:
        return _surfaces(path, bare.group(1), seen)
    return [("decl", path, idx, _block_end(pairs, idx))]


def public_surfaces():
    """Every surface a game can name through the public root, starting from the root's own re-exports."""
    root = ROOT / PUBLIC_ROOT
    seen = set()
    out = [("file", root, 0, 0)]
    for name, (is_pub, _idx, _rhs) in _top_decls(_pairs(root)).items():
        if is_pub:
            out += _surfaces(root, name, seen)
    return out


def _header_kind(code):
    m = STRUCT_HDR_RE.match(code)
    if m:
        return "pubstruct" if m.group(1) else "struct"
    if FN_HDR_RE.match(code):
        return "fn"
    if TEST_HDR_RE.match(code):
        return "test"
    return "other"


def _scan(kind, pairs, start, end):
    """Hits on one surface, as (line number, kind of hit, text). A "file" surface is the whole module."""
    hits, stack = [], []
    for i, (nc, code) in enumerate(pairs):
        in_scope = kind == "file" or start <= i <= end
        if in_scope and code.strip():
            structs = [k for k in stack if k in ("pubstruct", "struct")]
            innermost = structs[-1] if structs else None
            top = stack[-1] if stack else None
            text = nc.strip()
            if kind == "file":
                rhs = TOP_REEXPORT_RHS_RE.match(code)
                if rhs and FONT_INTERNAL_RE.search(rhs.group(1)):
                    hits.append((i + 1, "re-export", text))
            if PUB_FN_RE.match(code) and innermost in (None, "pubstruct") and FONT_INTERNAL_RE.search(code):
                hits.append((i + 1, "pub fn", text))
            elif top == "pubstruct":
                field = FIELD_RE.match(code)
                if field and FONT_INTERNAL_RE.search(field.group(1)):
                    hits.append((i + 1, "field", text))
        header = _header_kind(code)
        used = False
        for ch in code:
            if ch == "{":
                stack.append("other" if used else header)
                used = True
            elif ch == "}" and stack:
                stack.pop()
    return hits


def scan_public_surface():
    hits, surfaces = {}, public_surfaces()
    for kind, path, start, end in surfaces:
        rel = path.relative_to(ROOT).as_posix()
        for ln, k, text in _scan(kind, _pairs(path), start, end):
            hits.setdefault((rel, ln), (k, text))
    return hits, surfaces


def classify_d21(hits):
    debt = {(rel, text): why for rel, text, why in D21_DEBT}
    known, new, matched = [], [], set()
    for (rel, ln), (k, text) in sorted(hits.items()):
        if (rel, text) in debt:
            known.append((rel, ln, k, text, debt[(rel, text)]))
            matched.add((rel, text))
        else:
            new.append((rel, ln, k, text))
    stale = [(rel, text, why) for (rel, text), why in debt.items() if (rel, text) not in matched]
    return known, new, stale


def hb_hits_from_pairs(rel, pairs):
    hits = []
    for ln, (nc, code) in enumerate(pairs, 1):
        if HB_NAME_RE.search(code) or HB_INCLUDE_RE.search(nc):
            hits.append((rel, ln, nc.strip()))
    return hits


def scan_hb_names():
    out = []
    for p in sorted(SRC.rglob("*")):
        if not p.is_file() or p.suffix not in (".zig", ".c", ".h"):
            continue
        rel = p.relative_to(ROOT).as_posix()
        if rel.startswith(TEXT_PACKAGE):
            continue
        out += hb_hits_from_pairs(rel, _pairs(p))
    return out


def render_d21():
    """Returns (report text, new exposures, stale debt entries, HarfBuzz hits)."""
    hits, surfaces = scan_public_surface()
    known, new, stale = classify_d21(hits)
    hb = scan_hb_names()
    whole = sum(1 for s in surfaces if s[0] == "file")
    decl = len(surfaces) - whole
    out = [
        "PUBLIC SURFACE AND HARFBUZZ NAMES (D-21, plan section 6.2)",
        f"Public root {PUBLIC_ROOT}: {len(surfaces)} surface(s), {whole} whole module(s) and {decl} declaration(s).",
        f"KNOWN EXPOSURES (debt listed in D21_DEBT): {len(known)} line(s)",
    ]
    for rel, ln, k, text, why in known:
        out.append(f"  {rel}:{ln} [{k}] {text[:120]}")
        out.append(f"      {why}")
    out.append(f"NEW EXPOSURES: {len(new)}" + ("  (fails --fail)" if new else ""))
    for rel, ln, k, text in new:
        out.append(f"  {rel}:{ln} [{k}] {text[:120]}")
    out.append(f"STALE DEBT ENTRIES: {len(stale)}" + ("  (fails --fail: remove from D21_DEBT)" if stale else ""))
    for rel, text, _why in stale:
        out.append(f"  {rel}: {text[:120]}")
    out.append(f"HARFBUZZ NAMES OUTSIDE {TEXT_PACKAGE}: {len(hb)}" + ("  (fails --fail)" if hb else ""))
    for rel, ln, text in hb:
        out.append(f"  {rel}:{ln} {text[:120]}")
    out.append("")
    return "\n".join(out), new, stale, hb


def self_test_d21():
    """Runs the D-21 and HarfBuzz scans on small inline cases. Returns a list of failure messages."""
    failures = []

    def expect(label, got, want):
        if got != want:
            failures.append(f"{label}: expected lines {sorted(want)}, got {sorted(got)}")

    module = [
        'pub const Font = @import("../text/font.zig").Font;',              # 1 re-export of a forbidden name
        "pub const Fonts = font_resource.Resources;",                      # 2 re-export of a forbidden name
        "pub const FontHandle = font_registry.FontHandle;",                # 3 the handle is allowed
        "pub fn stage(prebaked: []const u8) error{InvalidFont}!Staged {",  # 4 signature names Staged
        "const Private = struct {",                                        # 5
        "    fonts: *font_resource.Resources,",                            # 6 private struct: not public
        "};",                                                              # 7
        "pub const Store = struct {",                                      # 8
        "    fonts: *font_resource.Resources,",                            # 9 public field
        "    staged: ?font.Staged = null,",                                # 10 public field
        "    pub fn fontOf(self: *const Store) *const FontResource {",     # 11 public method signature
        "        return undefined;",                                       # 12
        "    }",                                                           # 13
        "    fn helper(staged: *const staging.Staged) void {}",            # 14 private method, texture type
        "};",                                                              # 15
        "pub fn uploadStaged(staged: *const staging.Staged) void {}",     # 16 texture staging, not a font
        'test "not public" {',                                             # 17
        "    const r: Resources = undefined;",                             # 18 inside a test
        "    _ = r;",                                                      # 19
        "}",                                                               # 20
    ]
    pairs = _pairs_from_text("\n".join(module))
    expect("module surface", {ln for ln, _k, _t in _scan("file", pairs, 0, 0)}, {1, 2, 4, 9, 10, 11})
    decl_start = next(i for i, line in enumerate(module) if line.startswith("pub const Store"))
    decl_end = next(i for i in range(decl_start, len(module)) if module[i] == "};")
    expect("declaration surface",
           {ln for ln, _k, _t in _scan("decl", pairs, decl_start, decl_end)}, {9, 10, 11})

    hb_pairs = _pairs_from_text("const raw = hb_buffer_create();\n// hb_comment_only\nconst s = \"hb_text\";")
    expect("HarfBuzz call", {ln for _r, ln, _t in hb_hits_from_pairs("x.zig", hb_pairs)}, {1})
    c_pairs = _pairs_from_text("#include <hb.h>\n#include <stdio.h>", is_c=True)
    expect("HarfBuzz include", {ln for _r, ln, _t in hb_hits_from_pairs("x.c", c_pairs)}, {1})
    return failures



def counts(hits):
    out = {}
    for cats in hits.values():
        for c in cats:
            out[c] = out.get(c, 0) + 1
    return out


def fmt_counts(c):
    category_order = (
        "sdl_name", "sdl_import", "backend_import",
        "engine_game_import", "private_engine_import", "game_sdl_import",
    )
    return ", ".join(f"{k} {c[k]}" for k in category_order if k in c)


def render(results, reach):
    out = []
    total = len(results)
    zig = sum(1 for r in results if not r["is_c"])
    live_zig = sum(1 for r in results if not r["is_c"] and r["rel"] in reach)
    out.append("Platform-boundary scan (migration.md P0.5)")
    out.append(f"Scanned {total} files under src/ ({zig} .zig, {total - zig} .c/.h).")
    out.append(f"Reachable .zig from {', '.join(BUILD_ROOTS)}: {live_zig}. "
               f"Unreachable .zig: {zig - live_zig}.")
    out.append("")

    viol_files, allowed_files, dead_files, info_files = [], [], [], []
    for r in sorted(results, key=lambda r: r["rel"]):
        live = r["is_c"] or r["rel"] in reach
        allowed_hits, viol_hits = {}, {}
        for ln, cats in r["hits"].items():
            a = cats & r["allowed"]
            v = cats - r["allowed"]
            if a:
                allowed_hits[ln] = a
            if v:
                viol_hits[ln] = v
        if r["info"]:
            info_files.append(r)
        if not live and r["hits"]:
            dead_files.append(r)
        elif live and viol_hits:
            viol_files.append((r, viol_hits))
        if live and allowed_hits:
            allowed_files.append((r, allowed_hits))

    viol_lines = sum(len(v) for _, v in viol_files)
    out.append(f"REACHABLE VIOLATIONS: {viol_lines} line(s) in {len(viol_files)} file(s) (warning)")
    for r, vh in viol_files:
        out.append(f"  {r['rel']}")
        out.append(f"      {fmt_counts(counts(vh))}")
        for ln in sorted(vh):
            out.append(f"      L{ln:<5} {','.join(sorted(vh[ln])):<22} {r['lines'][ln - 1].strip()[:140]}")
    out.append("")

    out.append("ALLOWED HITS (not violations)")
    for r, ah in allowed_files:
        out.append(f"  {r['rel']}: {fmt_counts(counts(ah))}  [{r['why']}]")
    out.append("")

    out.append("UNREACHABLE FILES WITH HITS (dead code; Step 1 candidates, not warned)")
    for r in dead_files:
        out.append(f"  {r['rel']}: {fmt_counts(counts(r['hits']))}")
    out.append("")

    out.append("INFORMATION: SDL names that appear only inside string literals")
    for r in info_files:
        out.append(f"  {r['rel']}: lines {', '.join(str(x) for x in r['info'])}")
    out.append("")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fail", action="store_true", help="exit 1 when reachable violations exist")
    ap.add_argument("--report", metavar="FILE", help="also write the report to FILE")
    ap.add_argument("--self-test", action="store_true", help="run built-in negative boundary fixtures")
    args = ap.parse_args()
    if args.self_test:
        cases = [
            ("engine-game-import.zig", "src/engine/core/example.zig", "engine_game_import"),
            ("game-private-engine-import.zig", "src/game/example.zig", "private_engine_import"),
            ("game-sdl-import.zig", "src/game/example.zig", "game_sdl_import"),
        ]
        failed = False
        fixture_dir = ROOT / "scripts" / "boundary-fixtures"
        for filename, virtual_rel, expected in cases:
            fixture = fixture_dir / filename
            if not fixture.is_file():
                print(f"self-test failed: missing fixture {fixture}", file=sys.stderr)
                failed = True
                continue
            raw = fixture.read_text(encoding="utf-8")
            matches = list(IMPORT_RE.finditer(raw))
            if not matches:
                print(f"self-test failed: {filename} has no import", file=sys.stderr)
                failed = True
                continue
            target = matches[0].group(1)
            resolved = os.path.normpath(os.path.join(os.path.dirname(virtual_rel), target)).replace(os.sep, "/")
            found = classify_boundary_import(virtual_rel, resolved, target)
            if virtual_rel.startswith("src/game/") and resolved.startswith(SDL_BACKEND_DIR):
                found.add("game_sdl_import")
            if expected not in found:
                print(f"self-test failed: {filename} did not report {expected}", file=sys.stderr)
                failed = True
        for msg in self_test_d21():
            print(f"self-test failed: {msg}", file=sys.stderr)
            failed = True
        if failed:
            return 1
        print("Boundary self-test: 3/3 negative fixtures rejected; 4/4 public-surface and HarfBuzz cases as expected")
        return 0

    if not SRC.is_dir():
        print(f"error: {SRC} not found", file=sys.stderr)
        return 2

    paths = sorted(p for p in SRC.rglob("*") if p.is_file() and p.suffix in (".zig", ".c", ".h"))
    results = [scan_file(p, p.relative_to(ROOT).as_posix()) for p in paths]
    reach = reachable_zig()
    text = render(results, reach)
    d21_text, d21_new, d21_stale, d21_hb = render_d21()
    text = text + "\n" + d21_text
    print(text)
    if args.report:
        Path(args.report).write_text(text + "\n", encoding="utf-8")

    violating = [r for r in results
                 if (r["is_c"] or r["rel"] in reach) and (set().union(*r["hits"].values()) - r["allowed"]
                                                          if r["hits"] else False)]

    if os.environ.get("GITHUB_ACTIONS") == "true":
        for r in violating:
            viol = [ln for ln, cats in r["hits"].items() if cats - r["allowed"]]
            cats = sorted(set().union(*(r["hits"][ln] for ln in viol)) - r["allowed"])
            print(f"::warning file={r['rel']},line={min(viol)},title=SDL boundary::"
                  f"{len(viol)} line(s) outside the allowlist ({', '.join(cats)}). "
                  f"Full list in the job log.")

    if os.environ.get("GITHUB_ACTIONS") == "true":
        for rel, ln, k, t in d21_new:
            print(f"::warning file={rel},line={ln},title=D-21 public surface::{k}: {t}")
        for rel, ln, t in d21_hb:
            print(f"::warning file={rel},line={ln},title=HarfBuzz outside text::{t}")
    if args.fail and (violating or d21_new or d21_stale or d21_hb):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
