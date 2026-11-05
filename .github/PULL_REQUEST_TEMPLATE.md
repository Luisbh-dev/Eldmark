## What and why

<!-- Describe the change and link the issue (Fixes #123). -->

## Checklist

- [ ] The full test suite passes locally (`godot --headless --path . -s res://tests/run_tests.gd`) and I added or updated tests
- [ ] Style: static typing everywhere, tabs, identifiers, comments and assert messages in English
- [ ] Architecture: `scripts/shared/` does not depend on client or server; client and server do not depend on each other
- [ ] Scenes and resources are text (no binary `.scn`/`.res`, except Terrain3D regions)
- [ ] New assets have a compatible license (CC0, CC BY, OFL or MIT), are recorded in `assets/LICENSES.md` and `LICENSE-ASSETS.md`, and binaries are normal files under 50 MB (no Git LFS)
- [ ] Docs updated if behavior changed
- [ ] Screenshots or a short clip attached for visual changes

## Screenshots

<!-- Before / after, if the change is visual. -->
