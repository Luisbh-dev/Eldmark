# Contributing to Eldmark

Thanks for your interest in Eldmark, an open source 3D medieval-fantasy MMORPG built with
Godot 4 and GDScript. It is both a playable game with its own identity and a documented
foundation (authoritative server, zones, client-side prediction, interpolation, lag
compensation, bots, tests) that you can study or reuse. Contributions of every size are
welcome: bug reports, docs, tests, art, sound and code.

Issues and pull requests are accepted in **English or Spanish**.

## Requirements

- [Godot 4.7.2](https://godotengine.org/) (standard build, not .NET)
- Git (no Git LFS needed)
- Go (see `platform/go.mod`), only if you work on the platform service in `platform/`

## Setting up

```bash
git clone https://github.com/Luisbh-dev/Eldmark
cd Eldmark
godot --headless --path . --import   # imports resources and validates the project
```

Models, textures, audio and native addon binaries are normal files in the repository, so a
plain clone is enough. Git LFS is not used any more: its monthly bandwidth quota on GitHub would run out
with a few dozen clones. Commits from before that change still hold LFS pointers in the history, which
is harmless for a fresh checkout of the current tree.
To build a commit from before the change (for example with `git bisect`), install Git LFS and run
`git lfs pull`; this uses the LFS bandwidth quota.

## Running the client, the server and the bots

See [docs/getting-started.md](docs/getting-started.md) for how to run the client, a
dedicated headless zone server and the bots. To open the project in the editor, load
`project.godot` and press F5.

Automated scripts and CI must use `--headless` and never open game windows.

## Running the tests

From the project root:

```bash
# Full suite
godot --headless --path . -s res://tests/run_tests.gd

# Only the tests whose name ("file::method") contains some text
godot --headless --path . -s res://tests/run_tests.gd -- --filter=replay

# One part of the suite (K of N); CI runs 4 parts in parallel
godot --headless --path . -s res://tests/run_tests.gd -- --shard=1/4
```

The runner exits with code 0 if everything passes and 1 otherwise. A test also fails if a
script or engine error is logged while it runs. The GitHub Actions workflow
(`.github/workflows/tests.yml`) runs the whole suite on every pull request, so your PR must
be green. Add or update tests for the behavior you change. Test files are `tests/test_*.gd`
and extend `TestCase`; test methods start with `test_`.

## Code style

- Follow the [official GDScript style guide](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_styleguide.html).
- Indent with tabs. Files and variables in `snake_case`, `class_name` in `PascalCase`.
- Always use static typing: `var speed: float = 5.0`, `func move(dir: Vector3) -> void`.
- Identifiers, comments, documentation comments (`##`), assert messages and the failure messages of the Go tests are in English.
  In-game UI text and runtime log messages are currently in Spanish; localization is
  being rolled out in increments (see [docs/localization.md](docs/localization.md)),
  so keep new interface strings in Spanish until the file they live in is migrated, and
  in one place where they are easy to extract.
- Scenes and resources are text (`.tscn`, `.tres`). Do not commit binary `.scn` or `.res`
  files. The only exception is Terrain3D region data (`.res`), which is committed as a normal binary file.

## Architecture rules

The design is documented in [docs/vision.md](docs/vision.md) and [docs/networking.md](docs/networking.md); combat in
[docs/combat.md](docs/combat.md), the Vado Gris in [docs/zones/vado_gris.md](docs/zones/vado_gris.md) and the
visual quality plan in [docs/quality.md](docs/quality.md). The essentials:

- The server is **authoritative**. Clients send intents (input, abilities) and the server
  decides the outcome.
- `scripts/shared/` must not depend on `scripts/client/` (camera, UI, input) or on
  `scripts/server/`, so the headless server can load it.
- `scripts/server/` and `scripts/client/` must not depend on each other.
- `tests/test_architecture.gd` checks these rules. Do not weaken it to make a change pass.
- Movement is decided by the shared simulation, never by animation. The server does not play
  animations.

## Assets policy

- Only add assets with a license compatible with a public repository: CC0, CC BY, SIL OFL
  or MIT. No "free for personal use" packs, no non-commercial or no-derivatives licenses, and
  nothing taken from other games.
- Keep original zips outside the repo (`../Eldmark-raw/<pack>/`). Only the glTF files and
  textures that are actually used go into the repo.
- Record every pack you add in [assets/LICENSES.md](assets/LICENSES.md) (author, version, date, URL, license)
  and, for third-party material, in [LICENSE-ASSETS.md](LICENSE-ASSETS.md).
- Binaries (models, textures, audio, GDExtension libraries) are committed as normal files, marked
  `binary` in `.gitattributes`. Keep every file under 50 MB, prefer compressed formats (`.glb`, `.ogg`,
  `.webp`, lossless PNG only where needed) and do not commit heavy intermediate versions (source
  `.blend` or `.psd` files, uncompressed renders or `.wav` masters); keep those outside the repo.
- Use animation variants **without root motion**.
- Follow the art direction in [docs/art.md](docs/art.md): one stylized kit, recolored per realm. Visual changes are
  judged against the criteria in [docs/quality.md](docs/quality.md); the capture bench in `tools/quality/` regenerates
  the before and after images (see [docs/getting-started.md](docs/getting-started.md#quality-capture-bench)).
- Fonts must be SIL OFL (or similar) and keep their license text next to the file in `assets/fonts/`.
- By contributing, you agree that your code is released under the MIT license and your
  original assets under CC BY 4.0 (see [LICENSE-ASSETS.md](LICENSE-ASSETS.md)).

## Pull request workflow

1. Open an issue first for anything large, so we can agree on the approach.
2. Create a branch from `main` (for example `fix/dodge-cooldown`).
3. Keep changes focused: one topic per PR.
4. Run the full test suite locally and make sure it passes.
5. Open the PR using the template: describe what and why, link the issue, and attach
   **screenshots or a short clip for any visual change**.
6. Respond to review comments. The maintainer merges when CI is green.

## Roadmap

The vision and roadmap are in [docs/vision.md](docs/vision.md); the task breakdown is in
`docs/backlog.md`.

## Conduct and security

Be kind: see [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). To report a security problem, see
[SECURITY.md](SECURITY.md) and do not open a public issue.
