#!/usr/bin/env python3
"""Updates the references to the renamed documents in every versioned text file.

Usage:
  rename_doc_refs.py [--dry-run] [--exclude-file FILE] [--root DIR] [paths...]

Recognizes the path with and without "docs/" ("docs/red.md#...", "red.md §4", "../red.md",
"[red.md](red.md)") using word boundaries, so "red.md" never matches inside "shared.md" or
"my-red.md". Skips addons/**, the excluded files, platform/legal/**, .sql files, binary files and
tools/i18n/ itself. The "git mv" of the documents is not done here.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import i18nlib as L  # noqa: E402

DOC_RENAMES = {
	"arte.md": "art.md",
	"fuerte.md": "fortress.md",
	"habilidades.md": "abilities.md",
	"informe_noche.md": "history/2026-10-night-report.md",
	"mundo.md": "world.md",
	"plataforma.md": "platform.md",
	"progresion.md": "progression.md",
	"red.md": "networking.md",
	"mapa_mundo.svg": "world_map.svg",
	"calidad.md": "quality.md",
	"combate.md": "combat.md",
	"LICENCIAS.md": "LICENSES.md",
}
DIR_RENAMES = {"capturas": "screenshots", "zonas": "zones"}

_NAMES = "|".join(re.escape(n) for n in sorted(DOC_RENAMES, key=len, reverse=True))
FILE_RE = re.compile(r"(?P<lead>(?:\.{1,2}/)*(?:docs/)?)(?P<name>" + _NAMES + r")(?![\w-])")
_DIRS = "|".join(re.escape(n) for n in DIR_RENAMES)
DIR_RE = re.compile(r"(?P<lead>(?:\.{1,2}/)*(?:docs/)?)(?P<name>" + _DIRS + r")(?P<tail>/|(?![\w-]))")
# "assets/LICENCIAS.md": the file lives in assets/, so the "/" before the name would block the bare rule.
ASSETS_RE = re.compile(r"(?<![\w-])assets/LICENCIAS\.md(?![\w-])")

BARE_PREV = set(" \t\n\"'`([<*|=,;:>{«“‘¿¡")
BINARY_SUFFIXES = {
	".png", ".jpg", ".jpeg", ".gif", ".webp", ".ogg", ".wav", ".mp3", ".glb", ".gltf", ".bin", ".res",
	".so", ".dll", ".dylib", ".exe", ".pem", ".uid", ".import", ".zip", ".ttf", ".otf", ".woff", ".woff2",
	".blend", ".psd", ".ico", ".mp4", ".webm", ".sum",
}


def skip_path(rel: str, excludes: set[str]) -> bool:
	return (
		rel.startswith("addons/")
		or rel.startswith("platform/legal/")
		or rel.startswith("tools/i18n/")
		or rel in excludes
		or rel.endswith(".sql")
		or Path(rel).suffix.lower() in BINARY_SUFFIXES
	)


def _prev(text: str, pos: int) -> str:
	return text[pos - 1] if pos > 0 else "\n"


def rewrite(rel: str, text: str) -> tuple[str, list[tuple[int, str, str]]]:
	"""Returns the new text and the list of (line, old, new)."""
	changes: list[tuple[int, str, str]] = []
	edits: list[tuple[int, int, str]] = []
	in_docs = rel.startswith("docs/")

	for m in FILE_RE.finditer(text):
		lead = m.group("lead")
		prev = _prev(text, m.start())
		if lead:
			if prev.isalnum() or prev in "_-":
				continue
		elif prev not in BARE_PREV:
			continue
		new = lead + DOC_RENAMES[m.group("name")]
		edits.append((m.start(), m.end(), new))
	for m in DIR_RE.finditer(text):
		lead = m.group("lead")
		prev = _prev(text, m.start())
		if "docs/" in lead:
			if prev.isalnum() or prev in "_-":
				continue
		elif lead:
			if prev.isalnum() or prev in "_-":
				continue
		else:
			# Bare "capturas/" only as a link or an HTML attribute target inside the docs.
			if not (in_docs and prev in "(\"'" and m.group("tail") == "/"):
				continue
		edits.append((m.start(), m.end(), lead + DIR_RENAMES[m.group("name")] + m.group("tail")))
	for m in ASSETS_RE.finditer(text):
		edits.append((m.start(), m.end(), "assets/LICENSES.md"))

	if not edits:
		return text, changes
	out = text
	for s, e, new in sorted(edits, key=lambda x: x[0], reverse=True):
		line = text.count("\n", 0, s) + 1
		changes.append((line, text[s:e], new))
		out = out[:s] + new + out[e:]
	changes.sort()
	return out, changes


def main() -> int:
	sys.stdout.reconfigure(encoding="utf-8", errors="replace")
	ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	ap.add_argument("paths", nargs="*")
	ap.add_argument("--dry-run", action="store_true")
	ap.add_argument("--exclude-file")
	ap.add_argument("--root", default=str(L.REPO_ROOT))
	args = ap.parse_args()
	root = Path(args.root)
	excludes = L.load_excludes(Path(args.exclude_file) if args.exclude_file else None)
	files = [p.replace("\\", "/") for p in args.paths] if args.paths else L.git_files(root)

	total = changed_files = 0
	for rel in files:
		if skip_path(rel, excludes):
			continue
		full = root / rel
		if not full.is_file():
			continue
		raw = full.read_bytes()
		if b"\0" in raw[:8192]:
			continue
		try:
			src = L.read_source(full)
		except UnicodeDecodeError:
			continue
		new_text, changes = rewrite(rel, src.text)
		if not changes:
			continue
		changed_files += 1
		total += len(changes)
		for line, old, new in changes:
			print(f"{rel}:{line}: {old} -> {new}")
		if not args.dry_run:
			full.write_bytes(src.encode(new_text))
	print(f"{'would replace' if args.dry_run else 'replaced'} {total} references in {changed_files} files")
	return 0


if __name__ == "__main__":
	sys.exit(main())
