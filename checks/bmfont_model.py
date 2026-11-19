"""Reference model of src/engine/text/bmfont.zig and src/engine/assets/bmfont_check.zig, run on the Zig test cases.

This checks the algorithm and the test expectations against each other. It does not compile or run the Zig code, so it is
supporting evidence only. It does not close any environment gate (plan section 6.4).

Run from the repository root:  python3 checks/bmfont_model.py
"""
import re
import sys

MAX_CODEPOINT = 0x10FFFF
DEFAULT_FALLBACK = ord("?")
MAX_CHANNEL = 15
MAX_FIELDS = 32
SCHEMA_VERSION = 1


class Err(Exception):
    def __init__(self, name, line=0, **diag):
        super().__init__(name)
        self.name = name
        self.line = line
        self.diag = diag


def parse_int(value):
    if not re.fullmatch(r"[+-]?[0-9]+", value):
        raise Err("BadValue")
    n = int(value)
    if not (-(2**31) <= n < 2**31):
        raise Err("BadValue")
    return n


def parse_u32(value):
    n = parse_int(value)
    if n < 0:
        raise Err("BadValue")
    return n


def parse_list4(value):
    parts = value.split(",")
    if len(parts) != 4:
        raise Err("BadValue")
    return [parse_u32(p) for p in parts]


def split_fields(rest):
    fields = []
    i = 0
    n = len(rest)
    while True:
        while i < n and rest[i] in " \t":
            i += 1
        if i == n:
            break
        eq = rest.find("=", i)
        if eq < 0:
            raise Err("MalformedLine")
        key = rest[i:eq]
        if key == "" or any(c in key for c in " \t"):
            raise Err("MalformedLine")
        i = eq + 1
        if i < n and rest[i] == '"':
            close = rest.find('"', i + 1)
            if close < 0:
                raise Err("MalformedLine")
            value = rest[i + 1:close]
            i = close + 1
        else:
            end = i
            while end < n and rest[end] not in " \t":
                end += 1
            value = rest[i:end]
            i = end
        fields.append((key, value))
        if len(fields) > MAX_FIELDS:
            raise Err("MalformedLine")
    return fields


def find(fields, key):
    for k, v in fields:
        if k == key:
            return v
    return None


def required(fields, key):
    v = find(fields, key)
    if v is None:
        raise Err("MissingKey")
    return v


def is_codepoint(v):
    return v <= MAX_CODEPOINT and not (0xD800 <= v <= 0xDFFF)


def glyph_index(glyphs, cp):
    lo, hi = 0, len(glyphs)
    while lo < hi:
        mid = lo + (hi - lo) // 2
        if glyphs[mid]["codepoint"] < cp:
            lo = mid + 1
        else:
            hi = mid
    if lo < len(glyphs) and glyphs[lo]["codepoint"] == cp:
        return lo
    return None


def unmapped_of(glyphs, first, second):
    if glyph_index(glyphs, first) is None:
        return first
    if glyph_index(glyphs, second) is None:
        return second
    return None


class Builder:
    def __init__(self):
        self.size = None
        self.padding = [0, 0, 0, 0]
        self.line_height = None
        self.base = 0
        self.scale_w = 0
        self.scale_h = 0
        self.pages_declared = None
        self.chars_declared = None
        self.kernings_declared = None
        self.pages = []
        self.glyphs = []
        self.kernings = []  # each: {"first", "second", "amount", "line"}

    def add_line(self, line, line_number):
        tag_end = len(line)
        for idx, c in enumerate(line):
            if c in " \t":
                tag_end = idx
                break
        tag = line[:tag_end]
        fields = split_fields(line[tag_end:])
        handlers = {
            "info": self.info,
            "common": self.common,
            "page": self.page,
            "chars": self.chars_count,
            "char": self.char,
            "kernings": self.kernings_count,
            "kerning": lambda f: self.kerning(f, line_number),
        }
        if tag not in handlers:
            raise Err("UnknownTag")
        handlers[tag](fields)

    def info(self, f):
        if self.size is not None:
            raise Err("DuplicateSection")
        self.size = parse_int(required(f, "size"))
        pad = find(f, "padding")
        if pad is not None:
            self.padding = parse_list4(pad)

    def common(self, f):
        if self.line_height is not None:
            raise Err("DuplicateSection")
        line_height = parse_u32(required(f, "lineHeight"))
        base = parse_u32(required(f, "base"))
        scale_w = parse_u32(required(f, "scaleW"))
        scale_h = parse_u32(required(f, "scaleH"))
        pages = parse_u32(required(f, "pages"))
        if line_height == 0 or base > line_height or scale_w == 0 or scale_h == 0 or pages == 0:
            raise Err("BadValue")
        self.line_height, self.base, self.scale_w, self.scale_h, self.pages_declared = (
            line_height, base, scale_w, scale_h, pages)

    def page(self, f):
        pid = parse_u32(required(f, "id"))
        file = required(f, "file")
        if file == "":
            raise Err("BadValue")
        self.pages.append({"id": pid, "file": file})

    def chars_count(self, f):
        if self.chars_declared is not None:
            raise Err("DuplicateSection")
        self.chars_declared = parse_u32(required(f, "count"))

    def char(self, f):
        cid = parse_int(required(f, "id"))
        if cid < 0:
            raise Err("InvalidCodepoint")
        chnl = find(f, "chnl")
        channel = parse_u32(chnl) if chnl is not None else MAX_CHANNEL
        if channel > MAX_CHANNEL:
            raise Err("BadValue")
        self.glyphs.append({
            "codepoint": cid,
            "x": parse_u32(required(f, "x")),
            "y": parse_u32(required(f, "y")),
            "width": parse_u32(required(f, "width")),
            "height": parse_u32(required(f, "height")),
            "x_offset": parse_int(required(f, "xoffset")),
            "y_offset": parse_int(required(f, "yoffset")),
            "x_advance": parse_u32(required(f, "xadvance")),
            "page": parse_u32(required(f, "page")),
            "channel": channel,
        })

    def kernings_count(self, f):
        if self.kernings_declared is not None:
            raise Err("DuplicateSection")
        self.kernings_declared = parse_u32(required(f, "count"))

    def kerning(self, f, line_number):
        first = parse_int(required(f, "first"))
        second = parse_int(required(f, "second"))
        if first < 0 or second < 0:
            raise Err("InvalidCodepoint")
        amount = parse_int(required(f, "amount"))
        self.kernings.append({"first": first, "second": second, "amount": amount, "line": line_number})

    def finish(self, fallback):
        if self.line_height is None or self.size is None or self.pages_declared is None or self.chars_declared is None:
            raise Err("MissingSection")
        if len(self.pages) == 0:
            raise Err("MissingSection")
        page_count = len(self.pages)
        if page_count != self.pages_declared:
            raise Err("CountMismatch")
        if len(self.glyphs) != self.chars_declared:
            raise Err("CountMismatch")
        if self.kernings_declared is not None and len(self.kernings) != self.kernings_declared:
            raise Err("CountMismatch")

        for index, page in enumerate(self.pages):
            if page["id"] >= page_count:
                raise Err("PageOutOfRange")
            for earlier in self.pages[:index]:
                if earlier["id"] == page["id"]:
                    raise Err("DuplicatePage")
        for g in self.glyphs:
            if not is_codepoint(g["codepoint"]):
                raise Err("InvalidCodepoint")
            if g["page"] >= page_count:
                raise Err("PageOutOfRange")
            if g["x"] + g["width"] > self.scale_w or g["y"] + g["height"] > self.scale_h:
                raise Err("GlyphOutsideAtlas")
        for k in self.kernings:
            if not is_codepoint(k["first"]) or not is_codepoint(k["second"]):
                raise Err("InvalidCodepoint")

        glyphs = sorted((dict(g) for g in self.glyphs), key=lambda g: g["codepoint"])
        for i in range(1, len(glyphs)):
            if glyphs[i]["codepoint"] == glyphs[i - 1]["codepoint"]:
                raise Err("DuplicateCodepoint")
        if glyph_index(glyphs, fallback) is None:
            raise Err("MissingFallback")

        # Unmapped pairs, in file order.
        for k in self.kernings:
            missing = unmapped_of(glyphs, k["first"], k["second"])
            if missing is not None:
                raise Err("UnmappedKerning", k["line"], kerning_first=k["first"],
                          kerning_second=k["second"], unmapped_id=missing)
        # Duplicates, after sorting by (first, second, line): the later line is the one named.
        pending = sorted((dict(k) for k in self.kernings), key=lambda k: (k["first"], k["second"], k["line"]))
        for i in range(1, len(pending)):
            a, b = pending[i - 1], pending[i]
            if a["first"] == b["first"] and a["second"] == b["second"]:
                raise Err("DuplicateKerning", b["line"], kerning_first=b["first"], kerning_second=b["second"])
        kernings = [{"first": k["first"], "second": k["second"], "amount": k["amount"]} for k in pending]

        pages = sorted((dict(p) for p in self.pages), key=lambda p: p["id"])
        return {
            "schema_version": SCHEMA_VERSION,
            "size": self.size,
            "line_height": self.line_height,
            "base": self.base,
            "scale_w": self.scale_w,
            "scale_h": self.scale_h,
            "padding": self.padding,
            "pages": pages,
            "glyphs": glyphs,
            "kernings": kernings,
            "fallback": fallback,
        }


def parse(text, fallback=DEFAULT_FALLBACK):
    b = Builder()
    line_no = 0
    try:
        for raw in text.split("\n"):
            line_no += 1
            line = raw.strip(" \t\r")
            if line == "":
                continue
            try:
                b.add_line(line, line_no)
            except Err as e:
                e.line = line_no
                raise
    except Err:
        raise
    return b.finish(fallback)


def glyph_for(font, cp):
    i = glyph_index(font["glyphs"], cp)
    return None if i is None else font["glyphs"][i]


def kerning_for(font, first, second):
    for k in font["kernings"]:
        if k["first"] == first and k["second"] == second:
            return k["amount"]
    return 0


# ---- the same strings as bmfont.zig's tests -------------------------------------------------------------------------
INFO = 'info face="Test Face" size=8 bold=0 italic=0 charset="" unicode=1 stretchH=100 smooth=0 aa=1 padding=0,0,0,0 spacing=1,1 outline=0\n'
COMMON = "common lineHeight=8 base=7 scaleW=128 scaleH=48 pages=1 packed=0 alphaChnl=1 redChnl=0 greenChnl=0 blueChnl=0\n"
PAGE = 'page id=0 file="ui font 8px.png"\n'
SPACE = "char id=32 x=0 y=0 width=0 height=0 xoffset=0 yoffset=0 xadvance=8 page=0 chnl=15\n"
QUESTION = "char id=63 x=8 y=0 width=8 height=8 xoffset=0 yoffset=0 xadvance=8 page=0 chnl=15\n"
A = "char id=65 x=16 y=0 width=8 height=8 xoffset=0 yoffset=0 xadvance=8 page=0 chnl=15\n"
CHARS = "chars count=3\n" + SPACE + QUESTION + A
KERN = "kernings count=1\nkerning first=65 second=65 amount=-1\n"
GOOD = INFO + COMMON + PAGE + CHARS + KERN


def check(cond, msg, failures):
    if not cond:
        failures.append(msg)


def ok_parses_fields(failures):
    f = parse(GOOD)
    check(f["size"] == 8, "size", failures)
    check(f["line_height"] == 8, "line_height", failures)
    check(f["base"] == 7, "base", failures)
    check(f["scale_w"] == 128 and f["scale_h"] == 48, "scale", failures)
    check(len(f["pages"]) == 1 and f["pages"][0]["file"] == "ui font 8px.png", "page file", failures)
    check(len(f["glyphs"]) == 3, "glyph count", failures)
    check(f["fallback"] == 63, "fallback", failures)


def ok_lookup(failures):
    f = parse(GOOD)
    a = glyph_for(f, ord("A"))
    check(a is not None and a["x"] == 16 and a["width"] == 8, "A glyph", failures)
    sp = glyph_for(f, ord(" "))
    check(sp is not None and sp["width"] == 0 and sp["x_advance"] == 8, "space keeps advance", failures)
    check(glyph_for(f, ord("B")) is None, "B unmapped", failures)
    check(kerning_for(f, 65, 65) == -1, "A-A kerning", failures)
    check(kerning_for(f, 65, 63) == 0, "A-? no kerning", failures)


def ok_line_order(failures):
    f = parse(CHARS + KERN + INFO + COMMON + PAGE)
    check(len(f["glyphs"]) == 3, "reordered glyph count", failures)
    check(kerning_for(f, 65, 65) == -1, "reordered kerning", failures)


def ok_schema(failures):
    f = parse(GOOD)
    check(f["schema_version"] == 1, "schema version is 1", failures)


def expect_error(text, name, failures, fallback=DEFAULT_FALLBACK, line=None, **diag):
    try:
        parse(text, fallback)
    except Err as e:
        if e.name != name:
            failures.append(f"expected {name}, got {e.name}")
            return
        if line is not None and e.line != line:
            failures.append(f"{name}: expected line {line}, got {e.line}")
        for key, want in diag.items():
            got = e.diag.get(key)
            if got != want:
                failures.append(f"{name}: expected {key}={want}, got {got}")
        return
    failures.append(f"expected {name}, but parse succeeded")


CASES = [
    ("descriptor parses into fields, pages, glyphs, kerning", ok_parses_fields),
    ("glyphs found by codepoint, kerning by pair", ok_lookup),
    ("line order does not change the result", ok_line_order),
    ("normalized font carries schema version 1", ok_schema),
    ("no page is rejected", lambda fl: expect_error(INFO + COMMON + CHARS, "MissingSection", fl)),
    ("no info or common is rejected", lambda fl: expect_error(PAGE + CHARS, "MissingSection", fl)),
    ("glyph outside atlas is rejected", lambda fl: expect_error(
        INFO + COMMON + PAGE + "chars count=3\n" + SPACE + QUESTION +
        "char id=65 x=124 y=0 width=8 height=8 xoffset=0 yoffset=0 xadvance=8 page=0 chnl=15\n",
        "GlyphOutsideAtlas", fl)),
    ("glyph on missing page is rejected", lambda fl: expect_error(
        INFO + COMMON + PAGE + "chars count=3\n" + SPACE + QUESTION +
        "char id=65 x=16 y=0 width=8 height=8 xoffset=0 yoffset=0 xadvance=8 page=1 chnl=15\n",
        "PageOutOfRange", fl)),
    ("duplicate codepoint is rejected", lambda fl: expect_error(
        INFO + COMMON + PAGE + "chars count=3\n" + SPACE + QUESTION + QUESTION, "DuplicateCodepoint", fl)),
    ("count mismatch is rejected", lambda fl: expect_error(
        INFO + COMMON + PAGE + "chars count=4\n" + SPACE + QUESTION + A, "CountMismatch", fl)),
    ("missing fallback is rejected", lambda fl: expect_error(GOOD, "MissingFallback", fl, fallback=ord("Z"))),
    ("unmapped kerning: diagnostic names pair, line 9, missing id 66", lambda fl: expect_error(
        INFO + COMMON + PAGE + CHARS + "kernings count=1\nkerning first=65 second=66 amount=-1\n",
        "UnmappedKerning", fl, line=9, kerning_first=65, kerning_second=66, unmapped_id=66)),
    ("both kerning glyphs unmapped: the first is named", lambda fl: expect_error(
        INFO + COMMON + PAGE + CHARS + "kernings count=1\nkerning first=66 second=67 amount=-1\n",
        "UnmappedKerning", fl, unmapped_id=66)),
    ("duplicate kerning: diagnostic names the later line, 10", lambda fl: expect_error(
        INFO + COMMON + PAGE + CHARS + "kernings count=2\n" +
        "kerning first=65 second=65 amount=-1\nkerning first=65 second=65 amount=-1\n",
        "DuplicateKerning", fl, line=10, kerning_first=65)),
    ("unknown tag is rejected, diagnostic names line 10", lambda fl: expect_error(
        GOOD + "bogus x=1\n", "UnknownTag", fl, line=10)),
    ("value that does not parse is rejected", lambda fl: expect_error(
        INFO + COMMON + PAGE + "chars count=1\n" +
        "char id=65 x= y=0 width=8 height=8 xoffset=0 yoffset=0 xadvance=8 page=0\n",
        "BadValue", fl)),
    ("unclosed quote is malformed", lambda fl: expect_error(
        INFO + COMMON + 'page id=0 file="open.png\n', "MalformedLine", fl)),
    ("base past line height is rejected", lambda fl: expect_error(
        INFO + "common lineHeight=8 base=9 scaleW=128 scaleH=48 pages=1\n" + PAGE + CHARS, "BadValue", fl)),
    ("surrogate codepoint is rejected", lambda fl: expect_error(
        INFO + COMMON + PAGE + "chars count=1\n" +
        "char id=55296 x=0 y=0 width=0 height=0 xoffset=0 yoffset=0 xadvance=0 page=0\n",
        "InvalidCodepoint", fl)),
]



# ---- page and descriptor checks, mirroring src/engine/assets/bmfont_check.zig ---------------------------------------

def check_descriptor(text, page_images):
    """Returns the (line, message-key) issues a descriptor produces, in the order the Zig check reports them."""
    issues = []
    try:
        font = parse(text)
    except Err as e:
        if e.name == "UnmappedKerning":
            issues.append((e.line, f"kerning pair {e.diag['kerning_first']} {e.diag['kerning_second']} "
                                   f"names glyph {e.diag['unmapped_id']}, which the font does not map"))
        else:
            issues.append((e.line, e.name))
        return issues
    if len(page_images) != len(font["pages"]):
        issues.append((0, "page count"))
        return issues
    for page, image in zip(font["pages"], page_images):
        if image is None:
            issues.append((0, f"the image for page {page['id']} is missing or is not a PNG"))
        elif image != (font["scale_w"], font["scale_h"]):
            issues.append((0, f"page {page['id']} is {image[0]}x{image[1]}, but scaleW and scaleH give "
                              f"{font['scale_w']}x{font['scale_h']}"))
    return issues


CHECK_DESCRIPTOR = ("info size=8\ncommon lineHeight=8 base=7 scaleW=128 scaleH=48 pages=1\n"
                    'page id=0 file="p.png"\nchars count=1\n'
                    "char id=63 x=0 y=0 width=8 height=8 xoffset=0 yoffset=0 xadvance=8 page=0\n")


def check_cases(failures_list):
    d = CHECK_DESCRIPTOR
    fail = []
    issues = check_descriptor(d, [(128, 48)])
    check(issues == [], "matching page passes", fail)
    issues = check_descriptor(d, [(256, 48)])
    check(len(issues) == 1 and "page 0" in issues[0][1], "wrong size names page 0", fail)
    issues = check_descriptor(d, [None])
    check(len(issues) == 1, "missing image reported", fail)
    issues = check_descriptor(d, [(128, 48), (128, 48)])
    check(len(issues) == 1, "page count mismatch reported", fail)
    issues = check_descriptor(d + "kernings count=1\nkerning first=63 second=66 amount=-1\n", [(128, 48)])
    check(len(issues) == 1 and issues[0][0] == 7, "unmapped kerning on line 7", fail)
    check(len(issues) == 1 and "kerning pair 63 66" in issues[0][1] and "names glyph 66" in issues[0][1],
          "unmapped kerning message names pair and id", fail)
    issues = check_descriptor("info size=8\nbogus x=1\n", [(128, 48)])
    check(len(issues) == 1 and issues[0][0] == 2, "malformed line 2", fail)
    failures_list.extend(fail)


CASES += [
    ("page checks: matching size, wrong size, missing image, count mismatch, unmapped kerning, malformed line",
     check_cases),
]


def main():
    passed = 0
    for name, fn in CASES:
        failures = []
        fn(failures)
        if failures:
            print(f"FAIL {name}: " + "; ".join(failures))
        else:
            passed += 1
            print(f"PASS {name}")
    print(f"{passed} of {len(CASES)} cases pass")
    return 0 if passed == len(CASES) else 1


if __name__ == "__main__":
    sys.exit(main())
