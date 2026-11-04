#!/usr/bin/env python3
"""Checks and plots the sounds in assets/audio/sfx so they can be reviewed without listening (ART-11).

Decodes each OGG with ffmpeg (what the game will play, not the signal before encoding) and:

  1. Measures duration, channels, sample rate, sample and true peak, K loudness of the active part,
     RMS of the active part, clipped samples, DC offset, stray clicks, centroid, attack, decay, the stretch
     within 6 dB of the peak, the rise from the start, the energy of the first 80 ms and the energy
     distribution across bands.
  2. Fails (exit code 1) if anything falls outside what the catalog asks for, the general rules (duration,
     peak ceiling, matched loudness, clicks, nearly identical variations, stale niveles.json, reverb
     baked into a 3D sound) or the quality bar of each family: the numbers from the art director's critique
     (envelope and fixed peak of the swings, low body of swings and hits, inharmonic tail of the
     parry, snap of footsteps on stone, impacts of the fall...). It is as close to "hearing it" as you can get
     without speakers: a sound that passes the numbers can still sound bad, one that fails them surely sounds bad.
  3. Plots one spectrogram per file (waveform on top, spectrogram on a logarithmic frequency axis from 40 Hz
     to 20 kHz below), summary sheets per family and, with `--antes`, comparison sheets with the previous version.

Output in build/audio/ (ignored by Git): espectrogramas/<category>/<name>.png, hojas/<group>.png,
comparativa/<group>.png, informe.txt and muestrario.wav (all the sounds in a row, with their volume trim,
to hear them all at once). Usage, from the project root (needs numpy, Pillow and ffmpeg/ffprobe on the PATH):

    python tools/audio/analyze_sfx.py
    python tools/audio/analyze_sfx.py --sfx assets/audio/sfx --out build/audio --no-images
    python tools/audio/analyze_sfx.py --antes build/antes/sfx      # also, before-and-after comparisons
"""

import argparse
import inspect
import json
import subprocess
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import synth_sfx as synth  # noqa: E402  (el catálogo vive en el generador)
import sfx_dsp as dsp  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
SR = dsp.SR
TARGET_PEAK_DB = dsp.PEAK_DB
TARGET_LOUD_DB = dsp.LOUD_DB
MIN_COUNT = {  # minimum variations of each thing (critical: 8-10 footsteps, 5-6 light swings, 4-6 hits, 3 falls)
    "sword_swing_light": 5, "sword_swing_heavy": 2, "hit_flesh": 4, "hit_leather": 4, "hit_gambeson": 4, "hit_mail": 4,
    "hit_shield_wood": 4, "hit_shield_metal": 3, "clash_metal": 3, "step_dirt": 8, "step_stone": 8, "body_fall": 3,
    "dodge_roll": 3, "dodge_step": 2, "bow_draw": 2, "bow_release": 3, "arrow_hit_flesh": 3, "arrow_hit_wood": 2,
    "hollow_hurt": 4, "hollow_death": 2, "potion_drink": 1, "ui_click": 1, "ui_confirm": 1,
    "horn_fort_won_vardheim": 1, "horn_fort_won_solmarch": 1, "horn_fort_won_askarra": 1,
    "horn_fort_lost_vardheim": 1, "horn_fort_lost_solmarch": 1, "horn_fort_lost_askarra": 1,
}
GROUPS = {  # spectrogram sheet -> categories
    "barridos": ("swing",),
    "golpes": ("hit_flesh", "hit_leather", "hit_gambeson", "hit_mail"),
    "escudo_y_parada": ("hit_shield", "parry"),
    "pasos": ("step_dirt", "step_stone"),
    "cuerpo_y_esquiva": ("body", "dodge"),
    "arco": ("bow", "arrow"),
    "voces_y_mundo": ("hollow", "potion", "ui", "alert"),
}
# Comparison pairs with the previous version when the name changed: new -> old.
RENAMED = {"alert/horn_fort_won_askarra_01": "alert/horn_fort_capture_01"}
# Order of the comparison sheets: (name, [new files]).
COMPARE = {
    "barridos": ["swing/sword_swing_light_01", "swing/sword_swing_light_02", "swing/sword_swing_heavy_01",
                 "swing/sword_swing_heavy_02"],
    "golpes_y_parada": ["hit_flesh/hit_flesh_01", "hit_flesh/hit_flesh_02", "hit_flesh/hit_flesh_03",
                        "parry/clash_metal_01", "parry/clash_metal_02"],
    "pasos_y_cuerpo": ["step_stone/step_stone_01", "step_stone/step_stone_02", "step_dirt/step_dirt_01",
                       "step_dirt/step_dirt_02", "body/body_fall_01"],
    "cuerno_e_interfaz": ["alert/horn_fort_won_askarra_01", "ui/ui_confirm_01", "potion/potion_drink_01"],
}


# ---------------------------------------------------------------------------
# Decoding and measurements
# ---------------------------------------------------------------------------

def decode(path):
    """Returns (float64 signal [n] or [n, channels], sample rate)."""
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


true_peak = dsp.true_peak
band = dsp.band_fraction


def measure(x, rate):
    mono = x if x.ndim == 1 else x.mean(axis=1)
    env = np.max(np.abs(x), axis=1) if x.ndim == 2 else np.abs(x)
    n = len(mono)
    lv = dsp.measure_levels(x)
    spec = np.abs(np.fft.rfft(mono * np.hanning(n))) ** 2
    freqs = np.fft.rfftfreq(n, 1.0 / rate)
    # Smoothed envelope (2 ms) for the attack and decay.
    win = max(1, int(rate * 0.002))
    sm = np.convolve(env, np.ones(win) / win, mode="same")
    ipk = int(np.argmax(sm))
    first = int(np.argmax(sm > sm[ipk] * 0.05))
    reach90 = int(np.argmax(sm > sm[ipk] * 0.9))
    after = np.nonzero(sm[ipk:] < sm[ipk] * 10 ** (-40 / 20))[0]
    # Clicks: isolated jumps between samples (7 times that of their ±4 ms neighborhood), after the first 12 ms.
    d = np.diff(mono)
    w = int(rate * 0.004)
    local = np.sqrt(np.convolve(d * d, np.ones(2 * w + 1) / (2 * w + 1), mode="same") + 1e-12)
    clicks = int(np.sum((np.abs(d) > 7 * local) & (np.abs(d) > 0.01) & (np.arange(len(d)) > int(rate * 0.012))))
    e10 = dsp.env10(x)
    ip10 = int(np.argmax(e10))
    onset = int(np.argmax(np.abs(mono) > np.max(np.abs(mono)) * 0.1))
    cum = np.cumsum(mono ** 2)
    return dict(
        clicks=clicks,
        dur=lv["dur"], channels=lv["channels"], rate=rate,
        peak_db=lv["peak_db"], true_peak_db=lv["true_peak_db"], rms_db=lv["rms_db"], loud_db=lv["loud_db"],
        peak_t=lv["peak_t"],
        clipped=int(np.sum(env >= 0.999)),
        dc=float(np.mean(mono)),
        start_db=db(env[0]),
        end_db=db(env[-max(1, int(rate * 0.005)):].max()),
        centroid=float(np.sum(freqs * spec) / np.sum(spec)),
        attack_ms=(reach90 - first) / rate * 1000.0,
        t40_ms=((ipk + int(after[0])) - ipk) / rate * 1000.0 if len(after) else (n - ipk) / rate * 1000.0,
        span6_ms=dsp.span_db(x) * 1000.0,
        rise_db=db(e10[ip10] / max(e10[int(0.005 * rate)], 1e-9)),
        onset_ms=onset / rate * 1000.0,
        e80=float(cum[min(n - 1, int(0.08 * rate))] / cum[-1]),
        low150=band(x, 20, 150))


def band_spectrum(x, rate):
    """Mean spectrum in third-octave bands (dB relative to the total), to compare variations."""
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


def centroid_window(x, t0, t1, f_min=500.0):
    """Spectral centroid (Hz, above `f_min`: the low body goes neither up nor down) between t0 and t1 s."""
    mono = x if x.ndim == 1 else x.mean(axis=1)
    seg = mono[max(0, int(t0 * SR)):int(t1 * SR)]
    if len(seg) < 64:
        return 0.0
    spec = np.abs(np.fft.rfft(seg * np.hanning(len(seg)), 4096)) ** 2
    f = np.fft.rfftfreq(4096, 1.0 / SR)
    spec = np.where(f >= f_min, spec, 0.0)
    return float(np.sum(f * spec) / (np.sum(spec) + 1e-18))


def tail_peaks(x, t0, k=2, half_width=25.0):
    """Fraction of the tail's energy (from t0 s) that falls in the `k` strongest spectrum peaks
    (±`half_width` Hz) and in the 2 to 9 kHz band: a door timbre has almost everything in two sines."""
    mono = x if x.ndim == 1 else x.mean(axis=1)
    tail = mono[int(t0 * SR):]
    nfft = 1 << 17
    spec = np.abs(np.fft.rfft(tail * np.hanning(len(tail)), nfft)) ** 2
    f = np.fft.rfftfreq(nfft, 1.0 / SR)
    total = spec[f > 40].sum() + 1e-18
    work = spec.copy()
    work[f <= 40] = 0.0
    taken = 0.0
    freqs = []
    for _ in range(k):
        i = int(np.argmax(work))
        m = (f > f[i] - half_width) & (f < f[i] + half_width)
        taken += work[m].sum()
        work[m] = 0.0
        freqs.append(float(f[i]))
    return taken / total, float(spec[(f >= 2000) & (f < 9000)].sum() / total), freqs


def count_impacts(x, min_gap=0.05, floor_db=-14.0, valley_db=4.0):
    """Counts the clear impacts: maxima of the 4 ms envelope within `floor_db` of the peak, separated by
    `min_gap` s and with a valley of at least `valley_db` between one and the next."""
    mono = x if x.ndim == 1 else x.mean(axis=1)
    h = max(1, int(SR * 0.004))
    e = np.sqrt(np.convolve(mono * mono, np.ones(h) / h, mode="same") + 1e-18)
    e = e / e.max()
    w = int(SR * 0.015)
    cand = [i for i in np.nonzero(e > 10 ** (floor_db / 20))[0] if e[i] >= e[max(0, i - w):i + w + 1].max()]
    peaks = []
    for i in cand:
        if peaks and i - peaks[-1] < min_gap * SR:
            if e[i] > e[peaks[-1]]:
                peaks[-1] = i
            continue
        if peaks and e[peaks[-1]:i].min() > e[i] * 10 ** (-valley_db / 20):
            continue
        peaks.append(i)
    return len(peaks)


# ---------------------------------------------------------------------------
# The bar: what the art director's critique asks for, family by family
# ---------------------------------------------------------------------------

def rule_swing(light):
    span_max = 60.0 if light else 120.0
    band_lo, band_hi = (250, 600) if light else (120, 400)

    def check(x, m, s):
        out = []
        if m["span6_ms"] > span_max:
            out.append("tramo a menos de 6 dB del pico: %.0f ms (máximo %.0f)" % (m["span6_ms"], span_max))
        if m["rise_db"] < 15.0:
            out.append("sube solo %.0f dB desde el arranque hasta el pico (mínimo 15)" % m["rise_db"])
        frac = band(x, band_lo, band_hi)
        if frac < 0.20:
            out.append("cuerpo grave de %d-%d Hz: %.0f %% de la energía (mínimo 20 %%)" % (band_lo, band_hi, frac * 100))
        if not light and band(x, 1000, 4000) > 0.60:
            out.append("el fuerte no pesa: %.0f %% de la energía entre 1 y 4 kHz (máximo 60 %%)" % (band(x, 1000, 4000) * 100))
        # True Doppler: the centroid above 500 Hz rises toward the peak and falls afterwards. It is measured in
        # 30 ms windows; the maximum must fall near the peak and exceed the start and the end by 25 %.
        t = m["peak_t"]
        starts = np.arange(0.0, m["dur"] - 0.03, 0.015)
        cs = np.array([centroid_window(x, t0, t0 + 0.03) for t0 in starts])
        i = int(np.argmax(cs))
        if not (t - 0.10 <= starts[i] + 0.015 <= t + 0.04 and cs[i] >= 1.25 * cs[0] and cs[i] >= 1.25 * cs[-1]):
            out.append("sin Doppler: centroide %.0f Hz al arrancar, máximo de %.0f Hz a los %.0f ms (pico a los %.0f) y %.0f al acabar" % (
                cs[0], cs[i], (starts[i] + 0.015) * 1000, t * 1000, cs[-1]))
        return out
    return check


def rule_hit(x, m, s):
    out = []
    if m["e80"] < 0.90:
        out.append("solo el %.0f %% de la energía cae en los primeros 80 ms (mínimo 90 %%)" % (m["e80"] * 100))
    if m["span6_ms"] > 60.0:
        out.append("tramo a menos de 6 dB del pico: %.0f ms (máximo 60)" % m["span6_ms"])
    f = band(x, 60, 120)
    if f < 0.20:
        out.append("golpe sordo de 60-120 Hz: %.0f %% de la energía (mínimo 20 %%)" % (f * 100))
    if m["peak_t"] > 0.025:
        out.append("el pico llega a los %.0f ms (máximo 25)" % (m["peak_t"] * 1000))
    return out


def rule_shield_wood(x, m, s):
    return ["el pico llega a los %.0f ms" % (m["peak_t"] * 1000)] if m["peak_t"] > 0.012 else []


def rule_shield_metal(x, m, s):
    out = []
    if m["dur"] > 0.45:
        out.append("dura %.2f s: un bloqueo se apaga en 0,45 s como mucho para no confundirse con la parada" % m["dur"])
    mono = x if x.ndim == 1 else x.mean(axis=1)
    e150 = float(np.sum(mono[:int(0.15 * SR)] ** 2) / (np.sum(mono ** 2) + 1e-18))
    if e150 < 0.92:
        out.append("solo el %.0f %% de la energía cae en los primeros 150 ms: tiene cola y se parece a la parada" % (e150 * 100))
    return out


def rule_clash(x, m, s):
    out = []
    top2, hi, freqs = tail_peaks(x, 0.15)
    if top2 > 0.30:
        out.append("timbre de puerta: %.0f %% de la cola en dos senos (%.0f y %.0f Hz; máximo 30 %%)" % (top2 * 100, freqs[0], freqs[1]))
    if hi < 0.60:
        out.append("solo el %.0f %% de la cola entre 2 y 9 kHz (mínimo 60 %%)" % (hi * 100))
    if m["dur"] < 0.35:
        out.append("dura solo %.2f s: la parada ha de sonar y colear" % m["dur"])
    if m["peak_t"] > 0.015:
        out.append("el golpe llega a los %.0f ms" % (m["peak_t"] * 1000))
    return out


def rule_step_stone(x, m, s):
    out = []
    f_mid = band(x, 500, 1000, 0.0, 0.1)
    f_hi = band(x, 2000, 8000, 0.0, 0.1)
    f_lo = band(x, 80, 150, 0.0, 0.1)
    if f_mid > 0.25:
        out.append("«tock» de madera: %.0f %% de los primeros 100 ms entre 500 y 1000 Hz (máximo 25 %%)" % (f_mid * 100))
    if f_hi < 0.30:
        out.append("falta el chasquido: %.0f %% de los primeros 100 ms entre 2 y 8 kHz (mínimo 30 %%)" % (f_hi * 100))
    if f_lo < 0.08:
        out.append("falta el golpe sordo: %.0f %% de los primeros 100 ms entre 80 y 150 Hz (mínimo 8 %%)" % (f_lo * 100))
    if m["onset_ms"] > 5.0:
        out.append("el talón entra a los %.1f ms (máximo 5)" % m["onset_ms"])
    return out


def rule_step_dirt(x, m, s):
    return ["el talón entra a los %.1f ms (máximo 5)" % m["onset_ms"]] if m["onset_ms"] > 5.0 else []


def rule_body(x, m, s):
    out = []
    if m["low150"] < 0.35:
        out.append("solo el %.0f %% de la energía bajo 150 Hz (mínimo 35 %%)" % (m["low150"] * 100))
    k = count_impacts(x)
    if not 2 <= k <= 4:
        out.append("%d impactos claros (se piden 2 o 3)" % k)
    if m["peak_t"] > 0.03:
        out.append("el pico llega a los %.0f ms: el torso ha de caer primero" % (m["peak_t"] * 1000))
    if m["span6_ms"] > 130.0:
        out.append("tramo a menos de 6 dB del pico: %.0f ms (máximo 130)" % m["span6_ms"])
    return out


def rule_potion(x, m, s):
    out = []
    mono = x if x.ndim == 1 else x.mean(axis=1)
    first = np.sqrt(np.mean(mono[:int(0.04 * SR)] ** 2)) + 1e-12
    gap = np.sqrt(np.mean(mono[int(0.05 * SR):int(0.15 * SR)] ** 2)) + 1e-12
    if db(gap / first) > -22.0:
        out.append("el corcho dura más de 40 ms: el nivel de 50 a 150 ms está a %.0f dB del pop (máximo -22)" % db(gap / first))
    return out


def rule_horn(x, m, s):
    out = []
    first = x[:int(0.15 * SR)]
    if first.ndim == 2 and np.std(first[:, 0]) > 1e-6 and np.std(first[:, 1]) > 1e-6:
        corr = float(np.corrcoef(first[:, 0], first[:, 1])[0, 1])
        if corr < 0.95:
            out.append("no es una sola voz centrada: correlación izquierda-derecha %.2f (mínimo 0,95)" % corr)
    return out


RULES = {
    "sword_swing_light": rule_swing(True), "sword_swing_heavy": rule_swing(False),
    "hit_flesh": rule_hit, "hit_leather": rule_hit, "hit_gambeson": rule_hit, "hit_mail": rule_hit,
    "hit_shield_wood": rule_shield_wood, "hit_shield_metal": rule_shield_metal, "clash_metal": rule_clash,
    "step_stone": rule_step_stone, "step_dirt": rule_step_dirt, "body_fall": rule_body, "potion_drink": rule_potion,
}
for _name in synth.SOUNDS:
    if _name["name"].startswith("horn_fort_"):
        RULES[_name["name"]] = rule_horn


# ---------------------------------------------------------------------------
# Spectrograms
# ---------------------------------------------------------------------------

_CMAP = np.array([
    (0.00, 0, 0, 4), (0.13, 31, 12, 72), (0.25, 85, 15, 109), (0.38, 136, 34, 106), (0.50, 186, 54, 85),
    (0.63, 227, 89, 51), (0.75, 249, 140, 10), (0.88, 249, 201, 50), (1.00, 252, 255, 164)])


def colormap(v):
    """Inferno-style color map for values in 0..1; returns uint8 [..., 3]."""
    v = np.clip(v, 0.0, 1.0)
    out = np.empty(v.shape + (3,))
    for c in range(3):
        out[..., c] = np.interp(v, _CMAP[:, 0], _CMAP[:, c + 1])
    return out.astype(np.uint8)


def spectrogram_db(mono, rate, width, rows, f_lo=40.0, f_hi=20000.0, floor_db=-85.0):
    """Matrix [rows, width] in 0..1: dB relative to the maximum, rows on a logarithmic frequency axis (top, treble)."""
    dur = len(mono) / rate
    n_fft = 512 if dur < 0.12 else 1024  # short sounds lose low-frequency resolution, but gain time resolution
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
    return img.T[::-1]  # treble on top


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
    """PNG with waveform and spectrogram. Returns a PIL image."""
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

    # Waveform (minimum and maximum per column; if stereo, the channel with the most amplitude).
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

    # Spectrogram.
    y1 = y0 + h_wave + 8
    spec = spectrogram_db(mono, rate, w_plot, h_spec)
    img.paste(Image.fromarray(colormap(spec)), (ml, y1))
    d.rectangle([ml, y1, ml + w_plot, y1 + h_spec], outline=(60, 60, 70))
    f_lo, f_hi = 40.0, 20000.0
    for f, label in ((100, "100"), (500, "500"), (1000, "1k"), (2000, "2k"), (5000, "5k"), (10000, "10k"), (16000, "16k")):
        yy = y1 + (h_spec - 1) * (1 - np.log(f / f_lo) / np.log(f_hi / f_lo))
        d.line([ml - 4, yy, ml, yy], fill=dim)
        d.line([ml, yy, ml + w_plot, yy], fill=(70, 60, 70))
        d.text((ml - 6 - d.textlength(label, font=small), yy - fs_small / 2 - 1), label, fill=dim, font=small)

    # Time axis.
    step = 0.02 if dur < 0.2 else 0.05 if dur < 0.45 else 0.1 if dur < 1.0 else 0.25 if dur < 2.2 else 0.5
    k = 0
    while k * step <= dur + 1e-9:
        xx = ml + (k * step / dur) * w_plot
        d.line([xx, y1 + h_spec, xx, y1 + h_spec + 4], fill=dim)
        label = ("%.2f" % (k * step)).rstrip("0").rstrip(".") + (" s" if k == 0 else "")
        d.text((xx - d.textlength(label, font=small) / 2, y1 + h_spec + 5), label, fill=dim, font=small)
        k += 1
    return img


def make_sheet(entries, title, path, cols=3):
    """Sheet with one thumbnail per file, in rows of `cols`."""
    from PIL import Image, ImageDraw
    thumbs = [render_spectrogram(x, r, name, sub, compact=True) for (name, sub, x, r) in entries]
    cw, ch = thumbs[0].size
    rows = (len(thumbs) + cols - 1) // cols
    top = 40
    sheet = Image.new("RGB", (cols * cw, top + rows * ch), (18, 18, 22))
    ImageDraw.Draw(sheet).text((12, 8), title, fill=(235, 235, 240), font=_font(20))
    for i, t in enumerate(thumbs):
        sheet.paste(t, ((i % cols) * cw, top + (i // cols) * ch))
    path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(path)


def make_comparison(pairs, title, path):
    """Two-column sheet: the previous version on the left, the new one on the right, one row per sound."""
    from PIL import Image, ImageDraw
    thumbs = []
    for name, old, new in pairs:
        (xo, ro, mo), (xn, rn, mn) = old, new
        thumbs.append(render_spectrogram(xo, ro, "ANTES  " + name, "%.2f s, centroide %.0f Hz" % (mo["dur"], mo["centroid"]), True))
        thumbs.append(render_spectrogram(xn, rn, "AHORA  " + name, "%.2f s, centroide %.0f Hz" % (mn["dur"], mn["centroid"]), True))
    cw, ch = thumbs[0].size
    rows = len(thumbs) // 2
    top = 40
    sheet = Image.new("RGB", (2 * cw, top + rows * ch), (18, 18, 22))
    ImageDraw.Draw(sheet).text((12, 8), title, fill=(235, 235, 240), font=_font(20))
    for i, t in enumerate(thumbs):
        sheet.paste(t, ((i % 2) * cw, top + (i // 2) * ch))
    path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(path)


# ---------------------------------------------------------------------------
# Sampler
# ---------------------------------------------------------------------------

def write_reel(loaded, path):
    """16-bit WAV with all the sounds in a row (with the catalog's `volume_db` trim and 0.45 s of
    silence between them) to listen to them in one go."""
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
# Main program
# ---------------------------------------------------------------------------

def check_levels_file(sfx, loaded, problems):
    """niveles.json must say the same thing that is measured in the OGGs (the first version gave -10.98 and -9.46)."""
    path = sfx / "niveles.json"
    if not path.exists():
        problems.append("niveles.json: no existe")
        return
    meta = json.loads(path.read_text(encoding="utf-8"))
    sonidos = meta.get("sonidos", {})
    for key, (x, rate, m, s) in loaded.items():
        e = sonidos.get(key)
        if e is None:
            problems.append("niveles.json: falta %s" % key)
            continue
        for field, got, tol in (("duracion_s", m["dur"], 0.002), ("pico_s", m["peak_t"], 0.002),
                                ("pico_real_dbfs", m["true_peak_db"], 0.06), ("rms_activo_dbfs", m["rms_db"], 0.06),
                                ("sonoridad_activa_db", m["loud_db"], 0.06)):
            if abs(e.get(field, 1e9) - got) > tol:
                problems.append("niveles.json desfasado en %s: %s dice %s, el OGG mide %.3f" % (key, field, e.get(field), got))
        if e.get("volume_db", 1.0) > 0.0:
            problems.append("niveles.json: %s tiene volume_db positivo (%s)" % (key, e.get("volume_db")))
        if abs(e.get("volume_db", 0.0) - s["mix_db"]) > 1e-6:
            problems.append("niveles.json: %s tiene volume_db %s y el catálogo %s" % (key, e.get("volume_db"), s["mix_db"]))
    extra = set(sonidos) - set(loaded)
    if extra:
        problems.append("niveles.json: sobran %s" % ", ".join(sorted(extra)))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--sfx", default=str(ROOT / "assets" / "audio" / "sfx"))
    ap.add_argument("--out", default=str(ROOT / "build" / "audio"))
    ap.add_argument("--antes", help="carpeta con la versión anterior de los sonidos, para las hojas de comparación")
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
        if m["true_peak_db"] > TARGET_PEAK_DB + 0.3:
            problems.append("%s: pico real %.2f dBTP, por encima del techo %.1f" % (key, m["true_peak_db"], TARGET_PEAK_DB))
        if m["peak_db"] > -1.0:
            problems.append("%s: pico de muestra %.2f dBFS, por encima de -1,0" % (key, m["peak_db"]))
        limited = m["true_peak_db"] > TARGET_PEAK_DB - 0.4  # the ceiling rules, not the loudness
        if abs(m["loud_db"] - TARGET_LOUD_DB) > 0.4 and not (limited and m["loud_db"] < TARGET_LOUD_DB):
            problems.append("%s: sonoridad %.2f dB, lejos de la igualada (%.1f)" % (key, m["loud_db"], TARGET_LOUD_DB))
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
        if s["peak_s"] is not None and abs(m["peak_t"] - s["peak_s"][0]) > s["peak_s"][1]:
            problems.append("%s: el pico cae a los %.0f ms, se pide %.0f ± %.0f ms" % (
                key, m["peak_t"] * 1000, s["peak_s"][0] * 1000, s["peak_s"][1] * 1000))
        if s["dry"]:
            src = inspect.getsource(s["fn"])
            if "reverb(" in src or "reverb_stereo(" in src:
                problems.append("%s: lleva reverberación horneada y va en 3D (que la ponga el motor)" % key)
        rule = RULES.get(s["name"])
        if rule is not None:
            for msg in rule(x, m, s):
                problems.append("%s: %s" % (key, msg))
        rows.append((key, m))

    for base, need in MIN_COUNT.items():
        have = len(names_by_base.get(base, []))
        if have < need:
            problems.append("%s: %d variaciones, se piden al menos %d" % (base, have, need))

    check_levels_file(sfx, loaded, problems)

    # Variations: they should not be the same thing with different noise.
    lines_var = []
    var_summary = []
    for base, keys in names_by_base.items():
        if len(keys) < 2:
            continue
        specs = {k: band_spectrum(loaded[k][0], loaded[k][1]) for k in keys}
        dists = []
        cdiffs = []
        for i in range(len(keys)):
            for j in range(i + 1, len(keys)):
                dist = float(np.sqrt(np.mean((specs[keys[i]] - specs[keys[j]]) ** 2)))
                dur_diff = abs(loaded[keys[i]][2]["dur"] - loaded[keys[j]][2]["dur"])
                cen_diff = abs(loaded[keys[i]][2]["centroid"] - loaded[keys[j]][2]["centroid"])
                dists.append(dist)
                cdiffs.append(cen_diff)
                lines_var.append("%-38s %-38s distancia espectral %5.1f dB, dif. duración %.2f s, dif. centroide %5.0f Hz" % (
                    keys[i].split("/")[1], keys[j].split("/")[1], dist, dur_diff, cen_diff))
                if dist < 1.2 and dur_diff < 0.02 and cen_diff < 80:
                    problems.append("%s y %s son casi idénticos" % (keys[i], keys[j]))
        var_summary.append("%-24s %2d variaciones: distancia espectral mín %4.1f media %4.1f dB, dif. de centroide mín %4.0f media %4.0f Hz" % (
            base, len(keys), min(dists), float(np.mean(dists)), min(cdiffs), float(np.mean(cdiffs))))
        need = 5.0 if base.startswith("step_") else 2.5
        if float(np.mean(dists)) < need:
            problems.append("%s: las variaciones se parecen demasiado (distancia espectral media %.1f dB, mínimo %.1f)" % (
                base, float(np.mean(dists)), need))

    report = []
    hdr = "%-30s %6s %3s %8s %8s %8s %8s %6s %6s %8s %6s %6s %6s %6s %7s" % (
        "archivo", "dur s", "can", "pico dB", "real dB", "rms dB", "sonor dB", "satur", "clics", "centr Hz", "pico ms",
        "tr6 ms", "sube dB", "e80 %", "fin dB")
    report.append(hdr)
    report.append("-" * len(hdr))
    for key, m in rows:
        report.append("%-30s %6.3f %3d %8.2f %8.2f %8.2f %8.2f %6d %6d %8.0f %6.0f %6.0f %6.0f %6.0f %7.1f" % (
            key.split("/")[1], m["dur"], m["channels"], m["peak_db"], m["true_peak_db"], m["rms_db"], m["loud_db"],
            m["clipped"], m["clicks"], m["centroid"], m["peak_t"] * 1000, m["span6_ms"], m["rise_db"], m["e80"] * 100, m["end_db"]))
    report.append("")
    report.append("Variación dentro de cada grupo:")
    report.extend(var_summary)
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
            sub = "%.2f s, %s, pico %.1f dBFS (real %.1f), sonoridad %.1f dB, centroide %.0f Hz, tramo -6 dB %.0f ms" % (
                m["dur"], "estéreo" if m["channels"] == 2 else "mono", m["peak_db"], m["true_peak_db"], m["loud_db"],
                m["centroid"], m["span6_ms"])
            img = render_spectrogram(x, rate, key + ".ogg", sub)
            dest = out / "espectrogramas" / (key + ".png")
            dest.parent.mkdir(parents=True, exist_ok=True)
            img.save(dest)
        for group, cats in GROUPS.items():
            entries = []
            for key, (x, rate, m, s) in loaded.items():
                if s["category"] in cats:
                    entries.append((key.split("/")[1], "%.2f s, pico %.0f ms, centroide %.0f Hz" % (
                        m["dur"], m["peak_t"] * 1000, m["centroid"]), x, rate))
            if entries:
                make_sheet(entries, "Eldmark: sonidos sintetizados, " + group.replace("_", " "), out / "hojas" / (group + ".png"))
        print("Espectrogramas en %s" % (out / "espectrogramas"))
        if args.antes:
            antes = Path(args.antes)
            for group, keys in COMPARE.items():
                pairs = []
                for key in keys:
                    old_key = RENAMED.get(key, key)
                    old_path = antes / (old_key + ".ogg")
                    if key not in loaded or not old_path.exists():
                        continue
                    xo, ro = decode(old_path)
                    pairs.append((key.split("/")[1], (xo, ro, measure(xo, ro)), loaded[key][:3]))
                if pairs:
                    make_comparison(pairs, "Eldmark: sonido antes y después, " + group.replace("_", " "), out / "comparativa" / (group + ".png"))
            print("Comparativas en %s" % (out / "comparativa"))
    write_reel(loaded, out / "muestrario.wav")
    print("Muestrario en %s" % (out / "muestrario.wav"))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
