#!/usr/bin/env python3
"""Prepare versioned GitHub Pages sources while preserving published snapshots."""

from __future__ import annotations

import argparse
import json
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VERSION = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
TAG = re.compile(r"^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
BASE = "/Bairava-Engine"


def fail(message: str) -> None:
    raise SystemExit(f"docs publish: {message}")


def read_metadata(directory: Path) -> dict[str, str]:
    path = directory / "_data" / "site.json"
    if not path.is_file():
        fail(f"published site metadata is missing: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        fail(f"invalid published site metadata in {path}: {error}")
    if not isinstance(value, dict):
        fail(f"published site metadata must be an object: {path}")
    for key in ("engine_version", "source_commit"):
        if not isinstance(value.get(key), str) or not value[key]:
            fail(f"published site metadata has no {key}: {path}")
    return value


def prepare_variant(source: Path, sources: Path, name: str, baseurl: str) -> None:
    destination = sources / name
    shutil.copytree(source, destination)
    config = destination / "_config.yml"
    text = config.read_text(encoding="utf-8")
    updated, count = re.subn(r"(?m)^baseurl:\s*.*$", f"baseurl: {baseurl}", text)
    if count != 1:
        fail(f"expected one baseurl setting in {config}")
    config.write_text(updated, encoding="utf-8")


def write_root_index(site_root: Path, versions: set[str], include_dev: bool, include_latest: bool) -> None:
    links: list[tuple[str, str]] = []
    if include_dev:
        links.append(("Development", f"{BASE}/dev/"))
    if include_latest:
        links.append(("Latest release", f"{BASE}/latest/"))
    links.extend(
        (version, f"{BASE}/{version}/")
        for version in sorted(versions, key=lambda value: tuple(map(int, value.split("."))), reverse=True)
    )
    items = "\n".join(f'<li><a href="{href}">{label}</a></li>' for label, href in links)
    (site_root / "index.html").write_text(
        "<!doctype html>\n"
        '<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">'
        "<title>Bairava Engine Documentation</title>"
        "<body><main><h1>Bairava Engine Documentation</h1>"
        f"<p>Select documentation for a specific development or release version.</p><ul>{items}</ul>"
        "</main></body></html>\n",
        encoding="utf-8",
    )


def prepare(
    source: Path,
    archive: Path,
    sources: Path,
    site_root: Path,
    ref_type: str,
    ref_name: str,
) -> dict[str, str]:
    metadata = read_metadata(source)
    engine_version = metadata["engine_version"]
    source_commit = metadata["source_commit"]
    if not re.fullmatch(r"[0-9a-f]{40}", source_commit):
        fail("source commit must be a full Git commit hash")

    shutil.rmtree(sources, ignore_errors=True)
    sources.mkdir(parents=True)
    shutil.rmtree(site_root, ignore_errors=True)
    if archive.is_dir():
        shutil.copytree(archive, site_root)
    else:
        site_root.mkdir(parents=True)

    versions = {
        child.name
        for child in site_root.iterdir()
        if child.is_dir() and VERSION.fullmatch(child.name)
    }
    outputs = {"build_dev": "false", "build_release": "false", "build_latest": "false"}
    include_dev = (site_root / "dev").is_dir()
    include_latest = (site_root / "latest").is_dir()

    if ref_type == "branch" and ref_name == "main":
        prepare_variant(source, sources, "dev", f"{BASE}/dev")
        outputs["build_dev"] = "true"
        include_dev = True
    elif ref_type == "tag":
        tag_match = TAG.fullmatch(ref_name)
        if tag_match is None:
            fail(f"release tag must use vMAJOR.MINOR.PATCH form: {ref_name}")
        tag_version = ".".join(tag_match.groups())
        if tag_version != engine_version:
            fail(f"release tag {ref_name} does not match package/API version {engine_version}")

        release_path = site_root / tag_version
        if release_path.exists():
            old_metadata = read_metadata(release_path)
            if old_metadata["source_commit"] != source_commit:
                fail(f"release documentation is immutable and already exists: {tag_version}")
        else:
            prepare_variant(source, sources, "release", f"{BASE}/{tag_version}")
            outputs["build_release"] = "true"
            versions.add(tag_version)

        latest_version = ""
        latest_metadata_path = site_root / "latest" / "_data" / "site.json"
        if latest_metadata_path.is_file():
            latest_version = read_metadata(site_root / "latest")["engine_version"]
        if not latest_version or tuple(map(int, engine_version.split("."))) > tuple(map(int, latest_version.split("."))):
            prepare_variant(source, sources, "latest", f"{BASE}/latest")
            outputs["build_latest"] = "true"
            include_latest = True
        elif engine_version == latest_version:
            existing_latest = read_metadata(site_root / "latest")
            if existing_latest["source_commit"] != source_commit:
                fail(f"latest documentation for {engine_version} does not match the release source")
    else:
        fail(f"unsupported publishing ref: {ref_type} {ref_name}")

    write_root_index(site_root, versions, include_dev, include_latest)
    outputs["engine_version"] = engine_version
    outputs["source_commit"] = source_commit
    return outputs


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--sources", type=Path, required=True)
    parser.add_argument("--site-root", type=Path, required=True)
    parser.add_argument("--ref-type", required=True, choices=("branch", "tag"))
    parser.add_argument("--ref-name", required=True)
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args()
    result = prepare(
        args.source,
        args.archive,
        args.sources,
        args.site_root,
        args.ref_type,
        args.ref_name,
    )
    if args.github_output:
        with args.github_output.open("a", encoding="utf-8") as output:
            for key, value in result.items():
                output.write(f"{key}={value}\n")


if __name__ == "__main__":
    main()
