# Hit effects (ART-09): how they are made and how they are checked

Everything is original content, generated with code and versioned: textures with numpy and PIL
(`make_vfx_textures.py`, fixed seeds), scenes and materials with Godot (`build_vfx_scenes.gd`) and
hand-written shaders (`scenes/vfx/shaders/`). Only the text results and the PNGs (through LFS) are committed to Git;
everything else is regenerated.

## Regenerating

From the project root, with the editor closed:

```
python tools/vfx/make_vfx_textures.py
godot --headless --path . --import
godot --headless --path . -s res://tools/vfx/build_vfx_scenes.gd
godot --headless --path . --import
godot --headless --path . -s res://tests/run_tests.gd -- --filter=test_vfx
```

The numbers of each effect (sizes, times, speeds, colors) are in `build_vfx_scenes.gd`; nothing is
tweaked by hand in the `.tscn` files. The texture script does not rewrite the `.import` files that already exist (Godot
gives them their own uid and changing it would break everything that references them).

## What each thing is

| Effect | Scene | What sets it apart |
|---|---|---|
| Metal spark | `hit_metal_spark` | Incandescent point of 0.06 s, flash, tailed sparks in a cone that tilts with the slash (`direction_bias`) and slow down within 1.5 m, splinters that are born red-hot. |
| Flesh | `hit_flesh` | Two spurts from a five-frame sequence (4 variants by 2 reflections), 0.4 m and 0.2 s, oriented along the hit direction; dark red with a sheen. |
| Cloth | `hit_cloth` | Pale puff with light and falling threads. |
| Block | `hit_block_wood` | Dull thud: a muted flash pushed toward the camera, a flattened half ring on the shield face, flat two-tone splinters (max. 1.5 m) and brown dust. |
| Parry | `parry_flash` | Star with rays, horizontal lens flare and a thin shockwave on the plane of impact. 0.25 s in total; it does not cover the opponent's face. |
| Dust | `dust_kick` | Landing: low puffs in a ring (and a 1.2 m ring only on hard falls). Dodge: a crescent hugging the ground and sprayed backward. With light and shadow; ground color (`VfxGround`), not realm color. |
| Trail | `weapon_trail` | Ribbon that follows the blade's arc around the hand, with at least three samples, a tail that narrows and fades, taken when the skeleton updates. Colors per realm. |
| Charge aura | `charge_aura` | On the weapon, not the body: glow along the blade that grows with the charge, motes and absorbed embers, heat and the ground rune; flash and flat wave on reaching the maximum and on release. |

The reuse architecture (`VfxEffect`, `VfxPool`, the metadata `vfx_time`, `vfx_cue`, `vfx_tint`,
`vfx_variants`) is explained in the header of `scripts/client/vfx/vfx_effect.gd`. None of this is
hooked into combat yet.

## Checking (the bar from `docs/quality.md`)

`render_strips.ps1` opens `scenes/tests/vfx_preview.tscn` in a window, deterministically (`--fixed-fps 60`):

```
powershell -File tools/vfx/render_strips.ps1 -Out build/vfx/strips -Realms -Shade -Bench
powershell -File tools/vfx/render_strips.ps1 -Out build/vfx/strips_cerca -Camera demo -Strips metal_side,flesh,block,parry,dust,dodge,trail,aura
powershell -File tools/vfx/render_strips.ps1 -Out build/vfx/strips -Strips flesh -Reel 60
```

- **Game camera** (default): the real `CameraRig` (72-degree field of view, over the shoulder),
  over the Vardheim camp at Vado Gris with its sun, shadows and fog. It is what the player sees.
- **Close-ups** (`-Camera demo`): 40-degree field of view over a flat ground, to check the detail.
- **Shade** (`-Shade`): the same dust under a roof that only casts a shadow; `sombra_vs_sol.png` compares them.
- **Melee** (`-Bench`): ten effects at once plus the trail and the aura, against the same scene without effects;
  it writes `bench.json` with draw calls, objects, primitives and GPU and CPU times.
- **Video** (`-Reel 60`): one minute with `--write-movie`, with the four realms, a stretch in shade and a melee.
  Without sound (the game has no audio yet).

The tests (`tests/test_vfx.gd`) pin the design numbers: no camera-facing rings or filler, times
and sizes of the parry and the block, maximum reach of sparks, splinters and drops, a minimum of three trail
samples, ground dust and not realm dust.
