#!/usr/bin/env python3
"""Heuristic detector of Spanish left in comments and documentation.

Usage:
  find_spanish.py [--exclude-file FILE] [--summary] [--min-words N] [--no-accents] [paths...]

Without paths it scans every versioned file that is in scope (only the comments, docstrings and
assert messages are examined) and every .md file. A line is reported when it has Spanish-only
characters (n with tilde, inverted ? and !, accented vowels) or at least --min-words (default 2)
Spanish function words (el, la, los, de, que, para, ...). It is a heuristic: quoted UI strings and
proper names will show up too, so the output is for a human to judge.
Exit code 1 if anything is found.
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import i18nlib as L  # noqa: E402

WORDS = set(
	"el la los las del de en un una unos unas y que con para por se es al lo su sus como pero cuando "
	"donde este esta estos estas hay ya sin sobre entre está están también así cada muy "
	"todo todos desde hasta siempre después antes porque mientras cuyo cuya aunque además "
	"nunca algo algún tiene tienen puede pueden debe deben sino tras según aquí allí "
	"esto eso aquel otra otro otros otras mismo misma mismos".split()
)
SPANISH_CHARS = re.compile("[ñÑ¿¡áéíóúÁÉÍÓÚü]")
WORD_RE = re.compile(r"[^\W\d_]+", re.UNICODE)


def spanish_score(line: str, accents: bool) -> tuple[int, bool]:
	hits = sum(1 for w in WORD_RE.findall(line) if w in WORDS)
	chars = bool(SPANISH_CHARS.search(line)) if accents else False
	return hits, chars


def lines_of(rel: str, root: Path) -> list[tuple[int, str]]:
	full = root / rel
	try:
		src = L.read_source(full)
	except (UnicodeDecodeError, OSError):
		return []
	if rel.endswith(".md"):
		return [(i, ln) for i, ln in enumerate(src.text.split("\n"), start=1)]
	if L.language_of(rel) is None:
		return []
	out: list[tuple[int, str]] = []
	for seg in L.analyze(rel, src.text).segments:
		for i, ln in enumerate(seg.lines):
			out.append((seg.line + i, ln))
	return out


def main() -> int:
	ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	ap.add_argument("paths", nargs="*")
	ap.add_argument("--root", default=str(L.REPO_ROOT))
	ap.add_argument("--exclude-file")
	ap.add_argument("--summary", action="store_true", help="only count the lines per file")
	ap.add_argument("--min-words", type=int, default=2)
	ap.add_argument("--no-accents", action="store_true", help="do not treat accents as Spanish")
	args = ap.parse_args()
	root = Path(args.root)
	excludes = L.load_excludes(Path(args.exclude_file) if args.exclude_file else None)
	if args.paths:
		files = []
		for p in args.paths:
			path = Path(p)
			if path.is_dir():
				base = path.resolve()
				files += [str(f.relative_to(root.resolve())).replace("\\", "/") for f in sorted(base.rglob("*")) if f.is_file()]
			else:
				files.append(p.replace("\\", "/"))
	else:
		files = [
			p for p in L.git_files(root)
			if (L.in_scope(p, excludes) or (p.endswith(".md") and p not in excludes))
			and not p.startswith("addons/")
		]
	per_file: Counter[str] = Counter()
	for rel in sorted(files):
		in_fence = False
		for lineno, ln in lines_of(rel, root):
			if rel.endswith(".md"):
				if ln.lstrip().startswith("```"):
					in_fence = not in_fence
				if in_fence:
					continue
			hits, chars = spanish_score(ln, not args.no_accents)
			if chars or hits >= args.min_words:
				per_file[rel] += 1
				if not args.summary:
					print(f"{rel}:{lineno}: {ln.strip()[:160]}")
	if args.summary:
		for rel, n in per_file.most_common():
			print(f"{n:5d} {rel}")
	print(f"{sum(per_file.values())} lines in {len(per_file)} files", file=sys.stderr)
	return 1 if per_file else 0


if __name__ == "__main__":
	sys.exit(main())
