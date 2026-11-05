#!/usr/bin/env python
"""Combat listening sheet (ART-11): one OGG per category with option A and option B in sequence.

    python tools/audio/listening_sheet.py [--out build/o4_hoja_escucha] [--raw ../Eldmark-raw]

Each OGG sounds like this: one beep (A), three variants of option A, a silence, two beeps (B), three variants of
option B. A is almost always what was synthesized in-house (`assets/audio/sfx`, balanced with `niveles.json`) and B what was
downloaded (Kenney Impact Sounds and RPG Audio, Still North Weapon Impacts, rubberduck 80 CC0 RPG SFX), with its volume
matched to A's so that the only thing that changes is the sound. It also writes `indice.md` with the files of
each option and which one the game uses today (`CombatSoundBank`).

Requires ffmpeg on the PATH. It downloads nothing: it reads from ../Eldmark-raw/, where the packs already are.
"""
import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SFX = ROOT / "assets" / "audio" / "sfx"

# category -> (description, option A, option B, option the game uses). An option is (list of files, optional
# pitch factor). The A paths are relative to assets/audio/sfx; the B ones, to the packs folder.
KEN_I = "kenney_impact_sounds/extracted/Audio"
KEN_R = "kenney_rpg_audio/extracted/Audio"
STN = "still_north_weapon_impacts/extracted"
RUB = "rubberduck_80_cc0_rpg_sfx/extracted"

CATEGORIES = {
    "01_barrido_ligero": (
        "Barrido del golpe ligero",
        (["swing/sword_swing_light_01.ogg", "swing/sword_swing_light_03.ogg", "swing/sword_swing_light_05.ogg"], 1.0),
        ([f"{RUB}/blade_01.ogg", f"{RUB}/blade_02.ogg", f"{RUB}/blade_03.ogg"], 1.0),
        "A"),
    "02_barrido_fuerte": (
        "Barrido del golpe fuerte",
        (["swing/sword_swing_heavy_01.ogg", "swing/sword_swing_heavy_02.ogg", "swing/sword_swing_heavy_03.ogg"], 1.0),
        ([f"{KEN_R}/knifeSlice.ogg", f"{KEN_R}/knifeSlice2.ogg", f"{RUB}/blade_02.ogg"], 0.8),
        "A"),
    "03_impacto_carne": (
        "Impacto en carne (golpe ligero)",
        (["hit_flesh/hit_flesh_01.ogg", "hit_flesh/hit_flesh_02.ogg", "hit_flesh/hit_flesh_03.ogg"], 1.0),
        ([f"{KEN_I}/impactPunch_medium_000.ogg", f"{KEN_I}/impactPunch_medium_001.ogg",
          f"{KEN_I}/impactPunch_medium_002.ogg"], 1.0),
        "A"),
    "04_impacto_fuerte": (
        "Impacto fuerte en carne y malla",
        (["hit_flesh/hit_flesh_04.ogg", "hit_mail/hit_mail_01.ogg", "hit_mail/hit_mail_03.ogg"], 1.0),
        ([f"{KEN_I}/impactPunch_heavy_000.ogg", f"{KEN_I}/impactPunch_heavy_001.ogg",
          f"{KEN_I}/impactPunch_heavy_002.ogg"], 1.0),
        "A"),
    "05_escudo_madera": (
        "Golpe bloqueado con el escudo de madera",
        (["hit_shield/hit_shield_wood_01.ogg", "hit_shield/hit_shield_wood_02.ogg",
          "hit_shield/hit_shield_wood_03.ogg"], 1.0),
        ([f"{KEN_I}/impactPlank_medium_000.ogg", f"{KEN_I}/impactPlank_medium_001.ogg",
          f"{KEN_I}/impactPlank_medium_002.ogg"], 1.0),
        "A"),
    "06_escudo_metal": (
        "Golpe bloqueado con el borde de metal",
        (["hit_shield/hit_shield_metal_01.ogg", "hit_shield/hit_shield_metal_02.ogg",
          "hit_shield/hit_shield_metal_03.ogg"], 1.0),
        ([f"{KEN_I}/impactPlate_medium_000.ogg", f"{KEN_I}/impactPlate_medium_001.ogg",
          f"{KEN_I}/impactMetal_medium_002.ogg"], 1.0),
        "A"),
    "07_parada": (
        "Parada (choque de acero, agudo)",
        (["parry/clash_metal_01.ogg", "parry/clash_metal_02.ogg", "parry/clash_metal_03.ogg"], 1.0),
        ([f"{STN}/Norse Sword Katana Blade on Blade.wav", f"{STN}/Sabre Norse Sword Blade on Blade.wav",
          f"{STN}/Seax Norse Sword Blade on Blade.wav"], 1.0),
        "A"),
    "08_paso_hierba": (
        "Paso en hierba (A: Kenney; B: la tierra sintetizada)",
        ([f"{KEN_I}/footstep_grass_000.ogg", f"{KEN_I}/footstep_grass_001.ogg", f"{KEN_I}/footstep_grass_002.ogg"], 1.0),
        (["step_dirt/step_dirt_01.ogg", "step_dirt/step_dirt_03.ogg", "step_dirt/step_dirt_05.ogg"], 1.0),
        "A"),
    "09_paso_tierra": (
        "Paso en tierra",
        (["step_dirt/step_dirt_02.ogg", "step_dirt/step_dirt_04.ogg", "step_dirt/step_dirt_06.ogg"], 1.0),
        ([f"{KEN_I}/footstep_carpet_000.ogg", f"{KEN_I}/footstep_carpet_001.ogg", f"{KEN_I}/footstep_carpet_002.ogg"], 1.0),
        "A"),
    "10_paso_piedra": (
        "Paso en piedra",
        (["step_stone/step_stone_01.ogg", "step_stone/step_stone_03.ogg", "step_stone/step_stone_05.ogg"], 1.0),
        ([f"{KEN_I}/footstep_concrete_000.ogg", f"{KEN_I}/footstep_concrete_001.ogg",
          f"{KEN_I}/footstep_concrete_002.ogg"], 1.0),
        "A"),
    "11_paso_madera": (
        "Paso en madera (A: Kenney; B: la piedra sintetizada)",
        ([f"{KEN_I}/footstep_wood_000.ogg", f"{KEN_I}/footstep_wood_001.ogg", f"{KEN_I}/footstep_wood_002.ogg"], 1.0),
        (["step_stone/step_stone_02.ogg", "step_stone/step_stone_04.ogg", "step_stone/step_stone_06.ogg"], 1.0),
        "A"),
    "12_esquiva": (
        "Esquiva (voltereta y paso)",
        (["dodge/dodge_roll_01.ogg", "dodge/dodge_roll_02.ogg", "dodge/dodge_step_01.ogg"], 1.0),
        ([f"{KEN_R}/cloth1.ogg", f"{KEN_R}/cloth3.ogg", f"{KEN_R}/clothBelt.ogg"], 1.0),
        "A"),
    "13_caida_cuerpo": (
        "Caída del cuerpo al morir",
        (["body/body_fall_01.ogg", "body/body_fall_02.ogg", "body/body_fall_03.ogg"], 1.0),
        ([f"{KEN_I}/impactPunch_heavy_003.ogg", f"{KEN_I}/impactPunch_heavy_004.ogg",
          f"{KEN_I}/impactGeneric_light_000.ogg"], 0.7),
        "A"),
    "14_huecos": (
        "Dolor de los Huecos",
        (["hollow/hollow_hurt_01.ogg", "hollow/hollow_hurt_02.ogg", "hollow/hollow_hurt_03.ogg"], 1.0),
        ([f"{RUB}/creature_hurt_01.ogg", f"{RUB}/creature_hurt_02.ogg", f"{RUB}/creature_misc_03.ogg"], 1.0),
        "A"),
}

GAP = 0.45
MAX_CLIP = 1.6


def run(cmd):
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def normalized_wav(src: Path, dst: Path, pitch: float):
    """Converts to 44.1 kHz mono WAV, trims to MAX_CLIP s and lowers or raises the pitch with asetrate (which changes the duration)."""
    filters = []
    if abs(pitch - 1.0) > 1e-3:
        filters.append(f"asetrate={int(44100 * pitch)},aresample=44100")
    filters.append(f"atrim=0:{MAX_CLIP},afade=t=out:st={MAX_CLIP - 0.15}:d=0.15")
    run(["ffmpeg", "-y", "-i", str(src), "-ac", "1", "-ar", "44100", "-af", ",".join(filters), str(dst)])


def loudness(wav: Path) -> float:
    """Mean volume (dB) with volumedetect."""
    proc = subprocess.run(["ffmpeg", "-i", str(wav), "-af", "volumedetect", "-f", "null", "-"],
                          capture_output=True, text=True)
    for line in proc.stderr.splitlines():
        if "mean_volume" in line:
            return float(line.split("mean_volume:")[1].split("dB")[0])
    return -20.0


def beep(dst: Path, count: int):
    parts = []
    for _ in range(count):
        parts.append("sine=frequency=880:duration=0.12")
    inputs = []
    for p in parts:
        inputs += ["-f", "lavfi", "-i", p]
    gaps = "".join(f"[{i}:a]" for i in range(count))
    run(["ffmpeg", "-y", *inputs, "-filter_complex",
         f"{gaps}concat=n={count}:v=0:a=1,volume=0.25,aresample=44100,apad=pad_dur=0.4[o]", "-map", "[o]", "-ac", "1", str(dst)])


def silence(dst: Path, seconds: float):
    run(["ffmpeg", "-y", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono", "-t", str(seconds), str(dst)])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", default=str(ROOT / "build" / "o4_hoja_escucha"))
    parser.add_argument("--raw", default=str(ROOT.parent / "Eldmark-raw"))
    args = parser.parse_args()
    if not shutil.which("ffmpeg"):
        print("falta ffmpeg en el PATH")
        return 1
    raw = Path(args.raw)
    if not raw.exists():
        # If it is not where indicated, it climbs up the parent directories until it finds Eldmark-raw.
        for parent in ROOT.parents:
            if (parent / "Eldmark-raw").exists():
                raw = parent / "Eldmark-raw"
                break
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    lines = ["# Hoja de escucha de combate (ART-11)", "",
             "Cada OGG: un pitido, tres variantes de la opción A, silencio, dos pitidos, tres variantes de la opción B. "
             "Los volúmenes de la B se igualan a los de la A.", "",
             "| OGG | Qué es | Opción A | Opción B | La usa el juego |", "|---|---|---|---|---|"]
    with tempfile.TemporaryDirectory() as tmp_name:
        tmp = Path(tmp_name)
        beep(tmp / "beep1.wav", 1)
        beep(tmp / "beep2.wav", 2)
        silence(tmp / "gap.wav", GAP)
        silence(tmp / "gap_long.wav", 0.9)
        for key, (title, option_a, option_b, used) in CATEGORIES.items():
            sequence = [tmp / "beep1.wav"]
            reference = None
            names = {"A": [], "B": []}
            for label, (files, pitch) in (("A", option_a), ("B", option_b)):
                if label == "B":
                    sequence += [tmp / "gap_long.wav", tmp / "beep2.wav"]
                for index, rel in enumerate(files):
                    base = raw if rel.startswith(("kenney", "still", "rubber")) else SFX
                    src = base / rel
                    if not src.exists():
                        print(f"[hoja] falta {src}")
                        continue
                    wav = tmp / f"{key}_{label}{index}.wav"
                    normalized_wav(src, wav, pitch)
                    level = loudness(wav)
                    if reference is None:
                        reference = level
                    if label == "B":
                        # Match A's mean volume.
                        gained = tmp / f"{key}_{label}{index}_g.wav"
                        run(["ffmpeg", "-y", "-i", str(wav), "-af", f"volume={reference - level:.2f}dB,alimiter=limit=0.95", str(gained)])
                        wav = gained
                    sequence += [wav, tmp / "gap.wav"]
                    names[label].append(Path(rel).name)
            listing = tmp / f"{key}.txt"
            listing.write_text("".join(f"file '{p.as_posix()}'\n" for p in sequence), encoding="utf-8")
            joined = tmp / f"{key}_all.wav"
            run(["ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", str(listing), "-ar", "44100", "-ac", "1", str(joined)])
            run(["ffmpeg", "-y", "-i", str(joined), "-c:a", "libvorbis", "-q:a", "5", str(out / f"{key}.ogg")])
            lines.append(f"| {key}.ogg | {title} | {', '.join(names['A'])} | {', '.join(names['B'])} | {used} |")
            print(f"[hoja] {key}.ogg")
    (out / "indice.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"[hoja] listo en {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
