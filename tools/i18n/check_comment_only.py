#!/usr/bin/env python3
"""Proves that the changed files differ from a base only in comments.

Usage:
  check_comment_only.py [--base main] [paths...]

For every file changed against the base (or the given paths), compares the code without comments:
GDScript, Go and shaders by token stream (comments removed; in tests/ the message literals of the
assertions may also change), Python by ast.dump without docstrings, and the rest without
full-line comments. Directives (shebang, //go:, noqa, ...) must stay identical.
Exit code 1 and a report if anything else changed.
"""

from __future__ import annotations

import argparse
import difflib
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import i18nlib as L  # noqa: E402


def git(root: Path, *args: str) -> bytes:
	return subprocess.run(["git", *args], cwd=root, check=True, capture_output=True).stdout


def main() -> int:
	ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	ap.add_argument("paths", nargs="*")
	ap.add_argument("--base", default="main")
	ap.add_argument("--root", default=str(L.REPO_ROOT))
	args = ap.parse_args()
	root = Path(args.root)

	if args.paths:
		paths = [p.replace("\\", "/") for p in args.paths]
	else:
		out = git(root, "diff", "--name-only", "-z", "--diff-filter=M", args.base).decode("utf-8")
		paths = [p for p in out.split("\0") if p]

	checked = skipped = 0
	failures: list[str] = []
	for rel in paths:
		if L.language_of(rel) is None or rel.startswith("addons/"):
			skipped += 1
			continue
		full = root / rel
		if not full.exists():
			failures.append(f"{rel}: does not exist in the working tree")
			continue
		try:
			base_raw = git(root, "show", f"{args.base}:{rel}")
		except subprocess.CalledProcessError:
			skipped += 1  # new file
			continue
		checked += 1
		new_raw = full.read_bytes()
		if new_raw.startswith(b"\xef\xbb\xbf") != base_raw.startswith(b"\xef\xbb\xbf"):
			failures.append(f"{rel}: the BOM changed")
			continue
		if (b"\r\n" in new_raw) != (b"\r\n" in base_raw):
			failures.append(f"{rel}: the line endings changed")
			continue
		try:
			old = _decode(base_raw)
			new = _decode(new_raw)
			a = L.code_view(rel, old)
			b = L.code_view(rel, new)
		except Exception as exc:  # noqa: BLE001
			failures.append(f"{rel}: could not analyze ({exc})")
			continue
		if a != b:
			diff = list(difflib.unified_diff(a, b, "base", "now", lineterm="", n=0))
			shown = "\n    ".join(d[:200] for d in diff[2:12])
			failures.append(f"{rel}: something besides comments changed\n    {shown}")

	print(f"checked {checked} files, skipped {skipped} (other types or new files)")
	for f in failures:
		print("FAIL", f)
	if not failures:
		print("OK: only comments (and test assertion messages) changed")
	return 1 if failures else 0


def _decode(raw: bytes) -> str:
	if raw.startswith(b"\xef\xbb\xbf"):
		raw = raw[3:]
	return raw.decode("utf-8").replace("\r\n", "\n")


if __name__ == "__main__":
	sys.exit(main())
