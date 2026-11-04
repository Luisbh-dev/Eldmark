"""Shared library for the comment translation tools.

It knows how to find, in every supported language, the pieces of text that a translator may
change (comments, docstrings and the message of test assertions), and how to rebuild the file
with new text in those places without touching anything else.

Only the Python standard library is used.
"""

from __future__ import annotations

import ast
import fnmatch
import hashlib
import io
import re
import subprocess
import tokenize
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath

REPO_ROOT = Path(__file__).resolve().parents[2]

# ---------------------------------------------------------------------------------------------
# Scope
# ---------------------------------------------------------------------------------------------

SCOPE_EXTENSIONS = {
	".gd": "gd",
	".py": "py",
	".go": "go",
	".gdshader": "shader",
	".gdshaderinc": "shader",
	".sh": "hash",
	".ps1": "hash",
	".yml": "hash",
	".yaml": "hash",
	".conf": "hash",
	".cfg": "cfg",
	".editorconfig": "hash",
	".example": "hash",
	".dockerignore": "hash",
}
SCOPE_BASENAMES = {
	"Dockerfile": "hash",
	"Caddyfile": "hash",
	".gitignore": "hash",
	".gitattributes": "hash",
	".editorconfig": "hash",
	".dockerignore": "hash",
}


def language_of(path: str) -> str | None:
	"""Returns the language key of a path, or None when the file is out of scope."""
	name = PurePosixPath(path).name
	if name in SCOPE_BASENAMES:
		return SCOPE_BASENAMES[name]
	suffix = PurePosixPath(path).suffix
	if name.startswith(".") and suffix == "":
		suffix = name  # ".editorconfig" has no suffix for pathlib
	return SCOPE_EXTENSIONS.get(suffix)


def git_files(root: Path = REPO_ROOT) -> list[str]:
	out = subprocess.run(
		["git", "ls-files", "-z"], cwd=root, check=True, capture_output=True
	).stdout.decode("utf-8")
	return [p for p in out.split("\0") if p]


def load_excludes(path: Path | None) -> set[str]:
	if path is None or not path.exists():
		return set()
	lines = path.read_text(encoding="utf-8").splitlines()
	return {ln.strip().replace("\\", "/") for ln in lines if ln.strip()}


def in_scope(path: str, excludes: set[str]) -> bool:
	if language_of(path) is None:
		return False
	if path.startswith("addons/"):
		return False
	if path in excludes:
		return False
	if path.endswith(".sql") or path.endswith(".md"):
		return False
	return True


# ---------------------------------------------------------------------------------------------
# File reading and writing (LF, UTF-8 without BOM, preserved as found)
# ---------------------------------------------------------------------------------------------

@dataclass
class SourceFile:
	text: str  # normalized to LF
	crlf: bool
	bom: bool

	def encode(self, text: str | None = None) -> bytes:
		body = self.text if text is None else text
		if self.crlf:
			body = body.replace("\n", "\r\n")
		data = body.encode("utf-8")
		return (b"\xef\xbb\xbf" + data) if self.bom else data


def read_source(path: Path) -> SourceFile:
	raw = path.read_bytes()
	bom = raw.startswith(b"\xef\xbb\xbf")
	if bom:
		raw = raw[3:]
	text = raw.decode("utf-8")
	crlf = "\r\n" in text
	if crlf:
		text = text.replace("\r\n", "\n")
	return SourceFile(text=text, crlf=crlf, bom=bom)


# ---------------------------------------------------------------------------------------------
# Segments
# ---------------------------------------------------------------------------------------------

SINGLE_LINE_KINDS = {"inline", "region", "assert", "gotest"}


@dataclass
class Segment:
	path: str
	kind: str
	line: int
	start: int  # offset of the replaced region in the (LF) text
	end: int
	lines: list[str]  # original text, without prefix or indentation
	context: str = ""
	note: str = ""
	# Rendering data (language dependent).
	style: dict = field(default_factory=dict)
	ordinal: int = 0
	sid: str = ""

	@property
	def text(self) -> str:
		return "\n".join(self.lines)

	@property
	def single_line(self) -> bool:
		return self.kind in SINGLE_LINE_KINDS or self.style.get("single", False)


def _h(s: str, n: int) -> str:
	return hashlib.sha1(s.encode("utf-8")).hexdigest()[:n]


def assign_ids(path: str, segs: list[Segment]) -> None:
	ph = _h(path, 5)
	for i, s in enumerate(segs, start=1):
		s.ordinal = i
		s.sid = f"{ph}-{i}-{_h(s.text, 4)}"


# ---------------------------------------------------------------------------------------------
# Natural language filter
# ---------------------------------------------------------------------------------------------

_WORD = re.compile(r"[^\W\d_]{3,}")


def has_text(lines: list[str]) -> bool:
	"""True if the text contains something that looks like words (not just code or symbols)."""
	for ln in lines:
		if _WORD.search(ln):
			return True
		if any(ord(ch) > 127 and ch.isalpha() for ch in ln):
			return True
	return False


# ---------------------------------------------------------------------------------------------
# Raw comment records
# ---------------------------------------------------------------------------------------------

@dataclass
class Comment:
	start: int  # offset of the marker
	end: int  # offset just after the last character of the comment (before "\n")
	line: int  # 1-based
	fullline: bool
	indent: str  # whitespace before the marker on its line (full-line comments)
	marker: str  # "#", "##", "//", ";"
	rest: str  # text after the marker
	block: bool = False  # /* */ comment (rest is everything between the delimiters)


def _line_starts(text: str) -> list[int]:
	starts = [0]
	for m in re.finditer("\n", text):
		starts.append(m.end())
	return starts


def _line_of(starts: list[int], off: int) -> int:
	import bisect

	return bisect.bisect_right(starts, off)


def _is_fullline(text: str, starts: list[int], start: int) -> tuple[bool, str]:
	ln = _line_of(starts, start)
	prefix = text[starts[ln - 1]:start]
	return (prefix.strip() == ""), prefix


# ---------------------------------------------------------------------------------------------
# Lexers
# ---------------------------------------------------------------------------------------------

@dataclass
class Tok:
	kind: str  # id, str, op, other
	start: int
	end: int
	text: str = ""
	# For strings
	cstart: int = 0
	cend: int = 0
	quote: str = ""
	triple: bool = False


_IDENT = re.compile(r"[^\W\d]\w*")


def lex_gd(text: str) -> tuple[list[Tok], list[Comment]]:
	"""Tokenizes GDScript just enough to separate strings, comments and punctuation."""
	toks: list[Tok] = []
	comments: list[Comment] = []
	starts = _line_starts(text)
	i, n = 0, len(text)
	while i < n:
		c = text[i]
		if c == "\n" or c in " \t\r":
			i += 1
		elif c == "#":
			j = text.find("\n", i)
			j = n if j == -1 else j
			raw = text[i:j]
			marker = "##" if raw.startswith("##") else "#"
			full, indent = _is_fullline(text, starts, i)
			comments.append(
				Comment(i, j, _line_of(starts, i), full, indent if full else "", marker, raw[len(marker):])
			)
			i = j
		elif c == '"' or c == "'":
			triple = text.startswith(c * 3, i)
			ql = 3 if triple else 1
			j = i + ql
			while True:
				if j >= n:
					raise ValueError(f"unterminated string at offset {i}")
				if text[j] == "\\":
					j += 2
					continue
				if text.startswith(c * ql, j):
					break
				j += 1
			toks.append(Tok("str", i, j + ql, text[i:j + ql], i + ql, j, c, triple))
			i = j + ql
		else:
			m = _IDENT.match(text, i)
			if m:
				toks.append(Tok("id", i, m.end(), m.group()))
				i = m.end()
			elif c.isdigit():
				j = i + 1
				while j < n and (text[j].isalnum() or text[j] in "._"):
					j += 1
				toks.append(Tok("other", i, j, text[i:j]))
				i = j
			else:
				toks.append(Tok("op", i, i + 1, c))
				i += 1
	return toks, comments


def lex_clike(text: str, go: bool) -> tuple[list[Tok], list[Comment]]:
	"""Tokenizes Go (go=True) or shader code, keeping // and /* */ comments."""
	toks: list[Tok] = []
	comments: list[Comment] = []
	starts = _line_starts(text)
	i, n = 0, len(text)
	while i < n:
		c = text[i]
		if c in " \t\r\n":
			i += 1
		elif text.startswith("//", i):
			j = text.find("\n", i)
			j = n if j == -1 else j
			full, indent = _is_fullline(text, starts, i)
			comments.append(
				Comment(i, j, _line_of(starts, i), full, indent if full else "", "//", text[i + 2:j])
			)
			i = j
		elif text.startswith("/*", i):
			j = text.find("*/", i + 2)
			if j == -1:
				raise ValueError(f"unterminated block comment at offset {i}")
			full, indent = _is_fullline(text, starts, i)
			comments.append(
				Comment(i, j + 2, _line_of(starts, i), full, indent if full else "", "/*", text[i + 2:j], True)
			)
			i = j + 2
		elif c == '"' or (go and c in "`'"):
			j = i + 1
			while True:
				if j >= n:
					raise ValueError(f"unterminated string at offset {i}")
				if c != "`" and text[j] == "\\":
					j += 2
					continue
				if text[j] == c:
					break
				j += 1
			toks.append(Tok("str", i, j + 1, text[i:j + 1], i + 1, j, c))
			i = j + 1
		else:
			m = _IDENT.match(text, i)
			if m:
				toks.append(Tok("id", i, m.end(), m.group()))
				i = m.end()
			else:
				toks.append(Tok("op", i, i + 1, c))
				i += 1
	return toks, comments


# ---------------------------------------------------------------------------------------------
# Grouping of line comments into segments
# ---------------------------------------------------------------------------------------------

GD_DIRECTIVE = re.compile(r"^\s*(warning-ignore|gdlint|gdformat|gdlint:)")
PY_DIRECTIVE = re.compile(r"^\s*(noqa\b|type:|pylint:|fmt:|isort:|pragma\b|mypy:|-\*-|!|ruff:|pyright:)")
GO_DIRECTIVE = re.compile(r"^(go:|line |export |nolint|\+build|\s\+build|\s?nolint|\s?go:)")
HASH_DIRECTIVE = re.compile(r"^\s*(shellcheck|yaml-language-server|hadolint|syntax=|escape=|check=|Requires|requires)")
REGION = re.compile(r"^#(end)?region\b")
OUTPUT_MARK = re.compile(r"^\s*(Unordered output|Output):")


def _style(rest: str) -> str:
	if rest.strip() == "":
		return "e"
	return "s" if rest.startswith(" ") else "n"


def _strip_marker_space(rest: str, style: str) -> str:
	if style == "s":
		return rest[1:]
	return rest


def _is_directive(c: Comment, lang: str, first_line: bool) -> bool:
	rest = c.rest
	if lang == "gd":
		return bool(GD_DIRECTIVE.match(rest)) or (first_line and c.marker == "#" and rest.startswith("!"))
	if lang == "go":
		return c.marker == "//" and bool(GO_DIRECTIVE.match(rest))
	if lang == "py":
		return bool(PY_DIRECTIVE.match(rest))
	if lang in ("hash", "cfg"):
		if first_line and rest.startswith("!"):
			return True
		return bool(HASH_DIRECTIVE.match(rest))
	return False


def build_line_segments(
	path: str,
	text: str,
	comments: list[Comment],
	lang: str,
	go_test: bool = False,
) -> tuple[list[Segment], list[Comment]]:
	"""Groups line comments into segments. Returns (segments, protected_comments)."""
	starts = _line_starts(text)
	lines = text.split("\n")
	segs: list[Segment] = []
	protected: list[Comment] = []
	# Index of full-line comments by line for grouping.
	i = 0
	cs = comments
	while i < len(cs):
		c = cs[i]
		if c.block:
			i += 1
			continue
		first_line = c.line == 1
		if _is_directive(c, lang, first_line):
			protected.append(c)
			i += 1
			continue
		if not c.fullline:
			style = _style(c.rest)
			body = _strip_marker_space(c.rest, style)
			if c.marker == "//" and lang == "go" and _is_directive(c, lang, False):
				protected.append(c)
			elif has_text([body]):
				seg = Segment(
					path, "inline", c.line, c.start, c.end, [body],
					style={"marker": c.marker, "spacing": style},
				)
				code_line = lines[c.line - 1][: c.start - starts[c.line - 1]].strip()
				seg.context = code_line
				segs.append(seg)
			i += 1
			continue
		# Region markers (GDScript, PowerShell).
		if lang in ("gd", "hash") and c.marker == "#" and REGION.match(c.marker + c.rest):
			m = REGION.match(c.marker + c.rest)
			kw = m.group()
			tail = (c.marker + c.rest)[len(kw):]
			style = _style(tail)
			body = _strip_marker_space(tail, style)
			if has_text([body]):
				segs.append(
					Segment(
						path, "region", c.line, c.start + len(kw), c.end, [body],
						style={"marker": "", "spacing": style, "kw": kw},
					)
				)
			i += 1
			continue
		# Group consecutive full-line comments.
		group = [c]
		j = i + 1
		gstyle = _style(c.rest)
		while j < len(cs):
			d = cs[j]
			if (
				d.block
				or not d.fullline
				or d.line != group[-1].line + 1
				or d.indent != c.indent
				or d.marker != c.marker
				or _is_directive(d, lang, False)
				or (lang in ("gd", "hash") and REGION.match(d.marker + d.rest))
			):
				break
			ds = _style(d.rest)
			if ds != "e":
				if gstyle == "e":
					gstyle = ds
				elif ds != gstyle:
					break
			group.append(d)
			j += 1
		i = j
		# Output blocks of Go examples are compared by "go test": leave them alone.
		cut = len(group)
		if go_test:
			for k, d in enumerate(group):
				if OUTPUT_MARK.match(d.rest):
					cut = k
					protected.extend(group[k:])
					break
		group = group[:cut]
		while group and group[0].rest.strip() == "":
			group = group[1:]
		while group and group[-1].rest.strip() == "":
			group = group[:-1]
		if not group:
			continue
		style = gstyle if gstyle != "e" else "s"
		body_lines = []
		for d in group:
			if _style(d.rest) == "e":
				body_lines.append("")
			elif style == "s":
				body_lines.append(d.rest[1:])
			else:
				body_lines.append(d.rest)
		if not has_text(body_lines):
			continue
		kind = "doc" if (c.marker == "##" and lang == "gd") else "comment"
		note = ""
		if lang == "go" and c.indent == "" and kind == "comment":
			nxt = None
			last_line = group[-1].line
			k = last_line
			while k < len(lines) and lines[k].startswith("//") and GO_DIRECTIVE.match(lines[k][2:]):
				k += 1  # directives such as //go:noinline sit between the doc and the declaration
			if k < len(lines):
				nxt = lines[k]
			if nxt is not None and nxt.strip() and not nxt.lstrip().startswith("//"):
				first = body_lines[0].split()[0] if body_lines[0].split() else ""
				if re.fullmatch(r"[A-Za-z_]\w*", first) and (
					first == "Package" or re.search(r"\b" + re.escape(first) + r"\b", nxt)
				):
					kind = "godoc"
					note = (
						"NOTE: Go doc comment; the first word (\"%s\") must stay as the first word"
						% first
					)
		seg = Segment(
			path, kind, group[0].line, group[0].start, group[-1].end, body_lines,
			style={"marker": c.marker, "spacing": style, "indent": c.indent},
			note=note,
		)
		seg.context = _context_for(lines, group[0].line, group[-1].line, lang)
		segs.append(seg)
	return segs, protected


def _context_for(lines: list[str], first: int, last: int, lang: str) -> str:
	"""Next line of code after the comment block, or the previous one."""
	i = last
	while i < len(lines):
		s = lines[i].strip()
		if s and not _looks_comment(s, lang):
			return s[:140]
		if s == "":
			# Skip one blank line at most.
			pass
		i += 1
		if i - last > 4:
			break
	i = first - 2
	while i >= 0 and first - 2 - i < 4:
		s = lines[i].strip()
		if s and not _looks_comment(s, lang):
			return "(previous) " + s[:130]
		i -= 1
	return ""


def _looks_comment(s: str, lang: str) -> bool:
	if lang in ("go", "shader"):
		return s.startswith("//") or s.startswith("/*") or s.startswith("*")
	return s.startswith("#") or (lang == "cfg" and s.startswith(";"))


def render_line_segment(seg: Segment, new_lines: list[str]) -> str:
	"""Rebuilds the replaced region of a line-comment segment."""
	st = seg.style
	marker = st["marker"]
	spacing = st["spacing"]
	if seg.kind in ("inline", "region"):
		body = new_lines[0]
		if seg.kind == "region":
			return (" " if spacing == "s" else "") + body
		return marker + (" " if spacing == "s" else "") + body
	indent = st["indent"]
	out = []
	for idx, ln in enumerate(new_lines):
		if ln == "":
			piece = marker
		elif spacing == "s":
			piece = marker + " " + ln
		else:
			piece = marker + ln
		out.append(piece if idx == 0 else indent + piece)
	return "\n".join(out)


# ---------------------------------------------------------------------------------------------
# Block comments (/* */)
# ---------------------------------------------------------------------------------------------

def build_block_segments(path: str, text: str, comments: list[Comment]) -> list[Segment]:
	segs = []
	starts = _line_starts(text)
	lines = text.split("\n")
	for c in comments:
		if not c.block:
			continue
		inner = c.rest
		raw_lines = inner.split("\n")
		if len(raw_lines) == 1:
			body = inner.strip()
			if not has_text([body]):
				continue
			seg = Segment(
				path, "comment", c.line, c.start, c.end, [body],
				style={"block": "one", "single": True},
			)
			seg.context = _context_for(lines, c.line, c.line, "go")
			segs.append(seg)
			continue
		line_indent = text[starts[c.line - 1]:c.start]
		line_indent = line_indent[: len(line_indent) - len(line_indent.lstrip())]
		open_own = raw_lines[0].strip() == ""
		first = raw_lines[0].strip()
		rest = raw_lines[1:]
		close_own = rest[-1].strip() == ""
		cont = rest[:-1] if close_own else rest
		star = all(
			ln.lstrip().startswith("*") for ln in cont if ln.strip() != ""
		) and any(ln.strip() for ln in cont)
		body: list[str] = [] if open_own else [first]
		for ln in cont:
			s = ln.strip()
			if star and s.startswith("*"):
				s = s[1:]
				if s.startswith(" "):
					s = s[1:]
			else:
				s = ln[len(line_indent):] if ln.startswith(line_indent) else ln.strip()
			body.append(s.rstrip())
		if not close_own and body:
			body[-1] = body[-1].rstrip()
		if not has_text(body):
			continue
		seg = Segment(
			path, "comment", c.line, c.start, c.end, body,
			style={
				"block": "multi", "indent": line_indent, "open_own": open_own,
				"close_own": close_own, "star": star,
			},
		)
		seg.context = _context_for(lines, c.line + len(raw_lines) - 1, c.line + len(raw_lines) - 1, "go")
		segs.append(seg)
	return segs


def render_block_segment(seg: Segment, new_lines: list[str]) -> str:
	st = seg.style
	if st["block"] == "one":
		return "/* " + new_lines[0] + " */"
	indent = st["indent"]
	star = st["star"]
	pre = (indent + " * ") if star else indent
	blank_pre = (indent + " *") if star else ""
	parts = []
	for idx, ln in enumerate(new_lines):
		if idx == 0 and not st["open_own"]:
			parts.append(ln)
		else:
			parts.append(pre + ln if ln else blank_pre)
	body = "\n".join(parts)
	head = "/*" + ("\n" if st["open_own"] else " ")
	tail = ("\n" + indent + (" */" if star else "*/")) if st["close_own"] else " */"
	return head + body + tail


# ---------------------------------------------------------------------------------------------
# Assertions in tests (GDScript)
# ---------------------------------------------------------------------------------------------

# function name -> index of the "message" parameter
ASSERT_MESSAGE_INDEX = {
	"assert_true": 1,
	"assert_false": 1,
	"assert_eq": 2,
	"assert_near": 3,
	"assert_vec_near": 3,
	"assert_null": 1,
	"assert_not_null": 1,
	"fail": 0,
	# Local helpers in tests/ with a "message" parameter.
	"assert_ne_int": 2,
	"assert_ne_float": 2,
	"assert_ne_action": 2,
	"assert_same": 2,
	"fail_and_false": 0,
}

PERCENT = re.compile(r"%[-+0 #]*(?:\*|\d+)?(?:\.(?:\*|\d+))?[a-zA-Z%]")


_BAD_IDS = {"if", "else", "in", "and", "or", "not", "is", "as", "match", "for", "while"}


def _local_message_helpers(toks: list[Tok]) -> dict[str, int]:
	"""Functions defined in the same file with a parameter called 'message'."""
	found: dict[str, int] = {}
	n = len(toks)
	for i, t in enumerate(toks):
		if t.kind == "id" and t.text == "func" and i + 2 < n and toks[i + 1].kind == "id" and toks[i + 2].text == "(":
			depth, idx, k = 0, 0, i + 3
			while k < n:
				tk = toks[k]
				if tk.kind == "op":
					if tk.text in "([{":
						depth += 1
					elif tk.text in ")]}":
						if depth == 0:
							break
						depth -= 1
					elif tk.text == "," and depth == 0:
						idx += 1
				elif tk.kind == "id" and tk.text == "message" and depth == 0 and toks[k - 1].text in ("(", ","):
					found[toks[i + 1].text] = idx
				k += 1
	return found


def _message_literals(arg: list[Tok]) -> list[Tok]:
	"""String literals of a message expression ("a" % x, "a" + str(b) + "c", ...)."""
	arg = [t for t in arg if not (t.kind == "op" and t.text == "\\")]
	# Unwrap a pair of parentheses around the whole expression.
	while arg and arg[0].text == "(" and arg[0].kind == "op" and arg[-1].text == ")" and arg[-1].kind == "op":
		depth = 0
		ok = True
		for i, t in enumerate(arg):
			if t.kind == "op" and t.text in "([{":
				depth += 1
			elif t.kind == "op" and t.text in ")]}":
				depth -= 1
				if depth == 0 and i != len(arg) - 1:
					ok = False
					break
		if not ok:
			break
		arg = arg[1:-1]
	flat: list[Tok] = []
	depth = 0
	for t in arg:
		if t.kind == "op" and t.text in "([{":
			depth += 1
			if depth == 1:
				flat.append(t)
		elif t.kind == "op" and t.text in ")]}":
			depth -= 1
		elif depth == 0:
			flat.append(t)
	for t in flat:
		if t.kind == "op" and t.text not in ("+", "%", ".", "(", "[", "{"):
			return [flat[0]] if flat and flat[0].kind == "str" and len(flat) > 1 and flat[1].text == "%" else []
		if t.kind == "id" and t.text in _BAD_IDS:
			return []
	out = []
	for i, t in enumerate(flat):
		if t.kind != "str" or t.triple:
			continue
		if i > 0 and flat[i - 1].kind == "op" and flat[i - 1].text == ".":
			continue
		out.append(t)
	return out


def find_assert_messages(path: str, text: str, toks: list[Tok]) -> list[tuple[Tok, str]]:
	"""Returns (string token, function name) of each literal in a 'message' position."""
	out: list[tuple[Tok, str]] = []
	n = len(toks)
	index = dict(ASSERT_MESSAGE_INDEX)
	for name, i in _local_message_helpers(toks).items():
		index.setdefault(name, i)
	for idx, t in enumerate(toks):
		if t.kind != "id" or t.text not in index:
			continue
		if idx + 1 >= n or toks[idx + 1].text != "(" or toks[idx + 1].kind != "op":
			continue
		if idx > 0 and toks[idx - 1].kind == "id" and toks[idx - 1].text == "func":
			continue
		if idx > 0 and toks[idx - 1].kind == "op" and toks[idx - 1].text == ".":
			# Only "self.assert_x(...)" counts as a call to the helper itself.
			if not (idx > 1 and toks[idx - 2].text == "self"):
				continue
		want = index[t.text]
		depth = 0
		args: list[list[Tok]] = [[]]
		k = idx + 2
		closed = False
		while k < n:
			tk = toks[k]
			if tk.kind == "op":
				if tk.text in "([{":
					depth += 1
				elif tk.text in ")]}":
					if depth == 0:
						closed = True
						break
					depth -= 1
				elif tk.text == "," and depth == 0:
					args.append([])
					k += 1
					continue
			args[-1].append(tk)
			k += 1
		if not closed:
			continue
		if args and not args[-1]:
			args.pop()  # trailing comma
		if len(args) <= want or not args[want]:
			continue
		for lit in _message_literals(args[want]):
			out.append((lit, t.text))
	return out


def build_assert_segments(path: str, text: str, toks: list[Tok]) -> list[Segment]:
	segs = []
	starts = _line_starts(text)
	lines = text.split("\n")
	for tok, fn in find_assert_messages(path, text, toks):
		content = text[tok.cstart:tok.cend]
		if "\n" in content or not has_text([content]):
			continue
		line = _line_of(starts, tok.cstart)
		seg = Segment(
			path, "assert", line, tok.cstart, tok.cend, [content],
			style={"quote": tok.quote}, context=f"{fn}(...)",
		)
		if content != content.strip():
			seg.note = "NOTE: keep the spaces at the start/end of the text exactly (it is joined with +)"
		segs.append(seg)
	return segs


# ---------------------------------------------------------------------------------------------
# Messages of Go tests (t.Errorf, t.Fatal, ...)
# ---------------------------------------------------------------------------------------------

GO_PRINTF_METHODS = {"Errorf", "Fatalf", "Logf", "Skipf"}  # the format is argument 0
GO_PRINT_METHODS = {"Error", "Fatal", "Log", "Skip"}  # every argument is part of the message
GO_MESSAGE_METHODS = GO_PRINTF_METHODS | GO_PRINT_METHODS
# Receivers that always count as a testing value ("t.Fatalf", "h.t.Fatal", "h.T.Logf", "b.Fatalf").
GO_DEFAULT_RECEIVERS = {"t", "T", "tb", "b", "B"}
GO_TESTING_DECL = re.compile(r"\b(\w+)\s+\*?testing\.(?:T|B|TB|F)\b")
# Go verbs: flags, argument index, width, precision and the verb itself.
GO_PERCENT = re.compile(r"%[-+0 #]*(?:\[\d+\])?(?:\*|\d+)?(?:\.(?:\*|\d+))?(?:\[\d+\])?[a-zA-Z%]")
GO_ESCAPE = re.compile(r"\\(?:x[0-9a-fA-F]{2}|u[0-9a-fA-F]{4}|U[0-9a-fA-F]{8}|[0-7]{3}|.)", re.DOTALL)
GO_VALID_ESCAPE = re.compile(r"\\(?:x[0-9a-fA-F]{2}|u[0-9a-fA-F]{4}|U[0-9a-fA-F]{8}|[0-7]{3}|[abfnrtv\\\"'])")

# directory -> {helper name: index of its message parameter}
_GO_HELPER_CACHE: dict[str, dict[str, int]] = {}


def _split_args(toks: list[Tok], open_idx: int) -> tuple[list[list[Tok]], int] | None:
	"""Splits the arguments of the call whose '(' is toks[open_idx]. Returns (args, index of ')')."""
	depth = 0
	args: list[list[Tok]] = [[]]
	k = open_idx + 1
	while k < len(toks):
		tk = toks[k]
		if tk.kind == "op":
			if tk.text in "([{":
				depth += 1
			elif tk.text in ")]}":
				if depth == 0:
					if args and not args[-1]:
						args.pop()
					return args, k
				depth -= 1
			elif tk.text == "," and depth == 0:
				args.append([])
				k += 1
				continue
		args[-1].append(tk)
		k += 1
	return None


def _go_receiver_ok(toks: list[Tok], idx: int, receivers: set[str]) -> bool:
	"""toks[idx] is a method name preceded by '.': is the receiver a testing value?"""
	return idx >= 2 and toks[idx - 1].text == "." and toks[idx - 2].kind == "id" and toks[idx - 2].text in receivers


def _go_decls(toks: list[Tok]) -> list[tuple[int, str, list[tuple[str, str]], int, int]]:
	"""Function declarations: (index of the name, name, [(param, type)], body start, body end)."""
	out = []
	n = len(toks)
	for i, t in enumerate(toks):
		if not (t.kind == "id" and t.text == "func"):
			continue
		k = i + 1
		if k < n and toks[k].text == "(":  # receiver
			got = _split_args(toks, k)
			if got is None:
				continue
			k = got[1] + 1
		if not (k + 1 < n and toks[k].kind == "id" and toks[k + 1].text == "("):
			continue
		name_idx = k
		got = _split_args(toks, k + 1)
		if got is None:
			continue
		params_raw, close = got
		params: list[tuple[str, str]] = []
		pending: list[str] = []
		for piece in params_raw:
			words = [x.text for x in piece]
			if len(words) == 1 and piece[0].kind == "id":
				pending.append(words[0])
				continue
			if piece and piece[0].kind == "id":
				typ = "".join(words[1:])
				params += [(nm, typ) for nm in pending + [words[0]]]
			else:
				params += [("_", "".join(words)) for _ in range(len(pending) + 1)]
			pending = []
		for nm in pending:
			params.append((nm, ""))
		# Skip the result list up to the opening brace of the body.
		j = close + 1
		while j < n and not (toks[j].kind == "op" and toks[j].text == "{"):
			if toks[j].kind == "op" and toks[j].text == "(":
				sub = _split_args(toks, j)
				if sub is None:
					break
				j = sub[1]
			if toks[j].kind == "id" and toks[j].text == "func":
				break
			j += 1
		if j >= n or toks[j].text != "{":
			continue
		depth, e = 0, j
		while e < n:
			if toks[e].kind == "op" and toks[e].text == "{":
				depth += 1
			elif toks[e].kind == "op" and toks[e].text == "}":
				depth -= 1
				if depth == 0:
					break
			e += 1
		out.append((name_idx, toks[name_idx].text, params, j, e))
	return out


def _message_slots(name: str, args: list[list[Tok]], helpers: dict[str, int]) -> list[int]:
	if name in helpers:
		return [helpers[name]]
	return [0] if name in GO_PRINTF_METHODS else list(range(len(args)))


def go_helpers_of(text: str, known: dict[str, int] | None = None) -> dict[str, int]:
	"""Functions or methods whose string parameter is only ever passed on as a whole argument of
	t.Errorf & co (or of another helper). Returns {name: index of that parameter}."""
	known = dict(known or {})
	toks, _ = lex_clike(text, go=True)
	receivers = set(GO_DEFAULT_RECEIVERS) | set(GO_TESTING_DECL.findall(text))
	found: dict[str, int] = {}
	decls = _go_decls(toks)
	for _round in range(3):  # helpers that call helpers
		changed = False
		for _ni, name, params, bs, be in decls:
			if name in found:
				continue
			# Message calls inside the body: (argument token lists that carry a message).
			carriers: list[tuple[int, int, list[list[Tok]]]] = []
			for c in range(bs + 1, be):
				if not (toks[c].kind == "id" and toks[c + 1].text == "("):
					continue
				mname = toks[c].text
				if not (
					mname in known or mname in found
					or (mname in GO_MESSAGE_METHODS and _go_receiver_ok(toks, c, receivers))
				):
					continue
				got = _split_args(toks, c + 1)
				if got is None:
					continue
				args, close = got
				allh = {**known, **found}
				for s in _message_slots(mname, args, allh):
					if s < len(args):
						carriers.append((c + 1, close, [args[s]]))
				# fmt.Sprintf(format, ...) as an argument of the message call also carries it
				# (a helper that adds a prefix: t.Logf("[%s] %s", at, fmt.Sprintf(format, args...))).
				for arg in args:
					if len(arg) >= 4 and arg[0].text == "fmt" and arg[1].text == "." and arg[2].text == "Sprintf" and arg[3].text == "(":
						inner = _split_args(arg, 3)
						if inner is not None and inner[0]:
							carriers.append((c + 1, close, [inner[0][0]]))
			for pi, (pname, ptype) in enumerate(params):
				if ptype != "string" or pname == "_":
					continue
				uses = [k for k in range(bs + 1, be) if toks[k].kind == "id" and toks[k].text == pname]
				if not uses:
					continue
				ok = all(
					any(len(a[0]) == 1 and a[0][0] is toks[k] for _o, _c, a in carriers)
					for k in uses
				)
				if ok:
					found[name] = pi
					changed = True
					break
		if not changed:
			break
	return found


def _package_helpers(path: str, text: str) -> dict[str, int]:
	"""Helpers declared in the _test.go files of the same directory (cached) and in this file."""
	d = str(PurePosixPath(path).parent)
	cached = _GO_HELPER_CACHE.get(d)
	if cached is None:
		cached = {}
		folder = REPO_ROOT / d
		if folder.is_dir():
			for f in sorted(folder.glob("*_test.go")):
				if f.name == PurePosixPath(path).name:
					continue
				try:
					cached.update(go_helpers_of(read_source(f).text, cached))
				except (OSError, UnicodeDecodeError, ValueError):
					pass
		_GO_HELPER_CACHE[d] = cached
	known = dict(cached)
	try:
		known.update(go_helpers_of(text, known))
	except ValueError:
		pass
	return known


def _pure_literals(arg: list[Tok]) -> list[Tok]:
	"""The string literals of an argument made only of literals joined with '+'."""
	if not arg or len(arg) % 2 == 0:
		return []
	for i, t in enumerate(arg):
		if i % 2 == 0:
			if t.kind != "str" or t.quote not in ('"', "`"):
				return []
		elif not (t.kind == "op" and t.text == "+"):
			return []
	return [t for t in arg if t.kind == "str"]


def find_gotest_messages(path: str, text: str, toks: list[Tok]) -> list[tuple[Tok, str]]:
	"""(string token, method name) of every message literal of a Go test call."""
	receivers = set(GO_DEFAULT_RECEIVERS) | set(GO_TESTING_DECL.findall(text))
	helpers = _package_helpers(path, text)
	decl_names = {d[0] for d in _go_decls(toks)}
	out: list[tuple[Tok, str]] = []
	for idx, t in enumerate(toks):
		if t.kind != "id" or idx + 1 >= len(toks) or toks[idx + 1].text != "(" or idx in decl_names:
			continue
		name = t.text
		if name not in helpers and not (name in GO_MESSAGE_METHODS and _go_receiver_ok(toks, idx, receivers)):
			continue
		got = _split_args(toks, idx + 1)
		if got is None:
			continue
		args = got[0]
		for s in _message_slots(name, args, helpers):
			if s < len(args):
				for lit in _pure_literals(args[s]):
					out.append((lit, name))
	return out


def build_gotest_segments(path: str, text: str, toks: list[Tok]) -> list[Segment]:
	segs = []
	starts = _line_starts(text)
	seen: set[int] = set()
	for tok, fn in find_gotest_messages(path, text, toks):
		if tok.cstart in seen:
			continue
		seen.add(tok.cstart)
		content = text[tok.cstart:tok.cend]
		if "\n" in content or not has_text([content]):
			continue
		seg = Segment(
			path, "gotest", _line_of(starts, tok.cstart), tok.cstart, tok.cend, [content],
			style={"quote": tok.quote}, context=f"{fn}(...)",
		)
		if content != content.strip():
			seg.note = "NOTE: keep the spaces at the start/end of the text exactly (it is joined with +)"
		segs.append(seg)
	return segs


def validate_gotest(seg: Segment, new_text: str) -> str | None:
	"""Rules for the message literal of a Go test call."""
	old_pct = GO_PERCENT.findall(seg.text)
	new_pct = GO_PERCENT.findall(new_text)
	if old_pct != new_pct:
		return f"the format verbs changed: {old_pct} -> {new_pct}"
	old_text = seg.text
	if old_text[:len(old_text) - len(old_text.lstrip())] != new_text[:len(new_text) - len(new_text.lstrip())] or \
			old_text[len(old_text.rstrip()):] != new_text[len(new_text.rstrip()):]:
		return "the spaces at the start or end changed (the string is probably joined with +)"
	if seg.style["quote"] == "`":
		return "a backtick inside a raw string" if "`" in new_text else None
	if _unescaped_quote(new_text, '"'):
		return 'unescaped " quote in the string'
	if _ENDS_BACKSLASH.search(new_text):
		return "the text ends with a backslash"
	new_all = GO_ESCAPE.findall(new_text)
	for esc in new_all:
		if not GO_VALID_ESCAPE.fullmatch(esc):
			return f"invalid escape sequence {esc!r}"
	old_esc = [e for e in GO_ESCAPE.findall(seg.text) if e != '\\"']
	new_esc = [e for e in new_all if e != '\\"']
	if old_esc != new_esc:
		return f"the escape sequences changed: {old_esc} -> {new_esc}"
	return None


# ---------------------------------------------------------------------------------------------
# Python docstrings
# ---------------------------------------------------------------------------------------------

def _py_docstring_segments(path: str, text: str, toks: list[tokenize.TokenInfo]) -> list[Segment]:
	tree = ast.parse(text)
	lines = text.split("\n")
	starts = _line_starts(text)
	# Index of STRING tokens by start position.
	by_pos = {t.start: t for t in toks if t.type == tokenize.STRING}
	segs = []
	nodes: list[ast.AST] = [tree]
	for node in ast.walk(tree):
		if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
			nodes.append(node)
	for node in nodes:
		body = getattr(node, "body", [])
		if not body:
			continue
		first = body[0]
		if not (
			isinstance(first, ast.Expr)
			and isinstance(first.value, ast.Constant)
			and isinstance(first.value.value, str)
		):
			continue
		row = first.value.lineno
		col_bytes = first.value.col_offset
		col = len(lines[row - 1].encode("utf-8")[:col_bytes].decode("utf-8"))
		tok = by_pos.get((row, col))
		if tok is None:
			continue
		# Implicit concatenation: the next token on the same statement would be another string.
		if first.value.end_lineno != tok.end[0]:
			continue
		s = tok.string
		m = re.match(r"^([rRuUbBfF]{0,2})('''|\"\"\"|'|\")", s)
		if not m or "f" in m.group(1).lower() or "b" in m.group(1).lower():
			continue
		quote = m.group(2)
		prefix = m.group(1)
		inner = s[len(prefix) + len(quote):len(s) - len(quote)]
		start_off = starts[tok.start[0] - 1] + tok.start[1]
		end_off = starts[tok.end[0] - 1] + tok.end[1]
		raw_lines = inner.split("\n")
		if len(raw_lines) == 1:
			body_lines = [inner]
			style = {"prefix": prefix, "quote": quote, "multi": False, "single": True}
		else:
			cont = raw_lines[1:]
			close_own = cont[-1].strip() == ""
			nonblank = [ln for ln in cont if ln.strip()]
			if nonblank:
				ind_n = min(len(ln) - len(ln.lstrip()) for ln in nonblank)
				indent = nonblank[0][:ind_n]
			else:
				ind_n = len(cont[-1])
				indent = cont[-1]
			body_lines = [raw_lines[0]] + [
				(ln[ind_n:] if ln.strip() else "") for ln in (cont[:-1] if close_own else cont)
			]
			style = {
				"prefix": prefix, "quote": quote, "multi": True, "close_own": close_own,
				"indent": indent, "closing_indent": cont[-1] if close_own else "",
			}
		if not has_text(body_lines):
			continue
		seg = Segment(path, "docstring", row, start_off, end_off, body_lines, style=style)
		first_stmt = body[1] if len(body) > 1 else None
		if first_stmt is not None:
			seg.context = lines[first_stmt.lineno - 1].strip()[:140]
		elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
			seg.context = lines[node.lineno - 1].strip()[:140]
		segs.append(seg)
	return segs


def render_docstring(seg: Segment, new_lines: list[str]) -> str:
	st = seg.style
	q = st["quote"]
	if not st["multi"]:
		return st["prefix"] + q + new_lines[0] + q
	indent = st["indent"]
	out = [new_lines[0]]
	for ln in new_lines[1:]:
		out.append(indent + ln if ln else "")
	body = "\n".join(out)
	if st["close_own"]:
		body += "\n" + st["closing_indent"]
	return st["prefix"] + q + body + q


# ---------------------------------------------------------------------------------------------
# Analysis of a file
# ---------------------------------------------------------------------------------------------

@dataclass
class Analysis:
	path: str
	lang: str
	text: str
	segments: list[Segment]
	removable: list[tuple[int, int]]  # spans of comments dropped by code_view
	message_spans: list[tuple[int, int]]  # content of assertion messages (tests only)
	docstring_spans: list[tuple[int, int]] = field(default_factory=list)
	kept_comments: list[str] = field(default_factory=list)  # protected comment texts (directives)


def is_test_file(path: str) -> bool:
	return path.startswith("tests/") and path.endswith(".gd")


def analyze(path: str, text: str) -> Analysis:
	lang = language_of(path)
	if lang is None:
		raise ValueError(f"{path}: unsupported file type")
	segs: list[Segment] = []
	removable: list[tuple[int, int]] = []
	msg_spans: list[tuple[int, int]] = []
	doc_spans: list[tuple[int, int]] = []
	kept: list[str] = []
	if lang == "gd":
		toks, comments = lex_gd(text)
		segs, protected = build_line_segments(path, text, comments, "gd")
		prot = {id(c) for c in protected}
		removable = [(c.start, c.end) for c in comments if id(c) not in prot]
		kept = [text[c.start:c.end] for c in protected]
		if is_test_file(path):
			asegs = build_assert_segments(path, text, toks)
			segs += asegs
			msg_spans = [(s.start, s.end) for s in asegs]
			# Also blank the spans of messages that were skipped as "no text" to keep it simple.
			for tok, _fn in find_assert_messages(path, text, toks):
				span = (tok.cstart, tok.cend)
				if span not in msg_spans:
					msg_spans.append(span)
	elif lang in ("go", "shader"):
		toks, comments = lex_clike(text, go=(lang == "go"))
		segs, protected = build_line_segments(
			path, text, comments, "go" if lang == "go" else "shader",
			go_test=(lang == "go" and path.endswith("_test.go")),
		)
		segs += build_block_segments(path, text, comments)
		prot = {id(c) for c in protected}
		removable = [(c.start, c.end) for c in comments if id(c) not in prot]
		kept = [text[c.start:c.end] for c in protected]
		if lang == "go" and path.endswith("_test.go"):
			gsegs = build_gotest_segments(path, text, toks)
			segs += gsegs
			msg_spans = [(g.start, g.end) for g in gsegs]
			for tok, _fn in find_gotest_messages(path, text, toks):
				span = (tok.cstart, tok.cend)
				if span not in msg_spans:
					msg_spans.append(span)
	elif lang == "py":
		tokens = list(tokenize.generate_tokens(io.StringIO(text).readline))
		starts = _line_starts(text)
		comments = []
		for t in tokens:
			if t.type != tokenize.COMMENT:
				continue
			off = starts[t.start[0] - 1] + t.start[1]
			end = starts[t.end[0] - 1] + t.end[1]
			raw = t.string
			marker = "#"
			full, indent = _is_fullline(text, starts, off)
			comments.append(
				Comment(off, end, t.start[0], full, indent if full else "", marker, raw[1:])
			)
		segs, protected = build_line_segments(path, text, comments, "py")
		prot = {id(c) for c in protected}
		removable = [(c.start, c.end) for c in comments if id(c) not in prot]
		kept = [text[c.start:c.end] for c in protected]
		dsegs = _py_docstring_segments(path, text, tokens)
		segs += dsegs
		doc_spans = [(s.start, s.end) for s in dsegs]
	else:  # hash / cfg
		marker = ";" if lang == "cfg" else "#"
		starts = _line_starts(text)
		comments = []
		pos = 0
		for ln_no, ln in enumerate(text.split("\n"), start=1):
			stripped = ln.lstrip()
			if stripped.startswith(marker) or (lang == "cfg" and stripped.startswith("#")):
				m = marker if stripped.startswith(marker) else "#"
				if m == "#" and stripped.startswith("##"):
					m = "##"
				off = pos + (len(ln) - len(stripped))
				comments.append(
					Comment(off, pos + len(ln), ln_no, True, ln[: len(ln) - len(stripped)], m, stripped[len(m):])
				)
			pos += len(ln) + 1
		segs, protected = build_line_segments(path, text, comments, lang)
		prot = {id(c) for c in protected}
		removable = [(c.start, c.end) for c in comments if id(c) not in prot]
		kept = [text[c.start:c.end] for c in protected]
	segs.sort(key=lambda s: s.start)
	assign_ids(path, segs)
	return Analysis(path, lang, text, segs, removable, msg_spans, doc_spans, kept)


# ---------------------------------------------------------------------------------------------
# Code view, used to prove that only comments changed
# ---------------------------------------------------------------------------------------------

def _normalize_lines(text: str) -> list[str]:
	out = []
	for ln in text.split("\n"):
		s = ln.rstrip()
		if s.strip():
			out.append(s)
	return out


def code_view(path: str, text: str) -> list[str]:
	"""A list of strings that is equal for two versions that differ only in comments."""
	a = analyze(path, text)
	if a.lang == "py":
		tree = ast.parse(text)
		for node in ast.walk(tree):
			if isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
				body = node.body
				if (
					body
					and isinstance(body[0], ast.Expr)
					and isinstance(body[0].value, ast.Constant)
					and isinstance(body[0].value.value, str)
				):
					node.body = body[1:] or [ast.Pass()]
		return [ast.dump(tree)] + ["#kept:" + k for k in a.kept_comments]
	spans = sorted(a.removable + a.message_spans)
	out = []
	pos = 0
	for s, e in spans:
		if s < pos:
			continue
		out.append(text[pos:s])
		if (s, e) in a.message_spans:
			out.append("")  # content of an assert message
		else:
			out.append(" ")
		pos = e
	out.append(text[pos:])
	# Message spans are inner string content, so the quotes remain in the output.
	rebuilt = "".join(out)
	view = _normalize_lines(rebuilt)
	return view


# ---------------------------------------------------------------------------------------------
# Segment text format
# ---------------------------------------------------------------------------------------------

def format_segment(seg: Segment) -> str:
	out = [f"@@ {seg.sid} {seg.kind} {seg.path}:{seg.line}"]
	if seg.context:
		out.append("~ " + seg.context)
	if seg.note:
		out.append("~ " + seg.note)
	for ln in seg.lines:
		if ln.startswith("@@ ") or ln.startswith("~ ") or ln == "~":
			raise ValueError(f"{seg.path}:{seg.line}: text line starts with a reserved marker: {ln!r}")
		out.append(ln)
	return "\n".join(out) + "\n"


@dataclass
class Translated:
	sid: str
	kind: str
	path: str
	line: int
	lines: list[str]
	source: str  # file the block came from


def parse_segment_file(path: Path) -> list[Translated]:
	text = path.read_text(encoding="utf-8")
	if text.startswith("﻿"):
		text = text[1:]
	blocks: list[Translated] = []
	cur: Translated | None = None
	body: list[str] = []

	def flush() -> None:
		nonlocal cur, body
		if cur is None:
			return
		# Leading "~" context lines are ignored.
		k = 0
		while k < len(body) and (body[k].startswith("~ ") or body[k] == "~"):
			k += 1
		lines = [ln.rstrip("\r") for ln in body[k:]]
		while lines and lines[0].strip() == "":
			lines.pop(0)
		while lines and lines[-1].strip() == "":
			lines.pop()
		cur.lines = lines
		blocks.append(cur)
		cur = None
		body = []

	for raw in text.split("\n"):
		if raw.startswith("@@ "):
			flush()
			parts = raw[3:].split(" ", 2)
			if len(parts) < 3 or ":" not in parts[2]:
				raise ValueError(f"{path}: malformed header: {raw!r}")
			where, _, ln = parts[2].rpartition(":")
			cur = Translated(parts[0], parts[1], where, int(ln) if ln.isdigit() else 0, [], str(path))
		elif cur is not None:
			body.append(raw)
	flush()
	return blocks


# ---------------------------------------------------------------------------------------------
# Rendering and validation of translations
# ---------------------------------------------------------------------------------------------

BBCODE = re.compile(
	r"\[/?(?:code|codeblock|codeblocks|gdscript|csharp|param|member|method|signal|constant|enum|"
	r"class|annotation|theme_item|b|i|u|s|br|center|url|img|color|font|kbd|lb|rb|indent|ul|ol|li|"
	r"table|cell|p|bgcolor|fgcolor|outline_color|outline_size|font_size|hint|rainbow|pulse|wave|"
	r"tornado|shake|fade)(?:[ =][^\]]*)?\]"
)
BACKTICK = re.compile(r"`[^`\n]+`")


def _unescaped_quote(text: str, quote: str) -> bool:
	i = 0
	while i < len(text):
		if text[i] == "\\":
			i += 2
			continue
		if text[i] == quote:
			return True
		i += 1
	return False


_ENDS_BACKSLASH = re.compile(r"(?<!\\)(?:\\\\)*\\$")


def validate(seg: Segment, new_lines: list[str]) -> str | None:
	"""Returns the reason to reject a translation, or None if it is valid."""
	if not new_lines:
		return "empty translation"
	new_text = "\n".join(new_lines)
	if seg.single_line and len(new_lines) != 1:
		return "the result spans more than one line (this kind must stay on one line)"
	if seg.kind == "gotest":
		return validate_gotest(seg, new_text)
	if seg.kind == "assert":
		old_pct = PERCENT.findall(seg.text)
		new_pct = PERCENT.findall(new_text)
		if old_pct != new_pct:
			return f"the % markers changed: {old_pct} -> {new_pct}"
		if _unescaped_quote(new_text, seg.style["quote"]):
			return f"unescaped {seg.style['quote']} quote in the string"
		if _ENDS_BACKSLASH.search(new_text):
			return "the text ends with a backslash"
		old_text = seg.text
		if old_text[:len(old_text) - len(old_text.lstrip())] != new_text[:len(new_text) - len(new_text.lstrip())] or 				old_text[len(old_text.rstrip()):] != new_text[len(new_text.rstrip()):]:
			return "the spaces at the start or end changed (the string is probably joined with +)"
		return None
	a, b = sorted(BBCODE.findall(seg.text)), sorted(BBCODE.findall(new_text))
	if a != b:
		return f"BBCode tags changed: {a} -> {b}"
	a, b = sorted(BACKTICK.findall(seg.text)), sorted(BACKTICK.findall(new_text))
	if a != b:
		return f"`code` spans changed: {a} -> {b}"
	if seg.kind == "godoc":
		old_first = seg.lines[0].split()[0]
		parts = new_lines[0].split()
		if not parts or parts[0] != old_first:
			return f"the first word of the Go doc comment must stay '{old_first}'"
	if seg.kind == "docstring":
		q = seg.style["quote"]
		if len(q) == 3:
			if q in new_text or new_text.endswith(q[0]):
				return "the docstring contains its own closing quotes"
		elif _unescaped_quote(new_text, q):
			return "unescaped quote in the docstring"
		if _ENDS_BACKSLASH.search(new_text):
			return "the text ends with a backslash"
	if "block" in seg.style and "*/" in new_text:
		return "contains */ inside a block comment"
	return None


def render(seg: Segment, new_lines: list[str]) -> str:
	if seg.kind in ("assert", "gotest"):
		return new_lines[0]
	if seg.kind == "docstring":
		return render_docstring(seg, new_lines)
	if "block" in seg.style:
		return render_block_segment(seg, new_lines)
	return render_line_segment(seg, new_lines)
