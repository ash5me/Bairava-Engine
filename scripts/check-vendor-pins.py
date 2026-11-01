#!/usr/bin/env python3
"""Verify that vendored dependency trees match docs/dependency-lock.json."""

import hashlib
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "docs" / "dependency-lock.json"


def files_for(paths: list[str]) -> list[Path]:
    files = []
    for relative in paths:
        path = ROOT / relative
        if path.is_file():
            files.append(path)
        elif path.is_dir():
            files.extend(item for item in path.rglob("*") if item.is_file())
        else:
            raise FileNotFoundError(f"locked path does not exist: {relative}")
    return sorted(set(files), key=lambda item: item.relative_to(ROOT).as_posix())


def tree_hash(paths: list[str]) -> str:
    digest = hashlib.sha256()
    for path in files_for(paths):
        relative = path.relative_to(ROOT).as_posix().encode("utf-8")
        content = path.read_bytes()
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        digest.update(len(content).to_bytes(8, "big"))
        digest.update(content)
    return digest.hexdigest()


def main() -> int:
    try:
        lock = json.loads(LOCK.read_text(encoding="utf-8"))
        entries = lock["dependencies"]
    except (OSError, KeyError, json.JSONDecodeError) as error:
        print(f"cannot read dependency lock: {error}", file=sys.stderr)
        return 1

    failed = False
    for entry in entries:
        name = entry["name"]
        try:
            actual = tree_hash(entry["paths"])
        except (OSError, FileNotFoundError) as error:
            print(f"{name}: {error}", file=sys.stderr)
            failed = True
            continue
        expected = entry["sha256"]
        if actual != expected:
            print(f"{name}: hash mismatch (expected {expected}, got {actual})", file=sys.stderr)
            failed = True
        else:
            print(f"{name} {entry['version']}: verified")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
