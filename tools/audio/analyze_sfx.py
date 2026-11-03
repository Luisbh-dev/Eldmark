#!/usr/bin/env python3
"""Comprueba y dibuja los sonidos de assets/audio/sfx para revisarlos sin oírlos (ART-11).

Decodifica cada OGG con ffmpeg (lo que oirá el juego, no la señal antes de codificar) y:

  1. Mide duración, canales, frecuencia de muestreo, pico de muestra, pico real (sobremuestreado x4),
     nivel RMS de la parte activa, muestras saturadas, continua, nivel al principio y al final, clics
     sueltos dentro del sonido, centroide espectral, tiempo de ataque y tiempo de caída.
  2. Falla (código de salida 1) si algo se sale de lo que pide el catálogo de synth_sfx.py: faltan
     archivos, duración fuera de rango, pico real a más de 0,5 dB del objetivo (-1,5 dBFS), pico de
     muestra por encima de -1,0, saturación, clic al principio, al final o en medio (salvo en los sonidos
     de gravilla, burbujas y tintineos, que son impulsos a propósito) o variaciones casi idénticas.
  3. Dibuja un espectrograma por archivo (forma de onda arriba, espectrograma en frecuencia
     logarítmica de 40 Hz a 20 kHz debajo) y hojas resumen por grupo.

Salida en build/audio/ (ignorada por Git): espectrogramas/<categoría>/<nombre>.png, hojas/<grupo>.png,
informe.txt y muestrario.wav (todos los sonidos seguidos, con su recorte de volumen, para oírlos de una vez). Uso, desde la raíz del proyecto (necesita numpy, Pillow y ffmpeg/ffprobe en el PATH):

    python tools/audio/analyze_sfx.py
    python tools/audio/analyze_sfx.py --sfx assets/audio/sfx --out build/audio --no-images
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import synth_sfx as synth  # noqa: E402  (el catálogo vive en el generador)

ROOT = Path(__file__).resolve().parents[2]
SR = synth.SR
TARGET_PEAK_DB = synth.PEAK_DB
MIN_COUNT = {  # lo que pide ART-11: al menos tantas variaciones de cada cosa
    "sword_swing_light": 3, "sword_swing_heavy": 2, "hit_flesh": 3, "hit_shield_wood": 3,
    "clash_metal": 2, "step_dirt": 3, "step_stone": 3, "body_fall": 1, "potion_drink": 1,
    "ui_click": 1, "ui_confirm": 1, "horn_fort_capture": 1,
}
GROUPS = {
    "combate": ("swing", "hit_flesh", "hit_shield", "parry"),
    "movimiento": ("step_dirt", "step_stone", "body"),
    "otros": ("potion", "ui", "alert"),
}


# ---------------------------------------------------------------------------
# Decodificación y medidas
# ---------------------------------------------------------------------------

def decode(path):
    """Devuelve (señal float32 [n] o [n, canales], frecuencia de muestreo)."""
    probe = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries", "stream=channels,sample_rate",
         "-of", "json", str(path)], capture_output=True, check=True)
    info = json.loads(probe.stdout)["streams"][0]
    channels = int(info["channels"])
    rate = int(info["sample_rate"])
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-f", "f32le", "-acodec", "pcm_f32le", "-"],
                         capture_output=True, check=True).stdout
    x = np.frombuffer(raw, dtype="<f4").astype(np.float64)
    if channels > 1:
        x = x.reshape(-1, channels)
    return x, rate


def db(v):
    return 20.0 * np.log10(max(float(v), 1e-9))


true_peak = synth.true_peak


def measure(x, rate):
    mono = x if x.ndim == 1 else x.mean(axis=1)
    env = np.max(np.abs(x), axis=1) if x.ndim == 2 else np.abs(x)
    n = len(mono)
    peak = float(env.max())
    active = env > peak * 10 ** (-30 / 20)
    spec = np.abs(np.fft.rfft(mono * np.hanning(n))) ** 2
    freqs = np.fft.rfftfreq(n, 1.0 / rate)
    # Envolvente suavizada (2 ms) para el ataque y la caída.
    win = max(1, int(rate * 0.002))
    sm = np.convolve(env, np.ones(win) / win, mode="same")
    ipk = int(np.argmax(sm))
    first = int(np.argmax(sm > sm[ipk] * 0.05))
    reach90 = int(np.argmax(sm > sm[ipk] * 0.9))
    after = np.nonzero(sm[ipk:] < sm[ipk] * 10 ** (-40 / 20))[0]
    # Clics: saltos aislados entre muestras (7 veces el de su entorno de ±4 ms), pasados los primeros 12 ms.
    d = np.diff(mono)
    w = int(rate * 0.004)
    local = np.sqrt(np.convolve(d * d, np.ones(2 * w + 1) / (2 * w + 1), mode="same") + 1e-12)
    clicks = int(np.sum((np.abs(d) > 7 * local) & (np.abs(d) > 0.01) & (np.arange(len(d)) > int(rate * 0.012))))
    return dict(
        clicks=clicks,
        dur=n / rate, channels=1 if x.ndim == 1 else x.shape[1], rate=rate,
        peak_db=db(peak), true_peak_db=db(true_peak(x)),
        rms_db=db(np.sqrt(np.mean(env[active] ** 2))),
        clipped=int(np.sum(env >= 0.999)),
        dc=float(np.mean(mono)),
        start_db=db(env[0]),
        end_db=db(env[-max(1, int(rate * 0.005)):].max()),
        centroid=float(np.sum(freqs * spec) / np.sum(spec)),
        attack_ms=(reach90 - first) / rate * 1000.0,
        t40_ms=((ipk + int(after[0])) - ipk) / rate * 1000.0 if len(after) else (n - ipk) / rate * 1000.0,
        peak_t_ms=ipk / rate * 1000.0)


def band_spectrum(x, rate):
    """Espectro medio en bandas de tercio de octava (dB relativos al total), para comparar variaciones."""
    mono = x if x.ndim == 1 else x.mean(axis=1)
    spec = np.abs(np.fft.rfft(mono)) ** 2
    freqs = np.fft.rfftfreq(len(mono), 1.0 / rate)
    centers = 31.5 * 2 ** (np.arange(0, 28) / 3.0)
    centers = centers[centers < 18000]
    out = []
    for c in centers:
        m = (freqs >= c / 2 ** (1 / 6)) & (freqs < c * 2 ** (1 / 6))
        out.append(spec[m].sum() if m.any() else 0.0)
    out = np.array(out) + 1e-12
    return 10 * np.log10(out / out.sum())


# ---------------------------------------------------------------------------
# Espectrogramas
# ---------------------------------------------------------------------------

_CMAP = np.array([
    (0.00, 0, 0, 4), (0.13, 31, 12, 72), (0.25, 85, 15, 109), (0.38, 136, 34, 106), (0.50, 186, 54, 85),
    (0.63, 227, 89, 51), (0.75, 249, 140, 10), (0.88, 249, 201, 50), (1.00, 252, 255, 164)])


def colormap(v):
    """Mapa de color tipo inferno para valores en 0..1; devuelve uint8 [..., 3]."""
    v = np.clip(v, 0.0, 1.0)
    out = np.empty(v.shape + (3,))
    for c in range(3):
        out[..., c] = np.interp(v, _CMAP[:, 0], _CMAP[:, c + 1])
    return out.astype(np.uint8)


def spectrogram_db(mono, rate, width, rows, f_lo=40.0, f_hi=20000.0, floor_db=-85.0):
    """Matriz [rows, width] en 0..1: dB relativos al máximo, filas en frecuencia logarítmica (arriba, agudos)."""
    dur = len(mono) / rate
    n_fft = 512 if dur < 0.6 else 1024
    hop = max(1, int(len(mono) / width))
    pad = np.concatenate([np.zeros(n_fft // 2), mono, np.zeros(n_fft)])
    window = np.hanning(n_fft)
    frames = np.array([pad[i * hop:i * hop + n_fft] * window for i in range(width)])
    power = np.abs(np.fft.rfft(frames, axis=1)) ** 2  # [width, bins]
    freqs = f_lo * (f_hi / f_lo) ** (np.arange(rows) / (rows - 1))
    pos = freqs / (rate / n_fft)
    lo = np.clip(np.floor(pos).astype(int), 0, power.shape[1] - 2)
    frac = (pos - lo)[None, :]
    sample = power[:, lo] * (1 - frac) + power[:, lo + 1] * frac  # [width, rows]
    d = 10 * np.log10(sample + 1e-14)
    d -= d.max()
    img = (np.clip(d, floor_db, 0.0) - floor_db) / -floor_db
    return img.T[::-1]  # agudos arriba


def _font(size):
    from PIL import ImageFont
    for name in ("arial.ttf", "DejaVuSans.ttf", "Arial.ttf", "LiberationSans-Regular.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    try:
        return ImageFont.load_default(size=size)
    except TypeError:
        return ImageFont.load_default()


def render_spectrogram(x, rate, title, subtitle, compact=False):
    """PNG con forma de onda y espectrograma. Devuelve una imagen PIL."""
    from PIL import Image, ImageDraw
    w_plot, h_wave, h_spec = (520, 56, 200) if compact else (1000, 130, 380)
    ml, mr, mt, mb = (46, 8, 38, 20) if compact else (66, 24, 62, 34)
    fs, fs_small = (12, 10) if compact else (16, 12)
    W = ml + w_plot + mr
    H = mt + h_wave + 8 + h_spec + mb
    img = Image.new("RGB", (W, H), (18, 18, 22))
    d = ImageDraw.Draw(img)
    font, small = _font(fs), _font(fs_small)
    fg = (225, 225, 230)
    dim = (130, 130, 140)
    d.text((ml, 6), title, fill=fg, font=font)
    d.text((ml, 6 + fs + 3), subtitle, fill=dim, font=small)

    mono = x if x.ndim == 1 else x.mean(axis=1)
    dur = len(mono) / rate

    # Forma de onda (mínimo y máximo por columna; si es estéreo, el canal con más amplitud).
    wave_src = x if x.ndim == 1 else x[:, int(np.argmax(np.max(np.abs(x), axis=0)))]
    edges = np.linspace(0, len(wave_src), w_plot + 1).astype(int)
    y0 = mt
    d.rectangle([ml, y0, ml + w_plot, y0 + h_wave], outline=(60, 60, 70), fill=(12, 12, 16))
    mid = y0 + h_wave / 2
    d.line([ml, mid, ml + w_plot, mid], fill=(50, 50, 60))
    for lvl in (0.5, -0.5):
        yy = mid - lvl * h_wave / 2
        d.line([ml, yy, ml + w_plot, yy], fill=(34, 34, 42))
    for i in range(w_plot):
        seg = wave_src[edges[i]:max(edges[i] + 1, edges[i + 1])]
        d.line([ml + i, mid - seg.max() * h_wave / 2, ml + i, mid - seg.min() * h_wave / 2], fill=(120, 190, 235))
    d.text((6, y0), "+1", fill=dim, font=small)
    d.text((6, y0 + h_wave - fs_small - 2), "-1", fill=dim, font=small)

    # Espectrograma.
    y1 = y0 + h_wave + 8
    spec = spectrogram_db(mono, rate, w_plot, h_spec)
    img.paste(Image.fromarray(colormap(spec)), (ml, y1))
    d.rectangle([ml, y1, ml + w_plot, y1 + h_spec], outline=(60, 60, 70))
    f_lo, f_hi = 40.0, 20000.0
    for f, label in ((100, "100"), (500, "500"), (1000, "1k"), (2000, "2k"), (5000, "5k"), (10000, "10k"), (16000, "16k")):
        yy = y1 + (h_spec - 1) * (1 - np.log(f / f_lo) / np.log(f_hi / f_lo))
        d.line([ml - 4, yy, ml, yy], fill=dim)
        d.line([ml, yy, ml + w_plot, yy], fill=(255, 255, 255, 40) if False else (70, 60, 70))
        d.text((ml - 6 - d.textlength(label, font=small), yy - fs_small / 2 - 1), label, fill=dim, font=small)

    # Eje de tiempo.
    step = 0.05 if dur < 0.4 else 0.1 if dur < 1.0 else 0.25 if dur < 2.2 else 0.5
    k = 0
    while k * step <= dur + 1e-9:
        xx = ml + (k * step / dur) * w_plot
        d.line([xx, y1 + h_spec, xx, y1 + h_spec + 4], fill=dim)
        label = ("%.2f" % (k * step)).rstrip("0").rstrip(".") + (" s" if k == 0 else "")
        d.text((xx - d.textlength(label, font=small) / 2, y1 + h_spec + 5), label, fill=dim, font=small)
        k += 1
    return img


def make_sheet(entries, title, path):
    """Hoja con una miniatura por archivo, en filas de 3."""
    from PIL import Image, ImageDraw
    thumbs = [render_spectrogram(x, r, name, sub, compact=True) for (name, sub, x, r) in entries]
    cols = 3
    cw, ch = thumbs[0].size
    rows = (len(thumbs) + cols - 1) // cols
    top = 40
    sheet = Image.new("RGB", (cols * cw, top + rows * ch), (18, 18, 22))
    ImageDraw.Draw(sheet).text((12, 8), title, fill=(235, 235, 240), font=_font(20))
    for i, t in enumerate(thumbs):
        sheet.paste(t, ((i % cols) * cw, top + (i // cols) * ch))
    path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(path)


# ---------------------------------------------------------------------------
# Muestrario
# ---------------------------------------------------------------------------

def write_reel(loaded, path):
    """WAV de 16 bits con todos los sonidos seguidos (con el recorte `volume_db` del catálogo y 0,45 s de
    silencio entre ellos) para escucharlos de una tacada."""
    import wave
    gap = np.zeros((int(SR * 0.45), 2))
    parts = []
    for key, (x, rate, m, s) in loaded.items():
        st = np.stack([x, x], axis=1) if x.ndim == 1 else x
        parts.append(st * 10 ** (s["mix_db"] / 20))
        parts.append(gap)
    mix = np.concatenate(parts)
    pcm = (np.clip(mix, -1.0, 1.0) * 32767).astype("<i2")
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


# ---------------------------------------------------------------------------
# Programa principal
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--sfx", default=str(ROOT / "assets" / "audio" / "sfx"))
    ap.add_argument("--out", default=str(ROOT / "build" / "audio"))
    ap.add_argument("--no-images", action="store_true", help="solo las medidas, sin PNG")
    args = ap.parse_args()
    sfx = Path(args.sfx)
    out = Path(args.out)
    sys.stdout.reconfigure(encoding="utf-8")

    problems = []
    rows = []
    loaded = {}
    names_by_base = {}
    for s, v, fname in synth.sound_files():
        path = sfx / s["category"] / (fname + ".ogg")
        key = "%s/%s" % (s["category"], fname)
        if not path.exists():
            problems.append("%s: falta el archivo" % key)
            continue
        x, rate = decode(path)
        m = measure(x, rate)
        loaded[key] = (x, rate, m, s)
        names_by_base.setdefault(s["name"], []).append(key)
        want_ch = 2 if s["stereo"] else 1
        if m["rate"] != SR:
            problems.append("%s: frecuencia de muestreo %d (se esperaba %d)" % (key, m["rate"], SR))
        if m["channels"] != want_ch:
            problems.append("%s: %d canales (se esperaban %d)" % (key, m["channels"], want_ch))
        if not (s["dur"][0] <= m["dur"] <= s["dur"][1]):
            problems.append("%s: dura %.2f s, fuera de %.2f a %.2f s" % (key, m["dur"], *s["dur"]))
        if abs(m["true_peak_db"] - TARGET_PEAK_DB) > 0.5:
            problems.append("%s: pico real %.2f dBFS, lejos del objetivo %.1f" % (key, m["true_peak_db"], TARGET_PEAK_DB))
        if m["peak_db"] > -1.0:
            problems.append("%s: pico de muestra %.2f dBFS, por encima de -1,0" % (key, m["peak_db"]))
        if m["clipped"] > 0:
            problems.append("%s: %d muestras saturadas" % (key, m["clipped"]))
        if abs(m["dc"]) > 0.005:
            problems.append("%s: continua %.4f" % (key, m["dc"]))
        if m["start_db"] > -30.0:
            problems.append("%s: clic al principio (%.1f dBFS en la primera muestra)" % (key, m["start_db"]))
        if m["end_db"] > -45.0:
            problems.append("%s: corte seco al final (%.1f dBFS en los últimos 5 ms)" % (key, m["end_db"]))
        if m["clicks"] > 0 and not s["grainy"]:
            problems.append("%s: %d clics sueltos dentro del sonido" % (key, m["clicks"]))
        if m["rms_db"] < -35.0:
            problems.append("%s: casi inaudible (RMS activo %.1f dBFS)" % (key, m["rms_db"]))
        rows.append((key, m))

    for base, need in MIN_COUNT.items():
        have = len(names_by_base.get(base, []))
        if have < need:
            problems.append("%s: %d variaciones, ART-11 pide al menos %d" % (base, have, need))

    # Variaciones: que no sean la misma cosa con otro ruido.
    lines_var = []
    for base, keys in names_by_base.items():
        if len(keys) < 2:
            continue
        specs = {k: band_spectrum(loaded[k][0], loaded[k][1]) for k in keys}
        for i in range(len(keys)):
            for j in range(i + 1, len(keys)):
                dist = float(np.sqrt(np.mean((specs[keys[i]] - specs[keys[j]]) ** 2)))
                dur_diff = abs(loaded[keys[i]][2]["dur"] - loaded[keys[j]][2]["dur"])
                cen_diff = abs(loaded[keys[i]][2]["centroid"] - loaded[keys[j]][2]["centroid"])
                lines_var.append("%-38s %-38s distancia espectral %5.1f dB, dif. duración %.2f s, dif. centroide %5.0f Hz" % (
                    keys[i].split("/")[1], keys[j].split("/")[1], dist, dur_diff, cen_diff))
                if dist < 1.2 and dur_diff < 0.02 and cen_diff < 80:
                    problems.append("%s y %s son casi idénticos" % (keys[i], keys[j]))

    report = []
    hdr = "%-34s %6s %3s %8s %8s %8s %6s %6s %8s %7s %7s %7s" % (
        "archivo", "dur s", "can", "pico dB", "real dB", "rms dB", "satur", "clics", "centr Hz", "atq ms", "t40 ms", "fin dB")
    report.append(hdr)
    report.append("-" * len(hdr))
    for key, m in rows:
        report.append("%-34s %6.3f %3d %8.2f %8.2f %8.2f %6d %6d %8.0f %7.1f %7.0f %7.1f" % (
            key.split("/")[1], m["dur"], m["channels"], m["peak_db"], m["true_peak_db"], m["rms_db"],
            m["clipped"], m["clicks"], m["centroid"], m["attack_ms"], m["t40_ms"], m["end_db"]))
    report.append("")
    report.append("Parecido entre variaciones:")
    report.extend(lines_var)
    report.append("")
    report.append("%d archivos medidos; %d problemas" % (len(rows), len(problems)))
    for p in problems:
        report.append("  PROBLEMA: " + p)

    out.mkdir(parents=True, exist_ok=True)
    (out / "informe.txt").write_text("\n".join(report) + "\n", encoding="utf-8")
    print("\n".join(report))

    if not args.no_images:
        for key, (x, rate, m, s) in loaded.items():
            sub = "%.2f s, %s, pico %.1f dBFS (real %.1f), RMS %.1f dBFS, centroide %.0f Hz, ataque %.1f ms" % (
                m["dur"], "estéreo" if m["channels"] == 2 else "mono", m["peak_db"], m["true_peak_db"], m["rms_db"],
                m["centroid"], m["attack_ms"])
            img = render_spectrogram(x, rate, key + ".ogg", sub)
            dest = out / "espectrogramas" / (key + ".png")
            dest.parent.mkdir(parents=True, exist_ok=True)
            img.save(dest)
        for group, cats in GROUPS.items():
            entries = []
            for key, (x, rate, m, s) in loaded.items():
                if s["category"] in cats:
                    entries.append((key.split("/")[1], "%.2f s, pico %.1f dB, centroide %.0f Hz" % (
                        m["dur"], m["peak_db"], m["centroid"]), x, rate))
            if entries:
                make_sheet(entries, "Eldmark: sonidos sintetizados, " + group, out / "hojas" / (group + ".png"))
        print("Espectrogramas en %s" % (out / "espectrogramas"))
    write_reel(loaded, out / "muestrario.wav")
    print("Muestrario en %s" % (out / "muestrario.wav"))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
