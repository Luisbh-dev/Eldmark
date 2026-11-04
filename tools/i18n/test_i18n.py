#!/usr/bin/env python3
"""Self-tests of the i18n tools. Run: python -I tools/i18n/test_i18n.py"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import i18nlib as L  # noqa: E402
import rename_doc_refs as R  # noqa: E402


def segs(path: str, text: str) -> list[L.Segment]:
	return L.analyze(path, text).segments


def apply(path: str, text: str, translate) -> str:
	ana = L.analyze(path, text)
	out = text
	for s in sorted(ana.segments, key=lambda s: s.start, reverse=True):
		new = translate(s)
		reason = L.validate(s, new)
		assert reason is None, reason
		out = out[:s.start] + L.render(s, new) + out[s.end:]
	assert L.code_view(path, out) == L.code_view(path, text)
	return out


def en(seg: L.Segment) -> list[str]:
	return ["EN " + ln if ln else ln for ln in seg.lines]


class GdScript(unittest.TestCase):
	def test_strings_hide_hashes(self):
		src = 'var a: String = "x # no" # el comentario real\nvar b = """\n# tampoco\n"""\n'
		got = segs("a.gd", src)
		self.assertEqual([s.lines for s in got], [["el comentario real"]])

	def test_blocks_and_region(self):
		src = "## Hace algo.\n## [param x] es el valor.\nfunc f(x):\n\t# otra cosa\n\t# mas cosas\n\tpass\n#region Zona uno\n#endregion\n"
		got = segs("a.gd", src)
		self.assertEqual([s.kind for s in got], ["doc", "comment", "region"])
		out = apply("a.gd", src, en)
		self.assertIn("#region EN Zona uno", out)
		self.assertIn("\t# EN otra cosa\n\t# EN mas cosas", out)

	def test_assert_messages(self):
		src = (
			'extends TestCase\nfunc t():\n\tassert_eq(a, "x, y", "valor %d de %s" % [1, "z"])\n'
			'\tassert_true(ok, "uno " + str(a) + " dos")\n\tassert_true(ok)\n\tfail("roto")\n'
		)
		got = [s.lines[0] for s in segs("tests/t.gd", src)]
		self.assertEqual(got, ["valor %d de %s", "uno ", " dos", "roto"])
		self.assertEqual(segs("scripts/t.gd", src), [])

	def test_assert_rules(self):
		s = segs("tests/t.gd", 'func t():\n\tassert_true(ok, "valor %d dos")\n')[0]
		self.assertIsNotNone(L.validate(s, ["valor %s dos"]))
		self.assertIsNotNone(L.validate(s, ['valor " dos %d']))
		self.assertIsNone(L.validate(s, ['valor \\" dos %d']))
		self.assertIsNotNone(L.validate(s, ["valor %d", "dos"]))

	def test_bbcode_and_backticks(self):
		s = segs("a.gd", "## Usa [code]foo[/code] y `bar`.\nvar x\n")[0]
		self.assertIsNotNone(L.validate(s, ["Usa foo y `bar`."]))
		self.assertIsNotNone(L.validate(s, ["Uses [code]foo[/code] and `baz`."]))
		self.assertIsNone(L.validate(s, ["Uses [code]foo[/code] and `bar`."]))

	def test_inline_single_line(self):
		s = segs("a.gd", "var a = 1  # pista corta\n")[0]
		self.assertIsNotNone(L.validate(s, ["a", "b"]))


class GoPython(unittest.TestCase):
	def test_go_directives_and_output(self):
		src = (
			"package x\n\n// Foo hace algo.\n//\n// Sigue el texto.\n//go:noinline\nfunc Foo() {}\n\n"
			"func ExampleFoo() {\n\t// Output:\n\t// hola\n}\n"
		)
		got = segs("a_test.go", src)
		self.assertEqual([s.kind for s in got], ["godoc"])
		self.assertIsNotNone(L.validate(got[0], ["Does something.", "", "More."]))
		self.assertIsNone(L.validate(got[0], ["Foo does something.", "", "More."]))

	def test_go_block_comment(self):
		src = "package x\n/*\n * Hola mundo.\n * Segunda linea.\n */\nvar a = \"// no\" // si comentario\n"
		out = apply("a.go", src, en)
		self.assertIn("/*\n * EN Hola mundo.\n * EN Segunda linea.\n */", out)
		self.assertIn('"// no" // EN si comentario', out)

	def test_python(self):
		src = '"""Docstring del modulo.\n\nMas texto.\n"""\n# -*- coding: utf-8 -*-\nx = "#no"  # comentario\n\n\ndef f():\n\t"""Una linea."""\n'
		got = segs("a.py", src)
		self.assertEqual([s.kind for s in got], ["docstring", "inline", "docstring"])
		out = apply("a.py", src, en)
		self.assertIn('"""EN Docstring del modulo.\n\nEN Mas texto.\n"""', out)

	def test_hash_languages(self):
		src = "#!/bin/sh\n# Texto del script\necho hola # no se toca\n"
		got = segs("a.sh", src)
		self.assertEqual([s.lines for s in got], [["Texto del script"]])


class Rename(unittest.TestCase):
	def rw(self, text: str, rel: str = "docs/x.md") -> str:
		return R.rewrite(rel, text)[0]

	def test_matches(self):
		self.assertEqual(self.rw("ver docs/red.md#a y red.md \u00a74"), "ver docs/networking.md#a y networking.md \u00a74")
		self.assertEqual(self.rw("[fuerte.md](../fuerte.md)"), "[fortress.md](../fortress.md)")
		self.assertEqual(self.rw("`informe_noche.md`"), "`history/2026-10-night-report.md`")
		self.assertEqual(self.rw("docs/capturas/a.png y ](capturas/b.png)"), "docs/screenshots/a.png y ](screenshots/b.png)")

	def test_false_positives(self):
		for text in ["shared.md", "my-red.md", "scripts/red.md", "red.mdx", "red.md-old", "C:/capturas/demo", "bored.md"]:
			self.assertEqual(self.rw(text), text)


if __name__ == "__main__":
	unittest.main()
