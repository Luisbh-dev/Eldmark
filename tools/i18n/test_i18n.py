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


GO_TEST_SRC = """package x

import "testing"

type harness struct {
	T *testing.T
}

func (h *harness) Logf(format string, args ...any) {
	h.T.Helper()
	h.T.Logf("[%5.1f s] %s", 1.5, fmt.Sprintf(format, args...))
}

func must(t *testing.T, ok bool, msg string) {
	t.Helper()
	if !ok {
		t.Fatal(msg)
	}
}

func label(t *testing.T, what string) {
	t.Fatalf("%s roto: %v", what, 1)
}

func TestX(t *testing.T) {
	t.Errorf("valor %d de %q\\n", 1, "no")
	t.Fatal("uno " + "dos", err)
	t.Skipf("sin base de datos")
	t.Fatalf("%s: %v", name, strings.Join(bad, "; sin"))
	h.Logf("arranca %s", name)
	must(t, ok, "fallo del helper")
	label(t, "etiqueta libre")
	t.Fatal(err)
	fmt.Errorf("no es un test")
	err.Error()
	t.Fatalf(`bruto %v`, 1)
}
"""


class GoTestMessages(unittest.TestCase):
	PATH = "platform/x/x_test.go"

	def got(self) -> list[L.Segment]:
		return [s for s in segs(self.PATH, GO_TEST_SRC) if s.kind == "gotest"]

	def first(self, prefix: str) -> L.Segment:
		return next(s for s in self.got() if s.text.startswith(prefix))

	def test_extraction(self):
		self.assertEqual(
			[s.text for s in self.got()],
			[
				"%s roto: %v", "valor %d de %q\\n", "uno ", "dos", "sin base de datos",
				"arranca %s", "fallo del helper", "bruto %v",  # "%s: %v" and the Logf prefix have no words
			],
		)

	def test_not_in_production_code(self):
		self.assertEqual([s for s in segs("platform/x/x.go", GO_TEST_SRC) if s.kind == "gotest"], [])

	def test_helpers(self):
		self.assertEqual(L.go_helpers_of(GO_TEST_SRC), {"Logf": 0, "must": 2})

	def test_verbs(self):
		s = self.first("valor")
		self.assertIsNotNone(L.validate(s, ["value %s of %q\\n"]))
		self.assertIsNotNone(L.validate(s, ["value of %q %d\\n"]))
		self.assertIsNone(L.validate(s, ["value %d of %q\\n"]))

	def test_quotes_lines_and_escapes(self):
		s = self.first("valor")
		self.assertIsNotNone(L.validate(s, ['value %d of "%q"\\n']))
		self.assertIsNone(L.validate(s, ['value %d of \\"%q\\"\\n']))
		self.assertIsNotNone(L.validate(s, ["value %d of %q", "second"]))
		self.assertIsNotNone(L.validate(s, ["value %d of %q"]))  # lost the \n escape
		self.assertIsNotNone(L.validate(s, ["value %d of %q\\q"]))
		self.assertIsNotNone(L.validate(s, ["value %d of %q\\n\\"]))
		raw = self.first("bruto")
		self.assertIsNotNone(L.validate(raw, ["raw `%v`"]))
		self.assertIsNone(L.validate(raw, ["raw %v"]))

	def test_end_spaces(self):
		s = self.first("uno ")
		self.assertIsNotNone(L.validate(s, ["one"]))
		self.assertIsNone(L.validate(s, ["one "]))

	def test_roundtrip_changes_only_messages(self):
		out = apply(self.PATH, GO_TEST_SRC, en)
		self.assertIn('t.Fatal("EN uno " + "EN dos", err)', out)
		self.assertIn('t.Errorf("EN valor %d de %q\\n", 1, "no")', out)
		self.assertIn('strings.Join(bad, "; sin")', out)  # nested literal: not a message
		self.assertIn('fmt.Errorf("no es un test")', out)
		self.assertIn('label(t, "etiqueta libre")', out)  # the parameter is not only a message

	def test_checker_view(self):
		base = L.code_view(self.PATH, GO_TEST_SRC)
		changed = GO_TEST_SRC.replace('t.Skipf("sin base de datos")', 't.Skipf("sin base de datos", 7)')
		self.assertNotEqual(base, L.code_view(self.PATH, changed))
		changed = GO_TEST_SRC.replace('strings.Join(bad, "; sin")', 'strings.Join(bad, "; con")')
		self.assertNotEqual(base, L.code_view(self.PATH, changed))
		changed = GO_TEST_SRC.replace('"sin base de datos"', '"database missing"')
		self.assertEqual(base, L.code_view(self.PATH, changed))


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


class GoHelperCacheOrder(unittest.TestCase):
	"""A helper declared in the first file (alphabetically) must be seen from the other files."""

	DECL = """package x

func (h *H) Logf(format string, args ...any) {
	h.t.Logf(format, args...)
}
"""
	USE = """package x

func TestA(t *testing.T) {
	h.Logf("el bot ha jugado %d", 1)
}
"""

	def test_helper_declared_in_first_file(self):
		import tempfile
		old_root = L.REPO_ROOT
		with tempfile.TemporaryDirectory() as tmp:
			d = Path(tmp) / "pkg"
			d.mkdir()
			(d / "a_test.go").write_text(self.DECL, encoding="utf-8")
			(d / "b_test.go").write_text(self.USE, encoding="utf-8")
			L.REPO_ROOT = Path(tmp)
			L._GO_HELPER_CACHE.clear()
			try:
				# the declaring file is analysed first, as the extractor does (sorted order)
				segs("pkg/a_test.go", self.DECL)
				found = [s.text for s in segs("pkg/b_test.go", self.USE) if s.kind == "gotest"]
			finally:
				L.REPO_ROOT = old_root
				L._GO_HELPER_CACHE.clear()
		self.assertEqual(found, ["el bot ha jugado %d"])


if __name__ == "__main__":
	unittest.main()
