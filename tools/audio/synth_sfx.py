#!/usr/bin/env python3
"""Sonidos de Eldmark sintetizados desde cero (ART-11): sin muestras de terceros.

Todo sale de síntesis y procesado con numpy (sin scipy) y se pasa a OGG Vorbis con ffmpeg. El generador son
tres módulos junto a este programa:

    sfx_dsp.py      filtros, envolventes, ecos, medidas (sonoridad K, bandas, tramos) y codificación
    sfx_combat.py   barridos, golpes por material, escudo, parada, caída, esquiva, arco y flechas
    sfx_world.py    pasos, poción, interfaz, cuernos de fuerte y voces de los Huecos

Cada sonido tiene una semilla fija (el nombre del archivo): ejecutar el script dos veces da los mismos archivos,
bit a bit. Los sonidos del juego en 3D van en seco (la reverberación la pone el motor por zonas: buses o
Area3D); solo la interfaz conserva una sala y el cuerno lleva un eco exterior.

Salida (assets/audio/sfx/<categoría>/<nombre>_NN.ogg):

    swing/          sword_swing_light_01..06 (0,20-0,25 s), sword_swing_heavy_01..03 (0,40-0,50 s)
    hit_flesh/      hit_flesh_01..05        hit_leather/  hit_leather_01..05
    hit_gambeson/   hit_gambeson_01..05     hit_mail/     hit_mail_01..04
    hit_shield/     hit_shield_wood_01..05 (escudo de madera), hit_shield_metal_01..03 (bloqueo con acero)
    parry/          clash_metal_01..04      (parada: «shing» brillante con arrastre de filo)
    step_dirt/      step_dirt_01..08        step_stone/   step_stone_01..08
    body/           body_fall_01..03        (tela, cuero y equipo, armadura)
    dodge/          dodge_roll_01..03, dodge_step_01..02
    bow/            bow_draw_01..02, bow_release_01..03
    arrow/          arrow_hit_flesh_01..03, arrow_hit_wood_01..02
    hollow/         hollow_hurt_01..04, hollow_death_01..02    (voces de los Huecos)
    potion/         potion_drink_01
    ui/             ui_click_01, ui_confirm_01
    alert/          horn_fort_won_<reino>_01 y horn_fort_lost_<reino>_01 (vardheim, solmarch, askarra)

Todos son mono a 44,1 kHz salvo los cuernos y la confirmación de interfaz (estéreo: eco y sala).
Niveles: cada archivo se iguala por la sonoridad de su parte activa (ponderación K) con un techo de pico real de
-1,5 dBTP medido sobre el OGG decodificado. El equilibrio entre categorías no está en los archivos sino en
`niveles.json` (`volume_db`, el recorte que debe aplicar el reproductor), que también anota el pico de cada
sonido (`pico_s`), cómo sincronizar los barridos con la ventana activa de data/combat y el aleatorizador
recomendado de cada grupo (AudioStreamRandomizer: tono ±5 % y volumen ±2 dB).
`tools/audio/analyze_sfx.py` mide los OGG ya codificados contra el listón y dibuja los espectrogramas.

Uso, desde la raíz del proyecto (necesita numpy y ffmpeg en el PATH):

    python tools/audio/synth_sfx.py                    # genera todo
    python tools/audio/synth_sfx.py --only clash       # solo los que contengan «clash»
    python tools/audio/synth_sfx.py --list             # lista el catálogo
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
    """Lee un número de un .tres de texto (`key = 0.2`); None si no está."""
    try:
        m = re.search(r"^%s\s*=\s*([0-9.]+)" % re.escape(key), Path(path).read_text(encoding="utf-8"), re.M)
    except OSError:
        return None
    return float(m.group(1)) if m else None


def sync_notes(levels):
    """Cómo cuadrar los barridos con la ventana activa del golpe (data/combat): el sonido debe empezar en
    `inicio_s` tras el inicio de la acción (en el fuerte, tras soltar) para que su pico caiga en el centro de la
    ventana activa. Los valores salen de data/combat/sword_*.tres, así que siguen a los datos."""
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
        x, limited = encode_normalized(x, path)  # a partir de aquí, la señal decodificada
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
