#!/usr/bin/env python3
"""Eldmark sounds synthesized from scratch (ART-11): no third-party samples.

Everything comes from synthesis and processing with numpy (no scipy) and is converted to OGG Vorbis with ffmpeg. The generator is
three modules next to this program:

    sfx_dsp.py      filters, envelopes, echoes, measurements (K loudness, bands, spans) and encoding
    sfx_combat.py   swings, hits by material, shield, parry, fall, dodge, bow and arrows
    sfx_world.py    footsteps, potion, interface, fort horns and voices of the Hollow

Each sound has a fixed seed (the file name): running the script twice gives the same files,
bit for bit. The game's 3D sounds are dry (reverb is added by the engine per zone: buses or
Area3D); only the interface keeps a room and the horn carries an outdoor echo.

Output (assets/audio/sfx/<category>/<name>_NN.ogg):

    swing/          sword_swing_light_01..06 (0.20-0.25 s), sword_swing_heavy_01..03 (0.40-0.50 s)
    hit_flesh/      hit_flesh_01..05        hit_leather/  hit_leather_01..05
    hit_gambeson/   hit_gambeson_01..05     hit_mail/     hit_mail_01..04
    hit_shield/     hit_shield_wood_01..05 (wooden shield), hit_shield_metal_01..03 (block with steel)
    parry/          clash_metal_01..04      (parry: bright "shing" with a blade drag)
    step_dirt/      step_dirt_01..08        step_stone/   step_stone_01..08
    body/           body_fall_01..03        (cloth, leather and gear, armor)
    dodge/          dodge_roll_01..03, dodge_step_01..02
    bow/            bow_draw_01..02, bow_release_01..03
    arrow/          arrow_hit_flesh_01..03, arrow_hit_wood_01..02
    hollow/         hollow_hurt_01..04, hollow_death_01..02    (voices of the Hollow)
    potion/         potion_drink_01
    ui/             ui_click_01, ui_confirm_01
    alert/          horn_fort_won_<realm>_01 and horn_fort_lost_<realm>_01 (vardheim, solmarch, askarra)

All are mono at 44.1 kHz except the horns and the interface confirmation (stereo: echo and room).
Levels: each file is matched by the loudness of its active part (K weighting) with a true peak ceiling of
-1.5 dBTP measured on the decoded OGG. The balance between categories is not in the files but in
`niveles.json` (`volume_db`, the trim the player must apply), which also notes each
sound's peak (`pico_s`), how to sync the swings with the active window from data/combat and the
recommended randomizer for each group (AudioStreamRandomizer: pitch ±5 % and volume ±2 dB).
`tools/audio/analyze_sfx.py` measures the already-encoded OGGs against the quality bar and plots the spectrograms.

Usage, from the project root (needs numpy and ffmpeg on the PATH):

    python tools/audio/synth_sfx.py                    # generate everything
    python tools/audio/synth_sfx.py --only clash       # only those containing "clash"
    python tools/audio/synth_sfx.py --list             # list the catalog
"""

import argparse
import json
import re
import shutil
import sys
import time
import zlib
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

import sfx_combat  # noqa: E402,F401  (registra sus sonidos en el catálogo)
import sfx_world  # noqa: E402,F401
from sfx_dsp import (LOUD_DB, OUT_ROOT, PEAK_DB, ROOT, SOUNDS, SR, decode_ogg, encode_normalized, finalize,  # noqa: E402
                     measure_levels, sound_files)


def _tres_value(path, key):
    """Reads a number from a text .tres (`key = 0.2`); None if it is not there."""
    try:
        m = re.search(r"^%s\s*=\s*([0-9.]+)" % re.escape(key), Path(path).read_text(encoding="utf-8"), re.M)
    except OSError:
        return None
    return float(m.group(1)) if m else None


def sync_notes(levels):
    """How to line up the swings with the hit's active window (data/combat): the sound must start at
    `inicio_s` after the action starts (for the heavy attack, after release) so that its peak falls at the center of the
    active window. The values come from data/combat/sword_*.tres, so they follow the data."""
    out = {"regla": "inicio_s = preparacion_s + ventana_activa_s / 2 - pico_s; el pico del barrido (pico_s) es fijo "
                    "dentro de cada familia y está en 'sonidos'"}
    combat = ROOT / "data" / "combat"
    for family, files in (("sword_swing_light", ("sword_light_1", "sword_light_2", "sword_light_3")),
                          ("sword_swing_heavy", ("sword_heavy",))):
        peaks = [v["pico_s"] for k, v in levels.items() if k.split("/")[1].startswith(family)]
        if not peaks:
            continue
        pico = float(np.median(peaks))
        rows = {}
        for f in files:
            wind = _tres_value(combat / (f + ".tres"), "windup_s")
            act = _tres_value(combat / (f + ".tres"), "active_s")
            if wind is None or act is None:
                continue
            rows[f] = dict(preparacion_s=wind, ventana_activa_s=act, inicio_s=round(wind + act / 2 - pico, 3))
        out[family] = dict(pico_s=round(pico, 3), ataques=rows)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--only", help="genera solo los sonidos cuyo nombre contenga este texto")
    ap.add_argument("--out", default=str(OUT_ROOT), help="carpeta de salida (por defecto assets/audio/sfx)")
    ap.add_argument("--list", action="store_true", help="lista el catálogo y termina")
    args = ap.parse_args()
    sys.stdout.reconfigure(encoding="utf-8")

    if args.list:
        for s, v, fname in sound_files():
            print("%-12s %s" % (s["category"], fname))
        return 0
    if shutil.which("ffmpeg") is None:
        print("Falta ffmpeg en el PATH", file=sys.stderr)
        return 1

    out_root = Path(args.out)
    levels = {}
    total = 0
    t_start = time.time()
    for s, v, fname in sound_files():
        if args.only and args.only not in fname:
            continue
        seed = zlib.crc32(fname.encode("utf-8")) & 0xFFFFFFFF
        rng = np.random.default_rng(seed)
        t0 = time.time()
        x = finalize(s["fn"](rng, v))
        path = out_root / s["category"] / (fname + ".ogg")
        path.parent.mkdir(parents=True, exist_ok=True)
        x, limited = encode_normalized(x, path)  # from here on, the decoded signal
        m = measure_levels(x)
        levels["%s/%s" % (s["category"], fname)] = dict(
            duracion_s=round(m["dur"], 3),
            canales=m["channels"],
            pico_s=round(m["peak_t"], 3),
            pico_dbfs=round(m["peak_db"], 2),
            pico_real_dbfs=round(m["true_peak_db"], 2),
            rms_activo_dbfs=round(m["rms_db"], 2),
            sonoridad_activa_db=round(m["loud_db"], 2),
            limitado_por_techo=bool(limited),
            volume_db=s["mix_db"])
        total += 1
        print("%-34s %5.2f s  %s  %6.1f dB  (%.1f s)" % (fname, m["dur"], "estéreo" if m["channels"] == 2 else "mono   ",
                                                       m["loud_db"], time.time() - t0))

    if not args.only:
        groups = {}
        for s, v, fname in sound_files():
            g = groups.setdefault(s["name"], dict(directorio=s["category"], archivos=[], volume_db=s["mix_db"],
                                                  random_pitch=s["pitch"], random_volume_offset_db=s["vol_db"]))
            g["archivos"].append(fname + ".ogg")
        meta = dict(
            generador="tools/audio/synth_sfx.py",
            nota="Todos los archivos tienen la misma sonoridad de parte activa (sonoridad_objetivo_db) salvo los que "
                 "manda el techo de pico real. volume_db es el recorte que debe aplicar el reproductor para equilibrar "
                 "categorías: 0 es lo más fuerte (los golpes) y nunca es positivo. Pasos, golpes y barridos van en seco: "
                 "la reverberación la pone el motor.",
            politica=dict(sonoridad_objetivo_db=LOUD_DB, techo_pico_real_dbtp=PEAK_DB,
                          medida="ponderación K (ITU-R BS.1770) sobre la parte activa (envolvente RMS de 10 ms a menos de "
                                 "30 dB de su máximo), potencia media de los canales; sin la compensación de 0,691 de LUFS"),
            aleatorizador="cada grupo lleva random_pitch (1,05 = ±5 %) y random_volume_offset_db (2 = ±2 dB) para un "
                          "AudioStreamRandomizer con todos sus archivos como streams",
            sincronia=sync_notes(levels),
            grupos=groups,
            sonidos=levels)
        (out_root / "niveles.json").write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print("%d sonidos en %.1f s" % (total, time.time() - t_start))
    return 0


if __name__ == "__main__":
    sys.exit(main())
