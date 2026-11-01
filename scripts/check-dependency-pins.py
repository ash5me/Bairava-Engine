#!/usr/bin/env python3
"""Verify configured dependency pins and vendored trees against docs/dependency-lock.json."""

import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "docs" / "dependency-lock.json"
ZON = ROOT / "build.zig.zon"
CI = ROOT / ".github" / "workflows" / "ci.yml"


def fail(message: str) -> None:
    print(message, file=sys.stderr)


def verify_source_pins(lock: dict) -> bool:
    try:
        zon = ZON.read_text(encoding="utf-8")
        workflow = CI.read_text(encoding="utf-8")
        toolchain = lock["toolchain"]
        zig_version = re.search(r'\.minimum_zig_version\s*=\s*"([^"]+)"', zon)
        slang_version = re.search(r"(?m)^  SLANG_VERSION:\s*([^\s#]+)\s*$", workflow)
        if zig_version is None or slang_version is None:
            raise ValueError("could not find the Zig or Slang version in its source file")
        if zig_version.group(1) != toolchain["zig"]:
            raise ValueError(f"Zig version differs from lock (configured {zig_version.group(1)}, locked {toolchain['zig']})")
        if slang_version.group(1) != toolchain["slang"]:
            raise ValueError(f"Slang version differs from lock (configured {slang_version.group(1)}, locked {toolchain['slang']})")

        packages = lock["zig_packages"]
        if not isinstance(packages, list) or not packages:
            raise ValueError("zig_packages must be a non-empty list")
        for package in packages:
            if not isinstance(package, dict):
                raise ValueError("each Zig package pin must be an object")
            name = package["name"]
            if not isinstance(name, str) or not name:
                raise ValueError("Zig package name must be a non-empty string")
            declaration = re.search(rf"\.{re.escape(name.lower())}\s*=\s*\.\{{([^}}]*)\}}", zon, re.DOTALL)
            if declaration is None:
                raise ValueError(f"{name}: package declaration not found in build.zig.zon")
            url = re.search(r'\.url\s*=\s*"([^"]+)"', declaration.group(1))
            content_hash = re.search(r'\.hash\s*=\s*"([^"]+)"', declaration.group(1))
            if url is None or content_hash is None:
                raise ValueError(f"{name}: URL or package hash missing from build.zig.zon")
            if not isinstance(package.get("url"), str) or not isinstance(package.get("hash"), str):
                raise ValueError(f"{name}: lock entry needs a URL and package hash")
            if url.group(1) != package["url"] or content_hash.group(1) != package["hash"]:
                raise ValueError(f"{name}: URL or package hash differs from dependency lock")
            print(f"{name}: configured URL and package hash verified")
        print(f"Zig {toolchain['zig']}: verified")
        print(f"Slang {toolchain['slang']}: verified")
        archive_hashes = lock["slang_archives"]
        if not isinstance(archive_hashes, dict) or not archive_hashes:
            raise ValueError("slang_archives must map archive names to SHA-256 hashes")
        for archive, digest in archive_hashes.items():
            if not isinstance(archive, str) or not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
                raise ValueError(f"{archive!r}: invalid Slang archive SHA-256 pin")
            if not archive.startswith(f"slang-{toolchain['slang']}-"):
                raise ValueError(f"{archive}: archive name does not match the pinned Slang version")
        print(f"Slang release archives: {len(archive_hashes)} SHA-256 pins verified")
        return True
    except (OSError, KeyError, TypeError, ValueError) as error:
        fail(f"dependency pin verification failed: {error}")
        return False


def files_for(paths: list[str]) -> list[Path]:
    files = []
    for relative in paths:
        candidate = Path(relative)
        if candidate.is_absolute() or ".." in candidate.parts:
            raise ValueError(f"locked path must stay inside the repository: {relative}")
        path = ROOT / relative
        if path.is_file():
            files.append(path)
        elif path.is_dir():
            files.extend(item for item in path.rglob("*") if item.is_file())
        else:
            raise FileNotFoundError(f"locked path does not exist: {relative}")
    return sorted(set(files), key=lambda item: item.relative_to(ROOT).as_posix())


def canonical_content(path: Path) -> bytes:
    content = path.read_bytes()
    if b"\0" not in content[:8000]:
        content = content.replace(b"\r\n", b"\n")
    return content


def tree_hash(paths: list[str]) -> str:
    digest = hashlib.sha256()
    for path in files_for(paths):
        relative = path.relative_to(ROOT).as_posix().encode("utf-8")
        content = canonical_content(path)
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        digest.update(len(content).to_bytes(8, "big"))
        digest.update(content)
    return digest.hexdigest()


def verify_slang_archive(path: Path) -> bool:
    try:
        lock = json.loads(LOCK.read_text(encoding="utf-8"))
        expected = lock["slang_archives"][path.name]
        digest = hashlib.sha256()
        with path.open("rb") as archive:
            for block in iter(lambda: archive.read(1024 * 1024), b""):
                digest.update(block)
    except (OSError, KeyError, TypeError, json.JSONDecodeError) as error:
        fail(f"cannot verify Slang archive {path}: {error}")
        return False
    actual = digest.hexdigest()
    if actual != expected:
        fail(f"{path.name}: SHA-256 mismatch (expected {expected}, got {actual})")
        return False
    print(f"{path.name}: SHA-256 verified")
    return True


def verify_slang_compiler(command: str) -> bool:
    try:
        lock = json.loads(LOCK.read_text(encoding="utf-8"))
        version = lock["toolchain"]["slang"]
        result = subprocess.run([command, "-version"], check=False, capture_output=True, text=True)
    except (OSError, KeyError, TypeError, json.JSONDecodeError) as error:
        fail(f"cannot query Slang compiler {command}: {error}")
        return False
    if result.returncode != 0:
        fail(f"Slang compiler version query failed: {result.stderr.strip()}")
        return False
    output = (result.stdout + result.stderr).strip()
    if re.search(rf"(?m)^\s*{re.escape(version)}(?:$|[-+][^\s]*)", output) is None:
        fail(f"Slang compiler version mismatch (expected {version}, got {output or 'no version output'})")
        return False
    print(f"Slang compiler {version}: verified")
    return True


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "--slang-archive":
        return 0 if verify_slang_archive(Path(sys.argv[2])) else 1
    if len(sys.argv) == 3 and sys.argv[1] == "--slang-compiler":
        return 0 if verify_slang_compiler(sys.argv[2]) else 1
    if len(sys.argv) != 1:
        print("usage: check-dependency-pins.py [--slang-archive PATH | --slang-compiler COMMAND]", file=sys.stderr)
        return 2

    try:
        lock = json.loads(LOCK.read_text(encoding="utf-8"))
        if not isinstance(lock, dict) or lock.get("format") != 1:
            raise ValueError("unsupported dependency lock format")
        entries = lock["dependencies"]
        if not isinstance(entries, list) or not entries:
            raise ValueError("dependencies must be a non-empty list")
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(f"cannot read dependency lock: {error}", file=sys.stderr)
        return 1

    failed = not verify_source_pins(lock)
    names = set()
    for entry in entries:
        try:
            if not isinstance(entry, dict):
                raise ValueError("each dependency must be an object")
            name = entry["name"]
            expected = entry["sha256"]
            paths = entry["paths"]
            version = entry["version"]
            if not isinstance(name, str) or not name:
                raise ValueError("dependency name must be a non-empty string")
            if name in names:
                raise ValueError("dependency name is duplicated")
            names.add(name)
            if not isinstance(version, str) or not version:
                raise ValueError("version must be a non-empty string")
            if not isinstance(expected, str) or re.fullmatch(r"[0-9a-f]{64}", expected) is None:
                raise ValueError("sha256 must be 64 lowercase hexadecimal characters")
            if not isinstance(paths, list) or not paths or not all(isinstance(path, str) and path for path in paths):
                raise ValueError("paths must be a non-empty list of relative paths")
            actual = tree_hash(paths)
        except (KeyError, TypeError, ValueError, OSError) as error:
            entry_name = entry.get("name", "dependency") if isinstance(entry, dict) else "dependency"
            fail(f"{entry_name}: invalid lock entry or missing source: {error}")
            failed = True
            continue
        if actual != expected:
            fail(f"{name}: hash mismatch (expected {expected}, got {actual})")
            failed = True
        else:
            print(f"{name} {version}: verified")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
