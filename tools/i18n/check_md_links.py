#!/usr/bin/env python3
"""Checks the internal links and anchors of every versioned .md file.

Usage: check_md_links.py [--root DIR]

Verifies that relative links (and HTML src/href) point to an existing file and that the
"#anchor" exists as a GitHub-style heading slug in the target. External links are ignored.
Exit code 1 when something is broken. Standard library only.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote

LINK_RE = re.compile(r"(?<!\!)\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)|!\[[^\]]*\]\(([^)\s]+)\)|(?:src|href)=\"([^\"]+)\"")
HEAD_RE = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
FENCE_RE = re.compile(r"^\s*(```|~~~)")


def slug(title: str) -> str:
	t = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", title)
	t = re.sub(r"[`*_~]", lambda m: "_" if m.group(0) == "_" else "", t).lower()
	t = re.sub(r"[^\w\- ]", "", t, flags=re.UNICODE)
	return t.strip().replace(" ", "-")


def anchors_of(path: Path) -> set[str]:
	seen: dict[str, int] = {}
	out: set[str] = set()
	fenced = False
	for line in path.read_text(encoding="utf-8").splitlines():
		if FENCE_RE.match(line):
			fenced = not fenced
			continue
		if fenced:
			continue
		m = HEAD_RE.match(line)
		if not m:
			continue
		s = slug(m.group(2))
		n = seen.get(s, 0)
		seen[s] = n + 1
		out.add(s if n == 0 else f"{s}-{n}")
	for m in re.finditer(r"<a\s+(?:name|id)=\"([^\"]+)\"", path.read_text(encoding="utf-8")):
		out.add(m.group(1))
	return out


def main() -> int:
	ap = argparse.ArgumentParser(description=__doc__)
	ap.add_argument("--root", default=".")
	root = Path(ap.parse_args().root).resolve()
	files = subprocess.run(["git", "ls-files", "*.md"], cwd=root, capture_output=True, text=True, encoding="utf-8").stdout.split()
	cache: dict[Path, set[str]] = {}
	bad = 0
	for rel in files:
		if rel.startswith("addons/") or rel.startswith("platform/legal/"):
			continue
		path = root / rel
		if not path.is_file():
			continue
		fenced = False
		for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
			if FENCE_RE.match(line):
				fenced = not fenced
				continue
			if fenced:
				continue
			line = re.sub(r"`[^`]*`", "", line)
			for m in LINK_RE.finditer(line):
				target = next(g for g in m.groups() if g)
				if re.match(r"^[a-z][a-z0-9+.-]*:", target, re.I) or target.startswith("//"):
					continue
				file_part, _, anchor = target.partition("#")
				dest = path if not file_part else (path.parent / unquote(file_part)).resolve()
				if not dest.exists():
					print(f"{rel}:{n}: missing file {target}")
					bad += 1
					continue
				if anchor and dest.suffix == ".md":
					if dest not in cache:
						cache[dest] = anchors_of(dest)
					if unquote(anchor).lower() not in cache[dest]:
						print(f"{rel}:{n}: missing anchor {target}")
						bad += 1
	print(f"{bad} broken links in {len(files)} files")
	return 1 if bad else 0


if __name__ == "__main__":
	sys.exit(main())
