# Eldmark: visual quality plan

This document is the plan to take the Vado Gris vertical slice from prototype to something decent. It starts from the first windowed playthrough (1 November 2026, server, 8 bots and client), four audits with real screenshots at 1920 × 1080 (animation, map and interface, world and combat) and an asset survey done on 1 November. The screenshots are in `build/calidad/` and their index in `build/calidad/indice.md`. The backlog items that come out of this are in [backlog.md](backlog.md) with the prefix of their area.

Before writing it I reviewed the screenshots behind the serious findings myself and checked in the repo the causes that decide the plan. What does not hold up, or needs qualifying:

- **The red capsules in the review cameras are not part of the game.** `tools/render/render_screenshot_points.gd` places them as a scale reference (`--no-capsules` removes them). There is nothing to fix.
- **UAL2 Standard already ships more than the audits assumed.** The GLB in the repo contains `Idle_Shield_Loop`, `Idle_Shield_Break`, `Sword_Block`, `Sword_Dash`, `Shield_Dash`, `Shield_OneShot`, `Hit_Knockback`, `Melee_Hook`, `LayToIdle`, `Zombie_Idle_Loop`, `Zombie_Walk_Fwd_Loop` and `Zombie_Scratch`. What UAL2 Source really adds is 8-direction walking, the bow, the sprint with shield, the 8-direction zombie and hits such as Groundpound and Uppercut.
- **The rule of playing every clip between 0.7x and 1.5x cannot be met for the dodge.** The only clip is `Roll` (1.35 s) and the dodge lasts 27 ticks (0.45 s). Until there are dedicated dodge clips, the test allows up to 2x for the dodge only.
- **The floating rocks are likely, not certain.** In `mundo/jugador_vardheim/28_ruinas_final_de_calzada.png` there is a rock with no visible contact with the hillside, but at that distance it is not conclusive. What is confirmed is that the generator does not sink the instances according to the slope.
- **The fall pose of a remote NPC (`rem_hueco_ataque_b.png`) is unconfirmed**: the strip does not show whether it is the followed Hollow. It will be repeated with the capture bench (TEC-50).
- **The screenshots cannot be used to judge audio, hitstop or smoothness.** Those findings were checked in the code: `assets/audio/` is empty and nobody listens to `sound_requested` or `swing_active_changed`.
- **The sword for ART-06 cannot safely come from the Fantasy Props MegaKit**: the page does not name swords. The first thing to try is the sword from RPG Weapons Free.
- **The lighting proposed by the world audit clashes with world.md**, which paints the Vado Gris as the border of Eldrun under an overcast sky. It stays as a user decision (section 6).
- **The tools that produced the screenshots are not versioned**: they live in `build/calidad/scripts/`, which Git ignores. Without them no improvement can be demonstrated, so saving them in `tools/` comes first (TEC-50).

---

## 1. Verdict

**Animation.** This is the weakest part and the most noticeable. Idle and locomotion use unarmed clips, so the sword and shield, which are a box and a disc stuck to the hands, point in any direction and there is never a guard. Attacks only move the torso: the legs follow the walk cycle that the lunge triggers and every slash ends in a little hop on one foot, with the shield sticking out behind the shoulder (`animacion/lado/com_combo_completo.png`, frames 2 and 8 to 10). When each segment is rescaled to the combat ticks, speeds range from 0.35x to 3.3x: the heavy attack's windup looks frozen and the recoveries are spasms. The block is a parry with the sword frozen on one frame, with the shield hanging down (`camara_juego/com_bloqueo__mantener.png`). The dodge is a forward somersault even when dodging backwards. The Hollow and the Captain do not have a single attack clip: their unstoppable blow is a man walking (`lado/npc_hollow_ataque_ligero.png`). Half of this is fixed with clips already in the repo and animator code; strafing, the sideways dodge, the bow and the second death require buying UAL1 Pro and UAL2 Source.

**Combat feel.** The simulation works, but on screen the hit does not exist. There is not a single sound, spark, trail or hitstop, and two out of three light attacks do not move the victim. The only signal is a flat red cutout lasting 0.12 s and a number, and a red vignette that tints half the screen at any scratch (`combate/pelea_b_05.png`, at 910 of 1000 health). Hollow, Captain, allies and enemies are the same dummy. Almost all of it is missing content and missing connections: the signals already exist in `CombatFeedback` and nobody listens to them.

**Map and minimap.** The M map is not a map: it is a dump of the terrain paint with stair-stepped camouflage blotches, a poster-blue river, trees as polka dots and a gray band in the west (`mapa/imagen_horneada_vado_gris.png`). It does not look like the misty Vado Gris of the game. The window overlaps labels, leaves the ford, the ruins, the bridges and the chapel unnamed, has no zoom and leaves the HUD underneath. The minimap stretches the edge of the image into stripes as soon as the player nears a boundary, and the spawn camp is always stretched (`mapa/minimapa_06_borde_este_recorte.png`).

**Interface.** It reads like an internal tool in dark mode. There is no custom typography (everything is the engine font), the icons are letters on colored squares and all windows are almost-black rectangles with no frame. The HUD has no hierarchy: 14 keyboard shortcuts, place labels stacked under the crosshair, a compass and a panel off-center by about 300 px (`interfaz/hud_en_pelea_02.png`), and boss, warnings and numbers that overlap each other compete for attention. There are one-line bugs that only show up in a window: the knocked-down warning is cut off on the left (`interfaz/derribado_aviso.png`), a tooltip covers the inventory when it opens and the creation figure appears in the jump pose. Almost all of it is a visual layer still to be done, not systems to redo.

**Scenery.** The Vado Gris is well measured for play (symmetric routes, correct distances and collisions), but visually it is a blockout. The light is flat because two fill lights without shadows match the sun. The terrain looks like felt: watercolor textures with color only, no normals, with 8 to 17 m tiles and rock stretched on the slopes. The fort, which is the objective, is a low box that blends into the enemy wall behind it (`mundo/camaras_revision/vista_desde_puerta_vardheim.png`). The water is a milky sheet, the sky has streaks at the zenith and a blurry sun disc, and prism tents, plain banners and gallows like loose blocks are still in view. Of the Stylized Nature pack already downloaded, 16 of 68 models are used. A large part is fixed with parameters; the relief, the fort and the walls have to be redone as composition.

---

## 2. The bar

"Decent" here means a small indie game with stylized assets that does not embarrass itself in any screenshot: nothing that gives away a placeholder, everything readable in combat and a recognizable identity. It is not an AAA bar. Each criterion is checked by repeating the TEC-50 bench screenshots at 1920 × 1080; those marked with ⓒ are only met after the purchases in section 5.

### Animation

1. In every frame of `loc_*` (side, front and game camera) the shield is in front of the torso and the blade never points backwards or above the head. The fingers of both hands are closed.
2. In `com_ligero_*`, `com_combo_completo` and `com_fuerte__golpe`, with no movement input, the feet stay planted during the windup and the strike, the hips turn toward the strike and the shield does not leave the front of the chest.
3. No attack, block or ability segment plays outside 0.7x to 1.5x of its original speed. A test that crosses `data/animation` with the ticks in `data/combat` checks it; the dodge allows up to 2x until it has its own clips, and NPC windups allow down to 0.3x (they stretch them on purpose; this will change in wave 2 to a 1x segment plus a held pose).
4. Every attack of every `WeaponDefinition` in `data/combat` has an entry in its `CombatClipSet` (automatic test), and the `npc_*` strips show a clip in every frame of the action.
5. Block: seen from the attacker, the shield covers chest and head; the pose breathes (there are no 12 identical frames), it is possible to walk while blocking and every blocked hit gives a visible reaction of 0.15 s or more.
6. In all four dodges the body travels toward where it rolls or jumps. ⓒ With directional clips, the model does not turn more than 15° away from the aim point.
7. Every hit that deals damage is visible on the victim's body, even if it imposes no control. The stagger is full-body with a step back, knocked down is distinguishable from dead and a death while running does not stop dead.
8. ⓒ Strafe and backpedal with their own clips in 8 directions when walking and jogging; on the 1 m grid no planted foot slides more than about 5 cm per step.
9. ⓒ Vertical bow, string drawn to the cheek and released on the shot tick.
10. At 20 m, without nameplates, a Hollow and the Captain are told apart from a player by silhouette, color and way of moving.

### Combat feel

It is checked with the screenshots and with a one-minute video with sound recorded with the engine's Movie Maker mode (`--write-movie`), against two Hollow and a player.

1. Every own hit that lands gives, within its active window, an impact sound depending on the material, a spark or dust at the contact point, a 50 to 80 ms hitstop in the animation and a visible reaction on the victim, light attacks included.
2. Every hit, swing, block and dodge makes a sound, other players' too, in 3D position.
3. A blocked hit gives a spark, a shield sound, a push and a pulse in the stamina. A parry is told apart from a block without reading text.
4. A 90-damage hit tints no more than 10% of the screen, and each color means a single thing (red, own health and damage taken; an NPC's danger, another color).
5. In a melee no body covers more than 30% of the screen for more than an instant.
6. Not a single box or flat disc is left on screen: sword, shield and bow are models, with shadow.
7. Every NPC attack reads on the body at least 0.4 s before the hit, without looking at the ground.

### Map and minimap

1. On the M map, a new player points out within five seconds the fort, the two bridges, the ford, the ruins, the camps and the passes. All of them have a name, no label overlaps another, there are no pixel steps and the mountains frame the valley, in the game's desaturated range.
2. The M map has wheel zoom and drag panning, and with it open the HUD does not show through.
3. The minimap shows no stretched stripe in the six `sc_mapa` positions or in its three zoom levels; icons that touch are merged and the camera cone does not cover the terrain.

### Interface

1. No text uses the engine font: two OFL families everywhere, also in nameplates, health, group frames and statuses (a test that fails if `ThemeDB.fallback_font` reappears in `scripts/client`).
2. No slot carries a letter: every action has a drawn icon, distinguishable at 52 px and in grayscale.
3. In a fight with 12 combatants, compass, fort panel, boss bar and warnings are centered at x = 960 ± 1, nothing overlaps, no place label is within 150 px of the crosshair and the help line is hidden.
4. All text over the world has a contrast of 4.5:1 or more against its plate, not only through an outline.
5. Ally or enemy is told apart at 20 m without aiming.
6. No tooltip appears without hovering the mouse and no window cuts off columns.
7. The title has a logo and an in-engine background, the selection screen shows the figure at rest on a stage and the loading screen gives the zone name with an image.

### Scenery

1. Directional light: on the fort tower and on a wall tower, the lit face has three times or more the luminance of the shaded face, and trees, palisade and towers cast shadows in 80% or more of the 66 player-height views.
2. At 3 m from the camera the terrain shows grain, stones or blades of grass, and no slope steeper than 35° has stretched texture.
3. From both camps and both bridges, the fort tower stands out against the sky, not against the enemy wall, and is the tallest structure in view.
4. In none of the 66 views is there a gap under a rock or a log.
5. At the ford the gravel bed and the current are visible, the deep channel is darker and the river never ends in a visible gap.
6. Looking at any edge there are at least two planes of distant relief and it is never visible where the terrain ends.
7. No `PrismMesh` tents, Kenney flags or noise cloths remain; the banners carry the emblem from `assets/emblems`.
8. The groves read as forest (20 trees or more, with undergrowth) and the bark fits the palette in world.md.
9. The sky has no streaks at the zenith and the sun is consistent with the light.
10. Everything fits the current budget: fewer than 2000 draw calls and 2 M primitives in the `render_screenshot_points.gd` views.

---

## 3. The cheapest wins

Fixes of one session or less, with no purchases, ordered by effect. Together they change the first impression of almost every screenshot.

| Fix | What changes on screen | Effort | Item |
|---|---|---|---|
| Attack clips for Hollow, Captain, guards and guardians with clips from the repo (`Zombie_Scratch`, `Sword_Attack`, `Sword_Regular_C`, `Sword_Heavy_Combo`), and a coverage test | NPCs stop attacking while walking; the Captain's unstoppable blow can be seen coming | S | ART-47 |
| Block with `Idle_Shield_Loop` looping instead of `Sword_Block` frozen | The shield covers the chest; the main defensive verb finally reads | S | ART-48 |
| Remove the two light fills, raise the sun to 2–2.5, lower the ambient to 0.35–0.5 and lengthen the shadows | The valley gains volume and direction in every view | S | ART-54 |
| Proportional damage vignette, only at the edge; brief white flash on the victim | The world stops turning red at every scratch | S | UI-50 |
| Center the compass and fort panel (`grow_horizontal` on two lines), anchor the knocked-down warning and do not show tooltips on mouse focus | The HUD stops being broken in three visible places | S | UI-49 |
| `grounded = true` on the selection, creation and character figure | The figure appears at rest and not in the jump pose | S | UI-49 |
| Hide the help line of 14 shortcuts | The bottom of the screen breathes and the HUD can move down | S | UI-49 |
| Filter the world markers: only the current objective, name when the crosshair gets close | The soup of labels under the crosshair disappears | S | UI-54 |
| Clamp the minimap UVs with a fade to fog and enable mipmaps | The stretched stripes and the mottling disappear | S | UI-52 |
| Orient the model toward the dodge direction during `DODGE` | The somersault goes where the body moves | S | ART-49 |
| Terrain3D projection on slopes and `uv_scale` of 0.25–0.35 | The mountain rock stops stretching into streaks | S | ART-55 |
| Sink rocks and logs according to the slope and remove trees above 45° | Neither rocks nor trees stuck in like pins | S | ART-58 |
| Own material for the bark and bring in the already downloaded Stylized Nature variants | Goodbye salmon-colored trunks; more variety at no cost | S | ART-59 |
| Fade remotes closer than 1.2 m to the camera | No torso fills half the screen | S | ART-53 |
| Shadows on sword and shield (`cast_shadow`) and weapon swap mid-gesture | The weapon exists in the shadow and does not appear by magic | S | ART-06 |
| Cinzel and Noto Sans fonts (free download, OFL) | All screens stop looking like system UI | S | UI-02 |

---

## 4. Waves of work

The order puts first what makes it possible to demonstrate the improvement, then the cheap stuff and then what the user mentioned (animation and map), before the scenery, which is the longest. Wave 6 can start as soon as the purchases arrive, always after wave 2, because it mounts the new clips on the arms layer and the tree that wave 2 leaves behind. Sessions are agent sessions, as in the backlog.

### Wave 0: capture bench (1 session)

**Goal.** To be able to regenerate with one command the screenshots that demonstrate each criterion of the bar.

**Tasks.** TEC-50: move `build/calidad/scripts/` (`anim_strips.gd`, `online_driver.gd`, the `sc_*.gd` and `compose_strips.py`) to `tools/quality/`, with one command per area. Repeat the remote strips with a single isolated bot and save in `meta.json` the clip of the remote layer. Add the missing strips: hit received while blocking, guards and guardians. Add video recording with sound (`--write-movie`).

**Screenshots that demonstrate it.** The regenerated index and a remote strip in which the followed remote is not hidden.

**Status.** Done: `tools/quality/` with `python tools/quality/run.py <area>` (animacion, mapa, interfaz, mundo, combate, video and todo), documented in the README. The remote strips come from a full bot alone on the server (no NPCs), from the fort NPCs, from the realm guards and from the Gate Guardians; each one carries in its `meta.json` the clip that the remote's animation layer plays, its own side view and the mark of the occluded frames. There is a strip for a hit received while blocking and the video with `--write-movie`. The index summarizes per strip how many action frames have a clip (for example, `0/9` on an NPC attack that attacks while walking).

**Depends on the user.** Nothing.

### Wave 1: the cheap stuff (4 to 6 sessions)

**Goal.** Remove the flaws that scream prototype in every screenshot, without buying anything.

**Tasks.** UI-49 (quick interface fixes), UI-50 (damage signals and colors), ART-47 (NPC clips), ART-48 (block with shield), ART-49 (oriented dodge), ART-53 (bodies next to the camera), ART-58 (settled rocks and trees), the first half of ART-54 (light with no fills, shadows), the minimap UVs and mipmaps of UI-52, the marker filter of UI-54 and the weapon shadows of ART-06.

**Screenshots that demonstrate it.** `interfaz/hud_en_pelea_*` (compass and panel at x = 960), `interfaz/derribado_aviso.png` complete, `interfaz/inventario_i.png` and `personaje_c.png` without tooltip, `interfaz/creacion_02_apariencia.png` at rest, `combate/pelea_b_05.png` without full-screen red, `animacion/lado/npc_*_ataque_*` with a clip, `camara_juego/com_bloqueo__mantener.png` with the shield in front, `lado/com_esquiva_*`, `mapa/minimapa_*` without stripes and the 10 review cameras with shadows.

**Status.** Integrated (3 November 2026) the cheap part of UI-49 (points 1 to 5), UI-50, ART-47 (clips, no zombie tree), ART-48 (block with `Idle_Shield_Loop`), ART-49 (oriented dodge), ART-53, ART-58, ART-54 (light only), ART-55 (UV and projection), ART-59 (bark and models), UI-52 (UV and fog), UI-54 (marker filter) and ART-06 (shadows and weapon swap mid-gesture). The full suite passes (2768 tests) and the full set of screenshots was regenerated with `python tools/quality/run.py todo` in `build/calidad_o1/`, with the same framings as the audit. The before-and-after pairs are in `build/comparaciones/`. Checked in the screenshots: compass and panel centered at x = 960, knocked-down warning complete, no tooltip when opening the inventory, creation figure at rest, 70 or 90 hit without tinting the screen, minimap without stripes, shadows in the 10 review cameras (at most 1.93 M primitives and 1151 draw calls, within budget), all NPC attacks with a clip in every action frame and the block with the shield in front of the chest. Still open: the knocked-down warning overlaps with the boss bar (UI-08 and UI-18), the cut-off columns of the scoreboard and the realm selection (UI-49, 6 and 7), the zombie locomotion tree and the NPC visual profile (ART-52), the second half of ART-54, ART-55 and ART-59, and all of wave 2. Two observations from the bench: the `rem_bot_*` strip hung once when closing the client (it was repeated and came out fine) and `rem_guardian_andar` needed a second pass of the Guardian phase.

**Depends on the user.** Approve the download of the fonts (free) if they are wanted already in this wave.

### Wave 2: combat animation with the repo's clips (6 to 8 sessions)

**Goal.** Make the character look armed and give every hit support and weight, without waiting for the purchases.

**Tasks.** ART-45 (combat stance: combat idle with `Idle_Shield_Loop`, arms layer during locomotion and finger grip), ART-46 (full-body attacks with planted feet, shield-arm mask and leg speed without the lunge), the segment trimming of ART-07 (0.7x to 1.5x, automatic test, loop loading), ART-50 (visible reaction to every hit), ART-51 (death with inertia and distinguishable knocked down) and ART-52 (visual profile per NPC type: Hollow without shield, with gray bone and emissive eyes; bigger Captain).

**Screenshots that demonstrate it.** All the `animacion/*/loc_*` and `com_*` strips against animation criteria 1 to 5, 7 and 10; `lado/com_recibir_golpe.png`, `lado/com_muerte_corriendo.png`, `lado/com_derribado.png`; `combate/pelea_b_20.png` with distinguishable Hollow.

**Depends on the user.** If some segment does not fit 0.7x to 1.5x with any clip, decide whether to touch the combat ticks (decision 7). Changing `lunge_speed` affects the balance of CMB-29.

### Wave 3: readable map, minimap and HUD (8 to 10 sessions)

**Goal.** The map the user asked for and a HUD with hierarchy.

**Tasks.** UI-51 (layered map baking in the chosen style, ±256 m so the mountains fit, 2048 px), UI-52 (minimap with mask, fog at the edges, merged icons and soft cone), UI-53 (map window with place names, label placement, zoom, drag and hidden HUD), UI-54 (compass with heading, markers with hierarchy and objective line), UI-55 (composition of the bottom HUD), UI-56 (nameplates without overlaps and faction mark), ART-12 (game-icons.net icons with background and bevel), UI-02 (fonts and the five calls to `ThemeDB.fallback_font`), and the adjustments to UI-18 (boss bar only if you are fighting it), UI-08 (queued warnings over a band) and UI-41 (kill feed with band and icon format).

**Screenshots that demonstrate it.** `mapa/mapa_m_*` and `mapa/imagen_horneada_vado_gris.png` against the map criteria; `mapa/minimapa_*` in the six positions and three zooms; `interfaz/hud_en_pelea_*` and `hud_reposo_campamento.png` against interface criteria 1 to 5; `interfaz/recorte_*`.

**Status of the HUD and interface lane (4 November 2026).** Done: UI-02 (Cinzel and Noto Sans, variable, in `assets/fonts` with their OFLs and noted in LICENSES.md; IM Fell English SC available with `UIFonts.map_label()`; `UIFonts` replaces the five calls to the engine font and a test fails if it reappears), ART-12 (the own icons in `assets/ui/icons` in the action bar, potions, statuses, weapon swap and the weapon and potion items of the inventory; the icon fills almost the whole slot), UI-55 (compact bottom block: slots 24 px from the edge on a band, health with frame and ticks every 10% and thin stamina always visible stuck on top, effects above them, left and right click like a mouse inside the slot), UI-56 (stacked nameplates without overlapping, faction mark of circle or diamond within 30 m, larger bar up close), UI-18 (boss bar only when fighting it), UI-08 (war warnings queued, one at a time, over a band with emblem and the title font; band, boss bar and knocked-down warning at 166, 234 and 300 px, centered at x = 960), UI-41 (kill feed with band and the weapon icon between the names) and NPC telegraphing in amber (UI-50). The before-and-after pairs are in `build/comparaciones/`. Left for other lanes or for later: the 9-slice frames and the custom cursor of UI-02, the general NotificationCenter of UI-08 (UI-53 and UI-54 and the damage numbers were closed later: see the status after the merge).

**Depends on the user.** Choose the map style (decision 3) and approve the font and icon downloads (free; game-icons requires crediting each author).

**Status (map lane, 4 November 2026).** UI-51 (parchment map enabled and reproducible baking), UI-52, UI-53 and UI-54 done as far as the backlog says; the rest of the wave was done by other lanes (see the status after the merge). Before-and-after screenshots with `python tools/quality/run.py mapa`; `sc_mapa` adds zoom, drag and the objective line (`mapa_m_08` to `mapa_m_10`, `hud_objetivo_lejos`). To bake the map again after changing the scenery: `godot --headless --path . -s res://tools/map/bake_parchment_map.gd` and `godot --headless --path . --import`.

**Status after the merge of waves 2 to 5 (4 November 2026).** Replaces the two statuses above where they contradict each other. Done: UI-51 to UI-56, ART-12, UI-02 and the UI-18 adjustments (damage numbers now also stack among nearby victims and nameplates limit their stacking to 60 px with a stable order). Fixed after the review: the warning band, the boss bar and the knocked-down warning move down under the fort panel in its tallest state; footsteps no longer depend on FPS; respawn does not carry over the death slide; the predicted hit uses the victim's material and respects the dodge and line of sight. Pending: the windup of light attack 3 and of the heavy attack still lifts a foot (animation criterion 2), the keep keeps the flat `keep_earth` surface, the parchment map draws corner towers that do not exist (ART-57), tents are still prisms (ART-14, ART-15), the map legend is still half empty, the minimap needs more contrast and the nearby grass does not yet form a continuous meadow. Not yet demonstrated with screenshots: the block spark, the parry being distinguishable from the block, the sound, the hitstop, the remotes' reaction to a light attack and telling a Hollow apart at 20 m without nameplates; `sc_combate` has to be fixed (enter the courtyard through the gate and face a Hollow) and `run.py combate` and `run.py video --mp4` regenerated on the integrated branch. Update (6 November 2026, bench lane): `sc_combate` now resets the fort and fights inside the courtyard (it does not go through the closed gate), saves `huecos_20m_NN` (a Hollow from about 20 m), `golpe_NN` (the frame of every hit dealt, with numbers), `bloqueo_recibiendo_NN` (the frame of every blocked hit, with the spark) and `esquiva_NN`; `sc_video` alternates fighting and shield-up stretches in the courtyard against the Hollow and the Captain, then the combat bot. The bench bots take believable names per realm (`--bot-names=`), and the HUD crops point at the current position of the kill feed and the nameplates.

### Wave 4: hit feel (5 to 7 sessions)

**Goal.** Make hitting and being hit audible and tangible.

**Tasks.** ART-11 (combat audio node connected to `sound_requested`, banks per material with variations and hooks for other players' hits and actions, footsteps), ART-09 (spark or dust at the contact point, trail with `swing_active_changed` and with the remotes' active phase, 50 to 80 ms hitstop in the animation only, distinguishable blocked hit and parry, charge tension, effects of the three sword and shield abilities and of death) and the numbers and the marker of UI-12.

**Screenshots that demonstrate it.** The TEC-50 video with sound against combat feel criteria 1 to 3 and 7; `combate/pelea_b_*` and `combate/bloqueo_recibiendo_*` with sparks and trail; `camara_juego/com_habilidad_3_shield_wall.png` with its effect.

**Status.** Done (4 November 2026): ART-11 (`CombatAudio` with banks per material and variations, footsteps per surface from the feet, synchronized swings and also the remotes'), ART-09 (impact at the contact point of every hit, distinct block and parry, redone heavy-attack trail, 50/80 ms hitstop in the animation only and predicted locally, charge aura, effects of the three sword and shield abilities, death dust) and UI-12 (readable numbers and marker). Decision 6 was applied as a provisional cosmetic (the number, the marker and the DPS are still waiting for the server). Also the fixes to the own sword (base blade, wolf pommel, Askarra guard). Still to choose by ear among the alternatives of the listening sheet (`build/o4_hoja_escucha/`) and to judge the hitstop figures by playing. The tests are in `tests/test_combat_sound_bank.gd` and `tests/test_combat_feel.gd`; the video with sound comes from `python tools/quality/run.py video --mp4`.

**Depends on the user.** Approve the downloads of Kenney RPG Audio, Impact Sounds and Particle Pack, Still North, 80 CC0 RPG SFX and Binbun Hit FX and Battle FX Free (all free). Decide whether hitstop and impact sound are predicted locally (decision 6).

### Wave 5: the Vado Gris scenery (12 to 15 sessions)

**Goal.** Make the Vado Gris stop being a blockout.

**Tasks.** The sky and fog of ART-54, ART-55 (terrain with normals and height), ART-56 (relief with silhouette, ring of distant mountains and closed river exit), ART-57 (the fort dominates: keep of 20 to 24 m, corner towers, taller hill, irregular palisade and courtyard with objects), ART-59 (dense vegetation, grass with a base of the terrain color), ART-60 (Eldrun water), ART-61 (walls adapted to the terrain, monumental gate and gallows with corbels), ART-14 (wind, LOD, tents and decals), ART-15 (cloth banners with emblem), ART-62 (identity of each half) and ART-63 (ruins and chapel). When finished, bake the map again (UI-51) and repeat `verify_vado_gris_routes.gd` and the navigation mesh after ART-56 and ART-57.

**Status (Scenery lane, 4 November 2026).** Done: ART-54 (own sky of a storm that opens up, volumetric fog, SSIL, AgX and symmetric fill on the walls), ART-55 (Poly Haven texture set with normal and height, slopes without polka dots), ART-59 (grass with a base of the terrain color and wind, undergrowth), ART-57 (the own keep in its place, with low-resolution collision) and a first pass of ART-62 (snow and forest floor in the north, living grass in the south, cold or warm horizon). Sky3D has been discarded: the sky is our own. Budget: at most 975 draw calls and 1.77 M primitives. Routes verified with the same figures and navigation mesh rebuilt. Before and after of the 76 views in `build/mundo/` of the worktree. Still open: ART-56, ART-58 (bench check), ART-60, ART-61, ART-63, the rest of ART-57 and ART-62.

**Screenshots that demonstrate it.** The 10 cameras in `mundo/camaras_revision/` and the 66 views in `mundo/jugador_*` against the scenery criteria, with the figures in `metricas.txt` within budget.

**Depends on the user.** Decide the time of day and the weather (decision 4) and whether the two halves may be told apart by sight (decision 5). Approve the download of 6 to 8 CC0 textures and of Sky3D. Optional purchases: Medieval Village MegaKit Source (keep, tents, wall pieces) and Stylized Nature MegaKit Pro (more trees and rocks).

### Wave 6: purchased content (6 to 8 sessions)

**Goal.** Close what has no decent fix with the free clips.

**Tasks.** ART-04 (BlendSpace2D with UAL2 Source walk and UAL1 Pro jog in 8 directions, 90° turns and sprint entry and exit), the UAL1 Pro sideways dodge in ART-49, ART-41 (bow with the BOW clips of UAL2 Source and the bow from RPG Weapons Pro), ART-06 (sword and shields with model), the directional hits and the second death from UAL1 Pro in ART-50 and ART-51, and ART-16 (final model of the Hollow: Bestiary if it ships a skeleton, otherwise plan B).

**Screenshots that demonstrate it.** `animacion/*/loc_lateral_*`, `loc_atras`, `com_esquiva_*` and `arc_*` against animation criteria 6, 8 and 9; `combate/pelea_*` without boxes or discs.

**Depends on the user.** Buy UAL1 Pro and UAL2 Source; RPG Weapons Pro after trying the Free one; decide on the Bestiary (QAL license) and on the backward dodge (decision 9).

### Wave 7: flow screens and theme (about 5 sessions)

**Goal.** Make the first thing seen not a form on black.

**Tasks.** ART-21 (in-engine title logo and background), UI-22, UI-23 and UI-24 (selection and creation with stage and realm cards, ART-20), UI-06 (loading with zone name, image and tip, and game menu) and the theme frames of UI-02 and ART-12.

**Screenshots that demonstrate it.** `interfaz/titulo_*`, `seleccion_personaje_*`, `creacion_*`, `carga_*` and `galeria_ui_*` against interface criteria 6 and 7.

**Depends on the user.** Decide the frames (decision 10) and approve the download of Cinzel Decorative for the logo.

---

## 5. Recommended purchases and downloads

The user makes the purchases; the free downloads need their approval and a person downloads them to `../Eldmark-raw/<pack>/` (itch.io gives no direct links). Everything is recorded in `assets/LICENSES.md`. Prices in dollars as of 1 November 2026, VAT not checked.

| # | What | Price | License | What it unlocks | Item |
|---|---|---|---|---|---|
| 1 | Universal Animation Library (UAL1) Pro | 9.99 | CC0 | 8-direction jog, left and right dodge, hits to shoulders and stomach, second death, crawling in 4 directions, 90° turns and sprint entry and exit. Same skeleton, no retargeting. Strafing in Pro is already confirmed by the official image on the page. | ART-04, ART-49, ART-50, ART-51 |
| 2 | UAL2 Source (there is no Pro) | 14.99 | CC0 | The only 8-direction walk in the family, the bow clips (aim up, center and down, nock, shoot), sprint with shield and 8-direction zombie for the Hollow. | ART-04, ART-41, ART-16 |
| 3 | Cinzel, Noto Sans and IM Fell English SC (google/fonts) | Free | OFL | Titles, body and map labels with ñ and accents; `UIThemeBuilder` already expects them. | UI-02, UI-51 |
| 4 | Kenney RPG Audio and Impact Sounds | Free | CC0 | The first footsteps, swings and impacts while `assets/audio` is empty. | ART-11 |
| 5 | Still North Weapon Impacts and Weapon Textures, and 80 CC0 RPG SFX | Free | CC0 | Weapon clashes, unsheathing, bow and creature voices for the Hollow. | ART-11 |
| 6 | game-icons.net | Free | CC BY 3.0 (each author must be credited) | The first set of icons for actions, potions, statuses and weapons. | ART-12 |
| 7 | Kenney Particle Pack and Binbun Hit FX and Battle FX (Free) | Free (the Full versions, 3.49 each, only if they convince) | CC0 | Sparks, dust, trails, impacts and shield effects. | ART-09 |
| 8 | 6 to 8 textures from Poly Haven or ambientCG (grass, dirt, gravel, rock, shore mud, snow) | Free | CC0 | Terrain with normals and height, processed and desaturated as art.md asks. | ART-55 |
| 9 | Sky3D 2.1.0 | Free | MIT; the stars require crediting ESO | Sky with shaped clouds and a consistent sun, client only. | ART-54 |
| 10 | RPG Weapons Free, and then Pro | Free; Pro 3.99 | CC0 | Sword with grip point (Free); shields, bow and arrows (Pro). | ART-06, ART-41 |
| 11 | Medieval Village MegaKit Source | 14.99 | CC0 | Collisions, .blend and Godot project to model the keep, the tents and wall pieces with the kit's textures. | ART-14, ART-57, ART-61, ART-22 |
| 12 | Modular Character Outfits Source | 20.00 | CC0 | Knight, noble and mage of the same family: realm guards, Captain and per-realm look. | ART-27, ART-16, ART-03 |
| 13 | Stylized Nature MegaKit Pro | 9.99 | CC0 | About 40 trees, 35 plants and 27 rocks. Optional: first use the 52 models of the Standard already downloaded. | ART-59 |
| 14 | Bestiary Standard (to try) | Free | QAL v1.0, not CC0 | Check whether it ships a skeleton for the Hollow. | ART-16 |
| 15 | KayKit Character Animations 1.1 | Free | CC0 | Fallback for a backward dodge or the impact on block, with a style risk. | ART-49, ART-48 |
| 16 | Medieval Animation Pack 2.0 (Hadukis), try first | 19.99 | Use in own projects; CC BY 4.0 credit to 100STYLE | The only thing found with walking block, backward dodge and bow strafe. Very recent pack, no ratings and with another skeleton. | ART-48, ART-49 |
| 17 | Terrain3D 1.1.0 (try on a branch) | Free | MIT | Ocean mesh with water shader, height displacement and slope colorizer. It has API changes compared to 1.0. | ART-55, ART-60 |

Essential: 1 and 2 (24.98 USD). With 10, 11 and 12 the recommended purchase rises to 63.96 USD; with Nature Pro, to 73.95 USD.

Discarded for license or provenance: Unity Asset Store packs (they prohibit the files from being extractable and the use of AI on your team), MoCap Online (prohibits all AI, unconfirmed on the official page), AssetSmithy's music (AI-generated), GDQuest's sky textures (non-commercial) and Mixamo except as a last resort.

---

## 6. Decisions for the user

1. **Purchases.** I recommend buying UAL1 Pro and UAL2 Source now (24.98 USD): without them there is no decent strafe, sideways dodge or bow, and they share the same skeleton. RPG Weapons Pro, after trying the Free one; Village Source and Outfits Source, when wave 5 or the guards' clothing arrives.
2. **Free downloads.** Approve the list in section 5 (items 3 to 10, 14 and 15). Only game-icons.net and the Sky3D stars require credit.
3. **M map style.** Dark parchment (grainy paper, ink mountains, river with a bluish-gray wash, roads with a double stroke, tree stamps) or dark tactical map (color planes, contour lines, clean icons). I recommend dark parchment for the map window, for its tone, and the same layers with more contrast for the minimap, where legibility rules.
4. **Time of day and weather at the Vado Gris.** Keep the overcast sky with a real directional light; a storm that opens up (broken clouds, low western sun at 25–30° slipping between them); or the dark storm of Eldrun. I recommend the storm that opens up: it keeps the gray of the Eldrun border that world.md asks for, but gives shadows and volume, which do not exist with a closed sky. The sun stays on the west axis, so the symmetry is untouched. It affects the pending day and night cycle decision, which recommended fixed storm light.
5. **Visual asymmetry between the two halves.** docs/zones/vado_gris.md only allows changing models and materials. I propose also allowing different terrain, vegetation, sky and architecture as long as the gameplay layer (playable heights, collisions, markers) stays mirrored. I recommend yes: today both camps are the same photo with a different flag.
6. **Predicted hitstop and impact sound.** The "Own impact" table in combat.md only predicts the swing, the trail and the weapon sound. With 100 ms of RTT the confirmed hit already arrives during the recovery, outside the active window. I recommend predicting locally, as cosmetic, the hitstop and the impact sound with a check against the drawn positions; the number and the marker keep waiting for the server.
7. **Combat ticks versus clips.** If some attack does not match any clip segment between 0.7x and 1.5x, are its ticks touched (above all the windup and recovery of the heavy attack), with a new CMB-29 pass? I recommend trimming clips first and touching ticks only where there is no other way out, starting with the heavy attack.
8. **Strike reach versus blade.** The sword connects at 3.0 m between centers and the drawn blade reaches about 1.6 m. Options: a 1.1 m sword plus a trail that draws up to 2.2 m; lower the reach to 2.2 m; or more advance toward the target during the windup. I recommend the first and not touching the reach, which forgives with latency.
9. **Backward dodge.** No pack in the family ships a backward dodge. Options: a somersault oriented toward the direction of travel (the body turns); a short step or hop backwards New World style with an own clip or one from KayKit; or Hadukis' `dodge_back` after trying it. I recommend the short step backwards, because it is the most used dodge in combat and does not force turning your back on the enemy.
10. **Interface frames.** Keep the minimalist dark style and give it its own trait with iron 9-slice frames made from SVG in `tools/ui`, or try kibbitz's Fantasy RPG UI Kit (0.24 USD, tagged "AI Assisted" in the graphics). I recommend the own frames: no cost, no doubts about provenance and applicable to all windows at once from `UIThemeBuilder`.
11. **Hollow.** The backlog decision remains open. I recommend the quick profile of ART-52 now and downloading the Bestiary Standard only to see whether it ships a skeleton, knowing that it is QAL and that it would have to be removed if the repo goes public.
