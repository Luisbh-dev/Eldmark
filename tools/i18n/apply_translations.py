#!/usr/bin/env python3
"""Re-injects translated segments into the source files.

Usage:
  apply_translations.py translated.txt [more.txt ...] [--dry-run] [--root DIR]

The translated files use the same format as the extracted ones. Lines starting with "~ " (context)
are ignored. Every segment is validated; a rejected segment is reported and left as it was.
Segments whose text did not change are skipped, so applying an unchanged file changes nothing.
After editing a file, it is analyzed again and the tool refuses to write it if anything besides
comments (or test assertion messages) would differ.
"""

from __future__ import annotations

import argparse
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import i18nlib as L  # noqa: E402


def main() -> int:
	ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	ap.add_argument("files", nargs="+", help="translated segment files")
	ap.add_argument("--dry-run", action="store_true", help="validate and report, write nothing")
	ap.add_argument("--root", default=str(L.REPO_ROOT))
	ap.add_argument("--force-render", action="store_true",
		help="test mode: rebuild even the unchanged segments (to prove the rendering is exact)")
	ap.add_argument("--quiet", action="store_true", help="do not list every missing id")
	args = ap.parse_args()
	root = Path(args.root)

	blocks: list[L.Translated] = []
	for f in args.files:
		blocks += L.parse_segment_file(Path(f))

	by_path: dict[str, list[L.Translated]] = defaultdict(list)
	for b in blocks:
		by_path[b.path].append(b)

	counts = defaultdict(int)
	rejections: list[tuple[str, str]] = []
	missing: list[str] = []
	seen_ids: set[str] = set()
	touched_files = 0

	for rel in sorted(by_path):
		full = root / rel
		if not full.exists() or L.language_of(rel) is None:
			for b in by_path[rel]:
				rejections.append((b.sid, f"{rel}: the file does not exist or is out of scope"))
				counts["rejected"] += 1
			continue
		src = L.read_source(full)
		ana = L.analyze(rel, src.text)
		table = {s.sid: s for s in ana.segments}
		by_ordinal = {(s.ordinal): s for s in ana.segments}
		edits: list[tuple[int, int, str]] = []
		applied_ids: set[str] = set()
		for b in by_path[rel]:
			if b.sid in seen_ids:
				rejections.append((b.sid, "duplicate id in the translated files"))
				counts["rejected"] += 1
				continue
			seen_ids.add(b.sid)
			seg = table.get(b.sid)
			if seg is None:
				_, n, _ = b.sid.split("-") if b.sid.count("-") == 2 else (None, "0", None)
				other = by_ordinal.get(int(n)) if n.isdigit() else None
				why = (
					"the original text in the file changed since the extraction"
					if other is not None and other.sid.split("-")[0] == b.sid.split("-")[0]
					and other.sid.split("-")[1] == n
					else "the id does not exist"
				)
				rejections.append((b.sid, f"{rel}:{b.line}: {why}"))
				counts["rejected"] += 1
				continue
			if b.kind != seg.kind:
				rejections.append((b.sid, f"{rel}:{seg.line}: kind changed ({seg.kind} -> {b.kind})"))
				counts["rejected"] += 1
				continue
			if seg.kind in ("assert", "gotest"):  # spaces at the ends matter: the string may be joined with "+"
				new_lines, old_lines = list(b.lines), list(seg.lines)
			else:
				new_lines = [ln.rstrip() for ln in b.lines]
				old_lines = [ln.rstrip() for ln in seg.lines]
			if not args.force_render and new_lines == old_lines:
				counts["unchanged"] += 1
				applied_ids.add(seg.sid)
				continue
			reason = L.validate(seg, new_lines)
			if reason:
				rejections.append((b.sid, f"{rel}:{seg.line}: {reason}"))
				counts["rejected"] += 1
				continue
			edits.append((seg.start, seg.end, L.render(seg, new_lines)))
			applied_ids.add(seg.sid)
			counts["applied"] += 1
		present = {b.sid for b in by_path[rel]}
		for s in ana.segments:
			if s.sid not in present:
				missing.append(f"{s.sid} {s.kind} {rel}:{s.line}")
				counts["missing"] += 1
		if not edits:
			continue
		new_text = src.text
		for start, end, rep in sorted(edits, key=lambda e: e[0], reverse=True):
			new_text = new_text[:start] + rep + new_text[end:]
		# Safety net: only comments may have changed.
		try:
			ok = L.code_view(rel, new_text) == L.code_view(rel, src.text)
			err = "" if ok else "the code would change"
		except Exception as exc:  # noqa: BLE001
			ok, err = False, f"the result does not parse: {exc}"
		if not ok:
			rejections.append(("-", f"{rel}: file not written ({err})"))
			counts["files_refused"] += 1
			counts["applied"] -= len(edits)
			counts["rejected"] += len(edits)
			continue
		touched_files += 1
		if not args.dry_run:
			full.write_bytes(src.encode(new_text))

	print(("DRY RUN: " if args.dry_run else "") + "report")
	print(f"  segments read:      {len(blocks)}")
	print(f"  applied:            {counts['applied']}")
	print(f"  unchanged:          {counts['unchanged']}")
	print(f"  rejected:           {counts['rejected']}")
	print(f"  missing (not in the translated files, left as is): {counts['missing']}")
	print(f"  files {'that would be ' if args.dry_run else ''}written: {touched_files}")
	for sid, why in rejections:
		print(f"  REJECTED {sid}: {why}")
	if missing and not args.quiet:
		for m in missing[:200]:
			print(f"  MISSING {m}")
		if len(missing) > 200:
			print(f"  ... and {len(missing) - 200} more missing")
	return 1 if rejections else 0


if __name__ == "__main__":
	sys.exit(main())
