#!/usr/bin/env python3
"""Check the upstream commits recorded in docs/dependency-lock.json against the vendored files.

Run from the repository root (the folder that contains docs/ and vendor/):

    python scripts/verify-dependency-commits.py --harfbuzz <clone of harfbuzz/harfbuzz> --stb <clone of nothings/stb>

Other paths can be given with --lock and --vendor-root. Local clones are needed because the
commits are read from them:

    git clone https://github.com/harfbuzz/harfbuzz <dir>/harfbuzz
    git clone https://github.com/nothings/stb <dir>/stb

For HarfBuzz it also checks that the lock's tree hash equals the hash of the commit export.

Exit status: 0 when every checked file matches its commit, 1 when at least one differs,
2 when a path, a recorded commit, or a clone is missing. Line endings are normalized to LF
before comparison, as in the pin checker. Pass --verbose to list every differing name.
"""

import argparse
import hashlib
import io
import json
import subprocess
import sys
import tarfile
from pathlib import Path

HB_VENDOR = "vendor/harfbuzz-15.1.0"
HB_EXPORT = ["src", "COPYING"]
STB_REQUIRED = "vendor/stb_truetype.h"
STB_INFO = ["vendor/stb_image.h", "vendor/stb_image_write.h", "vendor/stb_rect_pack.h"]
LIST_LIMIT = 20


def canonical(data: bytes) -> bytes:
    return data.replace(b"\r\n", b"\n") if b"\0" not in data[:8000] else data


def git(clone: Path, *args: str) -> bytes:
    return subprocess.run(["git", "-C", str(clone), *args], check=True, capture_output=True).stdout


def commit_exists(clone: Path, sha: str) -> bool:
    result = subprocess.run(["git", "-C", str(clone), "cat-file", "-e", f"{sha}^{{commit}}"],
                            capture_output=True)
    return result.returncode == 0


def upstream_harfbuzz(clone: Path, sha: str) -> dict:
    data = git(clone, "archive", "--format=tar", sha, *HB_EXPORT)
    files = {}
    with tarfile.open(fileobj=io.BytesIO(data)) as tar:
        for member in tar.getmembers():
            if member.isfile():
                files[member.name] = tar.extractfile(member).read()
    return files


def tree_hash_of(files: dict) -> str:
    """The pin checker's tree hash, computed over the export as if it were vendor/harfbuzz-15.1.0/."""
    digest = hashlib.sha256()
    for rel in sorted(files):
        path = f"{HB_VENDOR}/{rel}".encode("utf-8")
        content = canonical(files[rel])
        digest.update(len(path).to_bytes(8, "big"))
        digest.update(path)
        digest.update(len(content).to_bytes(8, "big"))
        digest.update(content)
    return digest.hexdigest()


def vendored(root: Path, prefix: str) -> dict:
    base = root / prefix
    return {p.relative_to(base).as_posix(): p.read_bytes() for p in base.rglob("*") if p.is_file()}


def report(label: str, names: list, verbose: bool) -> None:
    if not names:
        return
    shown = names if verbose else names[:LIST_LIMIT]
    print(f"  {label}: {len(names)}")
    for name in shown:
        print(f"    {name}")
    if len(names) > len(shown):
        print(f"    ... {len(names) - len(shown)} more (use --verbose)")


def check_harfbuzz(clone: Path, sha: str, vendor_root: Path, verbose: bool, locked_hash: str) -> int:
    print(f"HarfBuzz at {sha}")
    up = upstream_harfbuzz(clone, sha)
    local = vendored(vendor_root, HB_VENDOR)
    only_up = sorted(set(up) - set(local))
    only_local = sorted(set(local) - set(up))
    differ = sorted(k for k in set(up) & set(local) if canonical(up[k]) != canonical(local[k]))
    print(f"  files at commit ({', '.join(HB_EXPORT)}): {len(up)}; vendored: {len(local)}")
    report("only at commit", only_up, verbose)
    report("only vendored", only_local, verbose)
    report("content differs", differ, verbose)
    export_hash = tree_hash_of(up)
    print(f"  tree hash of the commit export: {export_hash}")
    print(f"  tree hash recorded in the lock:  {locked_hash}")
    status = 0
    if only_up or only_local or differ:
        print("  vendored files differ from the commit")
        status = 1
    if export_hash != locked_hash:
        print("  lock hash does not describe the commit export")
        status = 1
    if status == 0:
        print("  result: vendored tree matches the commit, and the lock hash matches the commit export")
    return status


def check_stb(clone: Path, sha: str, vendor_root: Path, verbose: bool, locked_hash: str) -> int:
    print(f"stb at {sha}")
    local_path = vendor_root / STB_REQUIRED
    if not local_path.is_file():
        print(f"  {STB_REQUIRED} not found under {vendor_root}", file=sys.stderr)
        return 2
    up = git(clone, "show", f"{sha}:stb_truetype.h")
    same = canonical(up) == canonical(local_path.read_bytes())
    print(f"  stb_truetype.h: {'matches the commit' if same else 'DIFFERS from the commit'}")
    print(f"  stb_truetype.h raw SHA-256 at commit: {hashlib.sha256(up).hexdigest()}")
    for rel in STB_INFO:
        name = rel.split("/")[-1]
        try:
            up_other = git(clone, "show", f"{sha}:{name}")
        except subprocess.CalledProcessError:
            print(f"  {name}: not present at commit (informational)")
            continue
        other_path = vendor_root / rel
        if not other_path.is_file():
            print(f"  {name}: not vendored (informational)")
            continue
        match = canonical(up_other) == canonical(other_path.read_bytes())
        print(f"  {name}: {'matches' if match else 'differs from'} the commit (informational)")
    return 0 if same else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--harfbuzz", type=Path, help="local clone of harfbuzz/harfbuzz")
    parser.add_argument("--stb", type=Path, help="local clone of nothings/stb")
    parser.add_argument("--lock", type=Path, default=Path("docs") / "dependency-lock.json")
    parser.add_argument("--vendor-root", type=Path, default=Path("."),
                        help="repository root that holds vendor/ (default: current directory)")
    parser.add_argument("--verbose", action="store_true", help="list every differing file name")
    args = parser.parse_args()
    if not args.harfbuzz and not args.stb:
        parser.error("give --harfbuzz, --stb, or both")

    if not args.lock.is_file():
        print(f"lock file not found: {args.lock}. Run from the repository root or pass --lock.", file=sys.stderr)
        return 2
    if not (args.vendor_root / "vendor").is_dir():
        print(f"no vendor/ folder under {args.vendor_root.resolve()}. "
              "Run from the repository root or pass --vendor-root.", file=sys.stderr)
        return 2

    lock = json.loads(args.lock.read_text(encoding="utf-8"))
    commits = {entry["name"]: entry.get("commit") for entry in lock["dependencies"]}
    hashes = {entry["name"]: entry.get("sha256") for entry in lock["dependencies"]}

    checks = []
    if args.harfbuzz:
        checks.append(("HarfBuzz", args.harfbuzz, check_harfbuzz))
    if args.stb:
        checks.append(("stb", args.stb, check_stb))

    status = 0
    for name, clone, check in checks:
        sha = commits.get(name)
        if not sha:
            print(f"{name}: no commit recorded in {args.lock}", file=sys.stderr)
            return 2
        if not commit_exists(clone, sha):
            print(f"{name}: commit {sha} is not in {clone}; run git fetch in that clone", file=sys.stderr)
            return 2
        status = max(status, check(clone, sha, args.vendor_root, args.verbose, hashes.get(name)))
    print("OK" if status == 0 else "FAILED")
    return status


if __name__ == "__main__":
    raise SystemExit(main())
