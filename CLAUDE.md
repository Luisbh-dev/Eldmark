# Eldmark

A 3D medieval fantasy MMORPG in Godot 4.7 (GDScript). Third-person action combat in the style of New World: over-the-shoulder camera, crosshair, block and dodge.

Three realms, each with its own zones, cities and a wall surrounding it, plus a central war zone with capturable forts and castles. Design and roadmap in `docs/vision.md`: read it before making design decisions.

Eldmark is an open source project: the code is MIT-licensed, the assets made by the project are CC BY 4.0, and third-party assets keep their own license as recorded in `assets/LICENSES.md`.

## Architecture

- A single Godot project for client and server. The dedicated server runs in headless mode.
- World split into independent zones (each zone has its own map and server process), not a continuous world.
- Authoritative server: the client sends intents (input, abilities) and the server decides the outcome.
- Networked action combat: client-side prediction for the local player, interpolation for everyone else and lag compensation (hitbox rewind) on the server to validate hits.
- `scripts/shared/` must not depend on anything in `scripts/client/` (camera, UI, input) so that the server can load it without problems.
- `scripts/shared/` also does not depend on `scripts/server/`, and `scripts/server/` and `scripts/client/` do not depend on each other (checked by `tests/test_architecture.gd`).

## Conventions

- Follow the official GDScript style guide: files and variables in `snake_case`, `class_name` in `PascalCase`, tabs.
- Always use static typing (`var speed: float = 5.0`, `func move(dir: Vector3) -> void`).
- Identifiers, comments, doc comments and documentation in English. UI text and runtime log messages stay in Spanish until localization lands (see the backlog). Files changed by the pending quality-waves branch (wip/o2-integracion) still have Spanish comments and docs; translate them with tools/i18n after merging.
- Scenes and resources in text format (`.tscn`, `.tres`). No binary `.scn`/`.res`. The only exception: the Terrain3D region `.res` files, which go through Git LFS.
- Large binaries (models, textures, audio, GDExtension DLLs) go through Git LFS; see `.gitattributes`.

## Assets

- Art direction: the Quaternius "Universal + MegaKit" family (stylized with textures, heroic proportions), a single kit recolored per realm. Details in `docs/art.md`.
- The original zips are kept outside the repo, in `../Eldmark-raw/<pack>/`. Only the glTF files and textures that are used go into the repo.
- Every pack that enters the repo is recorded in `assets/LICENSES.md` (author, version, date, URL, license).
- Animations: variants without root motion. Movement is decided by the shared simulation, not by the animation. The server does not play animations.

## Running Godot from the terminal

The winget `godot` alias may not be on the PATH. The console executable is at:

```
%LOCALAPPDATA%\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7.2-stable_win64_console.exe
```

- Import resources and validate the project: `godot --headless --path . --import`
- Run the main scene without a window: `godot --headless --path . --quit-after 120`
