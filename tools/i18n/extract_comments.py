#!/usr/bin/env python3
"""Extracts the translatable text (comments, docstrings, assert messages) into segment files.

Usage:
  extract_comments.py --lanes 16 --out-dir DIR [--exclude-file FILE] [--manifest FILE]
  extract_comments.py --out FILE [--exclude-file FILE] [paths...]

Without paths it takes every file versioned by git that is in scope. The code is never part of
the output: only comments (and the message of test assertions) are extracted.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import i18nlib as L  # noqa: E402


def extract_file(rel: str, root: Path) -> list[L.Segment]:
	src = L.read_source(root / rel)
	return L.analyze(rel, src.text).segments


def partition(weights: list[int], k: int) -> list[int]:
	"""Splits a sequence into exactly k contiguous non-empty chunks, minimizing the heaviest.

	Returns the end index (exclusive) of each chunk."""
	n = len(weights)
	if n < k:
		raise ValueError("fewer files than lanes")
	lo, hi = max(weights), sum(weights)

	def fits(limit: int) -> bool:
		chunks, cur = 1, 0
		for w in weights:
			if cur + w > limit:
				chunks += 1
				cur = w
			else:
				cur += w
		return chunks <= k

	while lo < hi:
		mid = (lo + hi) // 2
		if fits(mid):
			hi = mid
		else:
			lo = mid + 1
	limit = lo
	ends: list[int] = []
	cur = 0
	for i, w in enumerate(weights):
		remaining_items = n - i
		remaining_chunks = k - len(ends)
		if cur and (cur + w > limit or remaining_items < remaining_chunks):
			ends.append(i)
			cur = 0
		cur += w
	ends.append(n)
	while len(ends) < k:  # split the heaviest multi-file chunk
		best, best_w, prev = -1, -1, 0
		for ci, e in enumerate(ends):
			if e - prev > 1 and sum(weights[prev:e]) > best_w:
				best, best_w = ci, sum(weights[prev:e])
			prev = e
		prev = ends[best - 1] if best else 0
		e = ends[best]
		total, acc, cut = sum(weights[prev:e]), 0, prev + 1
		for i in range(prev, e - 1):
			acc += weights[i]
			cut = i + 1
			if acc >= total / 2:
				break
		ends.insert(best, cut)
	return ends


def main() -> int:
	ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	ap.add_argument("paths", nargs="*", help="repo-relative files (default: all in scope)")
	ap.add_argument("--root", default=str(L.REPO_ROOT))
	ap.add_argument("--exclude-file", help="file with one repo path per line to skip")
	ap.add_argument("--out", help="single output file")
	ap.add_argument("--lanes", type=int, help="split the output into N balanced lanes")
	ap.add_argument("--out-dir", help="directory for lane_XX.txt")
	ap.add_argument("--manifest", help="manifest.json path (with --lanes)")
	ap.add_argument("--kind-only", action="append", default=[], metavar="GLOB=KIND",
		help="in the files matching GLOB keep only the segments of KIND (repeatable)")
	args = ap.parse_args()

	root = Path(args.root)
	excludes = L.load_excludes(Path(args.exclude_file) if args.exclude_file else None)
	if args.paths:
		files = [p.replace("\\", "/") for p in args.paths]
	else:
		files = [p for p in L.git_files(root) if L.in_scope(p, excludes)]
	files = sorted(files)
	kind_only: list[tuple[str, str]] = []
	for spec in args.kind_only:
		glob, _, kind = spec.rpartition("=")
		if not glob or not kind:
			ap.error(f"--kind-only expects GLOB=KIND, got {spec!r}")
		kind_only.append((glob, kind))

	per_file: list[tuple[str, list[L.Segment]]] = []
	for rel in files:
		segs = extract_file(rel, root)
		for glob, kind in kind_only:
			if fnmatch.fnmatch(rel, glob):
				segs = [sg for sg in segs if sg.kind == kind]
		if segs:
			per_file.append((rel, segs))
	weights = [sum(len(s.text) for s in segs) for _, segs in per_file]
	total_segs = sum(len(s) for _, s in per_file)
	print(f"{len(per_file)} files with text, {total_segs} segments, {sum(weights)} characters")

	if args.lanes:
		if not args.out_dir:
			ap.error("--lanes needs --out-dir")
		out_dir = Path(args.out_dir)
		out_dir.mkdir(parents=True, exist_ok=True)
		ends = partition(weights, args.lanes)
		manifest = {}
		prev = 0
		for li, e in enumerate(ends, start=1):
			chunk = per_file[prev:e]
			name = f"{li:02d}"
			lane_path = out_dir / f"lane_{name}.txt"
			body = [L.format_segment(s) for _, segs in chunk for s in segs]
			lane_path.write_bytes("\n".join(body).encode("utf-8"))
			dirs = sorted({str(Path(rel).parent).replace("\\", "/") for rel, _ in chunk})
			manifest[name] = {
				"files": [rel for rel, _ in chunk],
				"dirs": dirs,
				"segments": sum(len(s) for _, s in chunk),
				"chars": sum(weights[prev:e]),
				"segments_path": str(lane_path.resolve()).replace("\\", "/"),
			}
			m = manifest[name]
			print(f"lane {name}: {len(chunk):3d} files {m['segments']:5d} segments {m['chars']:7d} chars")
			prev = e
		if args.manifest:
			Path(args.manifest).write_text(json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8")
		return 0

	body = [L.format_segment(s) for _, segs in per_file for s in segs]
	data = "\n".join(body).encode("utf-8")
	if args.out:
		Path(args.out).write_bytes(data)
	else:
		sys.stdout.buffer.write(data)
	return 0


if __name__ == "__main__":
	sys.exit(main())
