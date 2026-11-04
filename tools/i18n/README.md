# i18n tools: translating comments without touching the code

These scripts move the project's comments (and the messages of the test assertions) from Spanish
to English. **A model never edits the code.** The text is extracted into plain segment files,
translated separately and injected back; a checker then proves that nothing but comments changed.
Python 3.14, standard library only.

## The segment format

```
@@ <id> <kind> <path>:<line>
~ optional context line (the next line of code), ignored when applying
the original text, without comment prefix or indentation
(the block ends at the next line that starts with "@@ ")
```

Kinds: `doc` (GDScript `##`), `comment`, `inline` (comment after code), `region`, `docstring`
(Python), `godoc` (Go doc comment: the first word must stay the identifier), `assert` (message
string of a test assertion). Consecutive full-line comments with the same indentation and prefix
form one multi-line segment; the translation may have a different number of lines.

## Tools

| Tool | What it does |
| --- | --- |
| `extract_comments.py` | Extracts segments from GDScript, Python, Go, shaders, YAML, shell, PowerShell, Dockerfile, Caddyfile and dot-files. `--lanes N --out-dir DIR --manifest FILE` splits the work into N balanced lanes (whole files, grouped by folder). |
| `apply_translations.py` | Validates and injects translated segment files. `--dry-run` only reports. Rejects a segment (and leaves it as it was) when the id or the original text no longer matches, when `%` markers, BBCode tags or `` `code` `` spans change, when an assert string gets an unescaped quote or a line break, when a one-line segment grows to several lines, or when a Go doc comment loses its identifier. It also refuses to write a file whose code would change. |
| `check_comment_only.py` | Proves that the files changed against a base (`--base main`) differ only in comments (token stream for GDScript, Go and shaders; `ast.dump` without docstrings for Python). In `tests/` the assertion messages may change too. Exit code 1 on any other change. |
| `rename_doc_refs.py` | Rewrites references to the renamed documents (`docs/red.md` -> `docs/networking.md`, with or without `docs/`, with word boundaries). `--dry-run` lists every replacement. It does not run `git mv`. |
| `find_spanish.py` | Heuristic detector of Spanish left in comments and `.md` files (function words, accents, inverted marks). Lists `file:line`. |
| `test_i18n.py` | Self-tests: `python -I tools/i18n/test_i18n.py`. |

`i18nlib.py` is the shared code: lexers, segment builders and the validation rules.

## Workflow

```sh
# 1. Extract (the exclude file lists paths that must not be touched yet)
python tools/i18n/extract_comments.py --exclude-file build/i18n/exclude.txt \
    --lanes 16 --out-dir build/i18n/segments --manifest build/i18n/manifest.json

# 2. Translate each lane_XX.txt into build/i18n/translated/lane_XX.txt
#    (same format; keep the "@@" header lines and the ids exactly)

# 3. Check, then apply
python tools/i18n/apply_translations.py build/i18n/translated/lane_*.txt --dry-run
python tools/i18n/apply_translations.py build/i18n/translated/lane_*.txt

# 4. Prove that only comments changed, and look for leftovers
python tools/i18n/check_comment_only.py --base main
python tools/i18n/find_spanish.py
```

Rules for the translator: keep BBCode tags (`[code]`, `[param x]`...) and `` `code` `` spans as they
are, keep `%s`/`%d` markers in the same order, keep the spaces at the ends of assert strings, and
start every Go doc comment with the identifier it documents.

The files of the pending quality-wave branch (`wip/o2-integracion`) were left out of the first
pass on purpose. Checklist for the pass after that branch is merged:

1. Get the path list with `git diff --name-only main...wip/o2-integracion` **before** merging (the
   first pass kept it in `build/i18n/exclude_o2.txt`, which is not versioned), or commit it.
2. Extract with an empty exclude file restricted to those paths, translate, apply, and run
   `check_comment_only.py`.
3. Run `rename_doc_refs.py` on those paths (about 45 of them still cite old doc names such as
   `plataforma.md` or `red.md`).
4. Pick English names for the deferred docs (`combate.md`, `calidad.md`, `backlog.md`, `zonas/`) and
   for `assets/LICENCIAS.md` (-> `assets/LICENSES.md`; update `CLAUDE.md`, `CONTRIBUTING.md`, the PR
   template, `export_presets.cfg`, `tests/test_assets.gd` and `tests/test_export_config.gd`),
   add them to `DOC_RENAMES` in `rename_doc_refs.py` and `git mv` them.
5. Re-point the links from already translated docs to the Spanish anchors of `combate.md`
   (`networking.md`, `abilities.md`, `fortress.md`) and the links inside the translated deferred docs.
6. Check that no internal link or anchor is broken (there is no versioned link checker yet; write one
   in `tools/i18n/` when doing this pass).
7. Add `docs/getting-started.md`'s `export_presets.cfg` filter for `LICENSE` and `LICENSE-ASSETS.md`.

Known leftovers that are deliberate or deferred:

- The SQL migrations in `platform/internal/migrate/migrations/` keep their Spanish comments and old doc
  names: `migrate.go` rejects a changed SHA-256 for an applied `.up.sql`, so they cannot be edited once
  deployed. The `testdata/seed_*.sql` seeds carry no checksum and are translated.
- The messages of the Go test assertions (`t.Errorf`, `t.Fatalf`, ...) in `platform/**/*_test.go` are
  still in Spanish; the extractor only knows GDScript assert functions. Pending as a follow-up.
- Some `tests/*.gd` helpers with a `label` parameter or case tables still carry Spanish labels.
- Run the Python tools with `python -I -X utf8` on Windows when redirecting their output.
