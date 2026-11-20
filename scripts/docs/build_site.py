#!/usr/bin/env python3
"""Assemble the curated Markdown source for the Bairava documentation site."""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urljoin, urlsplit

ROOT = Path(__file__).resolve().parents[2]
DOCS = ROOT / "docs"
OUTPUT = ROOT / "zig-out" / "doc" / "bairava"
API_SOURCE = OUTPUT / "_api_source.md"
BASEURL = "/Bairava-Engine"
RELEASE_VERSION = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")

GUIDES = (
    "getting-started.md",
    "application-lifecycle.md",
    "assets.md",
    "input.md",
    "rendering.md",
    "scenes.md",
    "ai.md",
    "animation.md",
    "asset-streaming.md",
    "audio-streaming.md",
    "build-profiles.md",
    "developer-console.md",
    "lighting.md",
    "localization.md",
    "logging.md",
    "navigation.md",
    "particles.md",
    "physics.md",
    "prefabs.md",
    "profiling.md",
    "replay.md",
    "text.md",
    "platform-capabilities.md",
)
PRIMARY_GUIDES = (
    "getting-started.md",
    "application-lifecycle.md",
    "rendering.md",
    "input.md",
    "assets.md",
    "scenes.md",
)

LINK = re.compile(r"(?<!!)\[[^\]]*\]\(([^)]+)\)")
CODE_INCLUDE = re.compile(r"<!-- include-code: ([A-Za-z0-9_./-]+) -->")
INTERNAL_PATH = re.compile(
    r"(?:src|vendor)/[A-Za-z0-9_./-]+\.(?:zig|c|h|cpp|hpp|cc|cxx|hh)\b"
)


def fail(message: str) -> None:
    raise SystemExit(f"docs site: {message}")


def source_page(name: str) -> tuple[str, str]:
    path = DOCS / name
    if not path.is_file():
        fail(f"listed documentation page does not exist: {path.relative_to(ROOT)}")
    text = path.read_text(encoding="utf-8")
    if INTERNAL_PATH.search(text):
        fail(f"public guide contains an internal source path: {path.relative_to(ROOT)}")
    text = expand_code_examples(text, path.relative_to(ROOT).as_posix())
    title_match = re.search(r"^#\s+(.+?)\s*$", text, re.MULTILINE)
    if title_match is None:
        fail(f"page has no top-level heading: {path.relative_to(ROOT)}")
    return title_match.group(1), text


def expand_code_examples(text: str, current_name: str) -> str:
    def replace(match: re.Match[str]) -> str:
        relative = Path(match.group(1))
        example_root = (ROOT / "examples").resolve()
        example = (ROOT / relative).resolve()
        if not example.is_relative_to(example_root) or not example.is_file():
            fail(f"invalid or missing code example in {current_name}: {relative}")
        source = example.read_text(encoding="utf-8")
        if INTERNAL_PATH.search(source):
            fail(f"public example contains an internal source path: {relative}")
        return "```zig\n" + source.rstrip() + "\n```"

    return CODE_INCLUDE.sub(replace, text)


def rewrite_links(text: str, current_name: str, known_pages: set[str]) -> str:
    def replace(match: re.Match[str]) -> str:
        target = match.group(1)
        if target.startswith(("https://", "http://", "mailto:", "#", "/")):
            return match.group(0)
        file_part, separator, fragment = target.partition("#")
        if not file_part:
            return match.group(0)
        if file_part.endswith(".md"):
            stem = Path(file_part).name
            if stem not in known_pages:
                fail(f"broken or excluded guide link in {current_name}: {target}")
            target = str(Path(file_part).with_suffix(".html")).replace("\\", "/")
            if separator:
                target += "#" + fragment
            return match.group(0).replace(match.group(1), target)
        if separator and file_part:
            return match.group(0)
        return match.group(0)

    return LINK.sub(replace, text)


def add_front_matter(title: str, permalink: str, body: str) -> str:
    return (
        "---\n"
        f"title: {json.dumps(title, ensure_ascii=False)}\n"
        f"permalink: {permalink}\n"
        "layout: default\n"
        "---\n\n"
        + body
    )


def parse_engine_version(package_data: str, source: str) -> str:
    package_match = re.search(r'\.version\s*=\s*"(\d+\.\d+\.\d+)"', package_data)
    source_match = re.search(
        r"pub const version: Version = \.\{\s*\.major = (\d+),\s*\.minor = (\d+),\s*\.patch = (\d+)\s*\}",
        source,
    )
    if package_match is None or source_match is None:
        fail("could not read package/API version metadata")
    package_version = package_match.group(1)
    source_version = ".".join(source_match.groups())
    if package_version != source_version:
        fail(f"package version {package_version} differs from API version {source_version}")
    return package_version


class LocalLinkParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.links: list[str] = []
        self.ids: set[str] = set()

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = dict(attrs)
        for key in ("href", "src"):
            value = values.get(key)
            if value:
                self.links.append(value)
        element_id = values.get("id")
        if element_id:
            self.ids.add(element_id)


def validate_rendered_site(site_root: Path, baseurl: str = BASEURL) -> None:
    site_root = site_root.resolve()
    required_pages = ("index.html", "api/index.html", "404.html")
    for relative in required_pages:
        if not (site_root / relative).is_file():
            fail(f"rendered site is missing {relative}")

    text_extensions = {".css", ".html", ".js", ".json", ".md", ".txt", ".xml"}
    for path in site_root.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in text_extensions:
            continue
        text = path.read_text(encoding="utf-8")
        if INTERNAL_PATH.search(text) or any(term in text for term in ("core.engine.", "src/engine/", "src/game/", "test_fixtures.zig")):
            fail(f"internal implementation detail leaked into rendered {path.relative_to(site_root)}")

    html_files = sorted(site_root.rglob("*.html"))
    parsed_pages: dict[Path, LocalLinkParser] = {}
    for path in html_files:
        parser = LocalLinkParser()
        text = path.read_text(encoding="utf-8")
        parser.feed(text)
        parsed_pages[path] = parser

    for source, parser in parsed_pages.items():
        source_url = "/" + source.relative_to(site_root).as_posix()
        for link in parser.links:
            target = urlsplit(urljoin(source_url, link))
            if target.scheme or target.netloc:
                continue
            target_path = unquote(target.path)
            if baseurl and (target_path == baseurl or target_path.startswith(baseurl + "/")):
                target_path = target_path[len(baseurl) :]
            resolved = (site_root / target_path.lstrip("/")).resolve()
            if not resolved.is_relative_to(site_root):
                fail(f"rendered link escapes site output in {source.relative_to(site_root)}: {link}")
            if resolved.is_dir():
                resolved = resolved / "index.html"
            if not resolved.is_file():
                fail(f"broken rendered link in {source.relative_to(site_root)}: {link}")
            if target.fragment and resolved.suffix == ".html":
                destination = parsed_pages.get(resolved)
                if destination is None:
                    destination = LocalLinkParser()
                    destination.feed(resolved.read_text(encoding="utf-8"))
                    parsed_pages[resolved] = destination
                if unquote(target.fragment) not in destination.ids:
                    fail(f"broken rendered anchor in {source.relative_to(site_root)}: {link}")

    search_path = site_root / "search-index.json"
    if not search_path.is_file():
        fail("rendered site is missing search-index.json")
    try:
        search_pages = json.loads(search_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        fail(f"rendered search index is invalid JSON: {error}")
    if not isinstance(search_pages, list):
        fail("rendered search index must be a list")
    for page in search_pages:
        if not isinstance(page, dict) or not isinstance(page.get("url"), str):
            fail("rendered search index contains an invalid page entry")
        target = urlsplit(urljoin("/index.html", page["url"]))
        target_path = unquote(target.path)
        if baseurl and (target_path == baseurl or target_path.startswith(baseurl + "/")):
            target_path = target_path[len(baseurl) :]
        resolved = (site_root / target_path.lstrip("/")).resolve()
        if not resolved.is_relative_to(site_root):
            fail(f"search index page escapes site output: {page['url']}")
        if resolved.is_dir():
            resolved = resolved / "index.html"
        if not resolved.is_file():
            fail(f"search index points to a missing page: {page['url']}")


def validate_publication(site_root: Path) -> None:
    site_root = site_root.resolve()
    root_index = site_root / "index.html"
    if not root_index.is_file():
        fail("published site is missing its version selector")
    parser = LocalLinkParser()
    parser.feed(root_index.read_text(encoding="utf-8"))
    for link in parser.links:
        target = urlsplit(urljoin("/index.html", link))
        if target.scheme or target.netloc:
            continue
        target_path = unquote(target.path)
        if target_path == BASEURL or target_path.startswith(BASEURL + "/"):
            target_path = target_path[len(BASEURL) :]
        resolved = (site_root / target_path.lstrip("/")).resolve()
        if not resolved.is_relative_to(site_root):
            fail(f"version selector link escapes site output: {link}")
        if resolved.is_dir():
            resolved /= "index.html"
        if not resolved.is_file():
            fail(f"version selector points to a missing page: {link}")

    variants = [
        path for path in site_root.iterdir()
        if path.is_dir() and (path.name in ("dev", "latest") or RELEASE_VERSION.fullmatch(path.name))
    ]
    if not variants:
        fail("published site contains no documentation versions")
    for path in variants:
        validate_rendered_site(path, f"{BASEURL}/{path.name}")


def clear_generated_site() -> None:
    for relative in (
        "api",
        "guides",
        "assets",
        "_layouts",
        "_data",
        "index.md",
        "search-index.json",
        "404.md",
        "license.md",
        "_config.yml",
    ):
        path = OUTPUT / relative
        if path.is_dir():
            shutil.rmtree(path)
        elif path.exists():
            path.unlink()


def main() -> None:
    if not API_SOURCE.is_file():
        fail("generated API reference is missing; run the Zig API exporter first")

    clear_generated_site()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    (OUTPUT / "guides").mkdir(exist_ok=True)
    api_dir = OUTPUT / "api"
    api_dir.mkdir(exist_ok=True)
    (api_dir / "index.md").write_text(
        add_front_matter("Public API", "/api/", API_SOURCE.read_text(encoding="utf-8")),
        encoding="utf-8",
    )

    page_names = set(GUIDES)
    page_names.add("api.md")
    pages: list[dict[str, str]] = []
    for filename in GUIDES:
        title, body = source_page(filename)
        body = rewrite_links(body, filename, page_names)
        route = f"/guides/{Path(filename).stem}.html"
        (OUTPUT / "guides" / filename).write_text(
            add_front_matter(title, route, body),
            encoding="utf-8",
        )
        plain = re.sub(r"```.*?```", " ", body, flags=re.DOTALL)
        plain = re.sub(r"<[^>]+>", " ", plain)
        plain = re.sub(r"[`*_#>|]", " ", plain)
        pages.append(
            {
                "title": title,
                "url": route,
                "text": re.sub(r"\s+", " ", plain).strip(),
            }
        )

    api_text = API_SOURCE.read_text(encoding="utf-8")
    api_plain = re.sub(r"[`*_#>|]", " ", api_text)
    pages.append(
        {
            "title": "Public API",
            "url": "/api/",
            "text": re.sub(r"\s+", " ", api_plain).strip(),
        }
    )

    index = (
        "# Bairava Engine Documentation\n\n"
        "Bairava is an experimental 2D game engine written in Zig. These guides describe current "
        "behavior; the generated reference lists the canonical exports from `@import(\"bairava\")`.\n\n"
        "## Start here\n\n"
        "- [Getting started](guides/getting-started.html)\n"
        "- [Public API reference](api/)\n"
        "- [Sample game source](https://github.com/ash5me/Bairava-Engine/tree/main/sample)\n\n"
        "The engine API is in early development and is not production-ready. "
        "The getting-started guide uses the repository's public-API sample.\n\n"
        "## Guides\n\n"
        + "".join(f"- [{page['title']}]({page['url'].removeprefix('/')})\n" for page in pages[:-1])
        + "\n"
        "<label for=\"doc-search\">Search documentation</label>\n\n"
        "<input id=\"doc-search\" type=\"search\" autocomplete=\"off\" "
        "aria-describedby=\"search-results\" placeholder=\"Search guides and API\">\n\n"
        "<ul id=\"search-results\" aria-live=\"polite\"></ul>\n"
    )
    (OUTPUT / "index.md").write_text(
        add_front_matter("Bairava Engine Documentation", "/", index),
        encoding="utf-8",
    )

    search_path = OUTPUT / "search-index.json"
    search_path.write_text(json.dumps(pages, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")

    site_data = OUTPUT / "_data"
    site_data.mkdir(exist_ok=True)
    zig_version = subprocess.run(
        ["zig", "version"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    if not zig_version:
        fail("zig version command returned no version")
    source_commit = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    engine_version = parse_engine_version(
        (ROOT / "build.zig.zon").read_text(encoding="utf-8"),
        (ROOT / "src" / "engine" / "version.zig").read_text(encoding="utf-8"),
    )
    (site_data / "site.json").write_text(
        json.dumps(
            {
                "engine_version": engine_version,
                "zig_version": zig_version,
                "source_commit": source_commit,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    page_by_name = {
        filename: page for filename, page in zip(GUIDES, pages[: len(GUIDES)])
    }
    nav = [{"title": "Home", "url": "/"}, {"title": "API reference", "url": "/api/"}]
    nav.extend(
        {"title": page_by_name[filename]["title"], "url": page_by_name[filename]["url"]}
        for filename in PRIMARY_GUIDES
    )
    (site_data / "navigation.json").write_text(json.dumps(nav, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    for source, target in (
        (DOCS / "site" / "_config.yml", OUTPUT / "_config.yml"),
        (DOCS / "site" / "assets", OUTPUT / "assets"),
        (DOCS / "site" / "_layouts", OUTPUT / "_layouts"),
        (DOCS / "site" / "404.md", OUTPUT / "404.md"),
        (DOCS / "LICENSE.md", OUTPUT / "license.md"),
    ):
        if source.is_dir():
            shutil.copytree(source, target, dirs_exist_ok=True)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)

    blocked = ("core.engine.", "src/engine/", "src/game/", "test_fixtures.zig")
    for path in OUTPUT.rglob("*"):
        if not path.is_file():
            continue
        if path.suffix not in {".md", ".json", ".js", ".css", ".html", ".yml"}:
            fail(f"unexpected non-text artifact in public site: {path.relative_to(OUTPUT)}")
        text = path.read_text(encoding="utf-8")
        if INTERNAL_PATH.search(text) or any(term in text for term in blocked):
            fail(f"internal implementation detail leaked into {path.relative_to(OUTPUT)}")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--check-rendered":
        validate_rendered_site(Path(sys.argv[2]))
    elif len(sys.argv) == 5 and sys.argv[1] == "--check-rendered" and sys.argv[3] == "--baseurl":
        validate_rendered_site(Path(sys.argv[2]), sys.argv[4])
    elif len(sys.argv) == 3 and sys.argv[1] == "--check-publication":
        validate_publication(Path(sys.argv[2]))
    elif len(sys.argv) == 1:
        main()
    else:
        fail("usage: build_site.py [--check-rendered SITE_DIRECTORY [--baseurl BASEURL] | --check-publication SITE_DIRECTORY]")
