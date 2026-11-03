#!/usr/bin/env python3
"""Sonidos de Eldmark sintetizados desde cero (ART-11): sin muestras de terceros.

Todo sale de síntesis y procesado con numpy (sin scipy) y se pasa a OGG Vorbis con ffmpeg:

    ruido filtrado   barridos de espada, golpes, pasos (filtro de estado variable en el tiempo)
    modos resonantes golpes de madera y de metal, campanillas (suma de senos que se apagan)
    sintesis aditiva el cuerno (armónicos que se abren con la fuerza, como un metal real)
    granos           la gravilla de los pasos, los tintineos del equipo, las burbujas
    reverberación    respuesta al impulso sintética (ruido con caída por bandas) por convolución FFT

Cada sonido tiene una semilla fija: ejecutar el script dos veces da los mismos archivos, bit a bit.

Salida (assets/audio/sfx/<categoría>/<nombre>_NN.ogg):

    swing/          sword_swing_light_01..03, sword_swing_heavy_01..02
    hit_flesh/      hit_flesh_01..03        (espada contra carne y cuero)
    hit_shield/     hit_shield_wood_01..03  (golpe en escudo de madera)
    parry/          clash_metal_01..02      (choque de acero con acero)
    step_dirt/      step_dirt_01..03
    step_stone/     step_stone_01..03
    body/           body_fall_01
    potion/         potion_drink_01
    ui/             ui_click_01, ui_confirm_01
    alert/          horn_fort_capture_01    (cuerno corto de captura del fuerte, estéreo)

Todos son mono a 44,1 kHz salvo el cuerno y la confirmación de interfaz (estéreo, por la reverberación).
Cada archivo se normaliza a un pico real de -1,5 dBFS medido sobre el OGG decodificado (Vorbis rebasa los picos agudos, así que se codifica, se mide y se corrige); el equilibrio de volumen entre categorías no está
en los archivos, sino en `niveles.json` (campo `volume_db`, el recorte que debe aplicar el reproductor).
`tools/audio/analyze_sfx.py` mide picos y duraciones sobre los OGG ya codificados y dibuja los
espectrogramas.

Uso, desde la raíz del proyecto (necesita numpy y ffmpeg en el PATH):

    python tools/audio/synth_sfx.py                    # genera todo
    python tools/audio/synth_sfx.py --only clash       # solo los que contengan «clash»
    python tools/audio/synth_sfx.py --list             # lista el catálogo
"""

import argparse
import json
import shutil
import subprocess
import sys
import time
import zlib
from pathlib import Path

import numpy as np

SR = 44100
PEAK_DB = -1.5  # pico real (sobremuestreado) de cada OGG ya codificado
ROOT = Path(__file__).resolve().parents[2]
OUT_ROOT = ROOT / "assets" / "audio" / "sfx"
TWO_PI = 2.0 * np.pi


# ---------------------------------------------------------------------------
# Utilidades básicas
# ---------------------------------------------------------------------------

def ms(milliseconds):
    """Milisegundos a muestras."""
    return int(round(milliseconds * SR / 1000.0))


def sec(seconds):
    return int(round(seconds * SR))


def tvec(n):
    return np.arange(n) / SR


def rms(x):
    return float(np.sqrt(np.mean(np.square(x)))) + 1e-12


def unit(x):
    """Escala a RMS 1 (para capas continuas, como los barridos)."""
    return x / rms(x)


def pk(x):
    """Escala a pico 1 (para capas de transitorios)."""
    return x / (np.max(np.abs(x)) + 1e-12)


def place(dst, src, start_s, gain=1.0):
    """Suma `src` en `dst` desde `start_s` segundos (recorta lo que no cabe)."""
    i = sec(start_s)
    if i >= len(dst) or i + len(src) <= 0:
        return
    a = max(i, 0)
    b = min(len(dst), i + len(src))
    dst[a:b] += gain * src[a - i:b - i]


def sat(x, drive=1.5):
    """Saturación suave (tanh) manteniendo el pico: da cuerpo a los golpes."""
    p = np.max(np.abs(x)) + 1e-12
    return np.tanh(drive * x / p) / np.tanh(drive) * p


def noise(n, rng, slope_db=0.0):
    """Ruido blanco (slope 0) o coloreado con `slope_db` dB por octava (-3 = rosa, -6 = marrón)."""
    w = rng.standard_normal(n)
    if slope_db == 0.0:
        return w
    spec = np.fft.rfft(w)
    f = np.fft.rfftfreq(n, 1.0 / SR)
    f[0] = f[1]
    spec *= (f / 1000.0) ** (slope_db / 6.0206)
    return unit(np.fft.irfft(spec, n))


def smooth_noise(n, rng, rate_hz):
    """Ruido lento (media 0, desviación 1) para modulaciones: interpola puntos al azar."""
    m = max(4, int(n / SR * rate_hz * 3) + 4)
    pts = rng.standard_normal(m)
    x = np.interp(np.linspace(0, m - 1, n), np.arange(m), pts)
    return x / (np.std(x) + 1e-12)


# ---------------------------------------------------------------------------
# Filtros
# ---------------------------------------------------------------------------

def svf(x, fc, q=0.7071, mode="lp"):
    """Filtro de estado variable (TPT, Zavalishin). `fc` y `q` pueden ser arrays por muestra.

    Modos: lp (paso bajo), bp (paso banda de ganancia 1 en el centro), hp (paso alto), notch.
    """
    x = np.asarray(x, dtype=np.float64)
    n = x.size
    fc = np.broadcast_to(np.asarray(fc, dtype=np.float64), (n,))
    q = np.broadcast_to(np.asarray(q, dtype=np.float64), (n,))
    g = np.tan(np.pi * np.clip(fc, 5.0, 0.46 * SR) / SR)
    k = 1.0 / np.maximum(q, 0.05)
    a1 = 1.0 / (1.0 + g * (g + k))
    a2 = g * a1
    a3 = g * a2
    xs = x.tolist()
    a1s = a1.tolist()
    a2s = a2.tolist()
    a3s = a3.tolist()
    v1s = [0.0] * n
    v2s = [0.0] * n
    ic1 = 0.0
    ic2 = 0.0
    for i in range(n):
        v3 = xs[i] - ic2
        v1 = a1s[i] * ic1 + a2s[i] * v3
        v2 = ic2 + a2s[i] * ic1 + a3s[i] * v3
        ic1 = 2.0 * v1 - ic1
        ic2 = 2.0 * v2 - ic2
        v1s[i] = v1
        v2s[i] = v2
    v1a = np.array(v1s)
    v2a = np.array(v2s)
    if mode == "lp":
        return v2a
    if mode == "bp":
        return k * v1a
    if mode == "hp":
        return x - k * v1a - v2a
    if mode == "notch":
        return x - k * v1a
    raise ValueError(mode)


def lp(x, fc, order=2):
    for _ in range(order):
        x = svf(x, fc, 0.7071, "lp")
    return x


def hp(x, fc, order=2):
    for _ in range(order):
        x = svf(x, fc, 0.7071, "hp")
    return x


def bp(x, fc, q):
    return svf(x, fc, q, "bp")


def bp2(x, fc, q):
    """Paso banda de dos etapas: laderas de 12 dB por octava (una sola etapa deja pasar demasiado agudo)."""
    return svf(svf(x, fc, q, "bp"), fc, q, "bp")


def taper(x, seconds=0.06):
    """Fundido de coseno en el final de un búfer cuyas capas no han llegado a callar (evita el escalón)."""
    k = min(len(x) // 2, sec(seconds))
    out = np.array(x, dtype=np.float64)
    out[-k:] *= np.cos(np.linspace(0.0, np.pi / 2, k)) ** 2
    return out


def dc_block(x):
    """Quita continua y subsónicos (sobre FFT, sin fase)."""
    n = len(x)
    pad = sec(0.3)  # relleno de ceros: evita que el filtro enrolle el principio con el final
    nfft = n + 2 * pad
    spec = np.fft.rfft(np.concatenate([np.zeros(pad), x, np.zeros(pad)]))
    f = np.fft.rfftfreq(nfft, 1.0 / SR)
    spec *= 1.0 / (1.0 + (22.0 / np.maximum(f, 1e-3)) ** 4)
    return np.fft.irfft(spec, nfft)[pad:pad + n]


# ---------------------------------------------------------------------------
# Envolventes y osciladores
# ---------------------------------------------------------------------------

def edecay(n, tau, attack=0.0005):
    """Caída exponencial (constante de tiempo `tau` en s) con ataque suave."""
    t = tvec(n)
    e = np.exp(-t / tau)
    if attack > 0:
        e *= 1.0 - np.exp(-t / attack)
    return e


def bump(n, a, b):
    """Campana u^a (1-u)^b normalizada a 1; el pico cae en a / (a + b) de la duración."""
    u = (np.arange(n) + 0.5) / n
    y = u ** a * (1.0 - u) ** b
    return y / y.max()


def sine_sweep(n, f_start, f_end, tau_f):
    """Seno cuya frecuencia cae (o sube) exponencialmente de `f_start` a `f_end`."""
    t = tvec(n)
    f = f_end + (f_start - f_end) * np.exp(-t / tau_f)
    return np.sin(TWO_PI * np.cumsum(f) / SR)


def modal(n, freqs, t60s, amps, rng=None, attack=0.0002):
    """Suma de senos que se apagan (síntesis modal). `t60s` en s hasta -60 dB."""
    t = tvec(n)
    out = np.zeros(n)
    for f, t60, a in zip(freqs, t60s, amps):
        if f >= 0.46 * SR:
            continue
        phase = rng.uniform(0, TWO_PI) if rng is not None else 0.0
        out += a * np.exp(-6.9078 * t / t60) * np.sin(TWO_PI * f * t + phase)
    return out * (1.0 - np.exp(-t / attack))


def grains(n, rng, count, scale_s, max_s, amp_tau=None):
    """Tren de impulsos con signo y amplitud al azar, más denso al principio (exponencial)."""
    x = np.zeros(n)
    times = np.minimum(rng.exponential(scale_s, count), max_s)
    idx = np.minimum((times * SR).astype(int), n - 1)
    amps = rng.uniform(0.25, 1.0, count) * rng.choice([-1.0, 1.0], count)
    if amp_tau is not None:
        amps = amps * np.exp(-times / amp_tau)
    np.add.at(x, idx, amps)
    return x


# ---------------------------------------------------------------------------
# Reverberación
# ---------------------------------------------------------------------------

def make_ir(rng, rt60, damp=0.4, predelay=0.0, early=1.0):
    """Respuesta al impulso: ruido que cae más deprisa cuanto más agudo (`damp` = RT60 agudo / RT60 grave)."""
    pd = sec(predelay)
    n = sec(rt60 * 1.1)
    t = tvec(n)
    w = rng.standard_normal(n)
    spec = np.fft.rfft(w)
    f = np.fft.rfftfreq(n, 1.0 / SR)
    low = 1.0 / (1.0 + (f / 450.0) ** 4)
    high = 1.0 / (1.0 + (3500.0 / np.maximum(f, 1.0)) ** 4)
    mid = np.clip(1.0 - low - high, 0.0, 1.0)
    diffuse = np.zeros(n)
    for mask, mult in ((low, 1.0), (mid, 0.7), (high, max(damp, 0.05))):
        band = np.fft.irfft(spec * mask, n)
        diffuse += band * np.exp(-6.9078 * t / (rt60 * mult))
    pad = sec(0.15)  # relleno de ceros: el filtro de fase cero no puede enrollar el principio con el final
    padded = np.concatenate([np.zeros(pad), diffuse, np.zeros(pad)])
    fp = np.fft.rfftfreq(len(padded), 1.0 / SR)
    padded = np.fft.irfft(np.fft.rfft(padded) / (1.0 + (130.0 / np.maximum(fp, 1.0)) ** 4), len(padded))
    diffuse = padded[pad:pad + n]  # sin barro grave
    diffuse *= 1.0 - np.exp(-t / 0.006)  # entrada suave de la cola
    ir = np.zeros(pd + n)
    ir[pd:] = diffuse * 0.5
    if early > 0:
        for tap_s in np.sort(rng.uniform(0.004, 0.035, 7)):
            amp = early * rng.uniform(0.4, 1.0) * np.exp(-tap_s / 0.03) * rng.choice([-1.0, 1.0])
            j = pd + sec(tap_s)
            ir[j:j + 3] += amp * np.array([0.5, 1.0, 0.5]) * 0.6
    return ir / np.sqrt(np.sum(ir * ir))


def reverb(x, rng, rt60=0.4, wet=0.15, damp=0.4, predelay=0.0, early=1.0):
    """Suma `wet` veces la señal reverberada (IR de energía unidad: wet 0,3 = -10 dB). Misma longitud."""
    n = len(x)
    ir = make_ir(rng, rt60, damp, predelay, early)
    nfft = 1 << (n + len(ir)).bit_length()
    y = np.fft.irfft(np.fft.rfft(x, nfft) * np.fft.rfft(ir, nfft), nfft)[:n]
    return x + wet * y


def reverb_stereo(x, rng, **kw):
    """Dos reverberaciones con respuestas distintas (decorreladas) sobre una señal mono o estéreo."""
    left = x if x.ndim == 1 else x[:, 0]
    right = x if x.ndim == 1 else x[:, 1]
    return np.stack([reverb(left, rng, **kw), reverb(right, rng, **kw)], axis=1)


# ---------------------------------------------------------------------------
# Catálogo y acabado
# ---------------------------------------------------------------------------

SOUNDS = []


def sound(category, name, count, mix_db, dur, stereo=False, grainy=False):
    """Registra un constructor `fn(rng, v) -> array` que se llama para v = 0..count-1.

    `mix_db`: recorte de volumen sugerido (va a niveles.json). `dur`: (mín, máx) en s que admite el
    comprobador. `grainy`: hecho de impulsos sueltos a propósito (gravilla, burbujas, tintineos), así que
    el comprobador no busca clics en él. El archivo se llama <name>_NN.ogg.
    """
    def deco(fn):
        SOUNDS.append(dict(category=category, name=name, count=count, mix_db=mix_db, dur=dur,
                           stereo=stereo, grainy=grainy, fn=fn))
        return fn
    return deco


def finalize(x):
    """Quita continua, recorta el silencio final, aplica fundidos y normaliza al pico objetivo."""
    x = np.asarray(x, dtype=np.float64)
    if x.ndim == 1:
        x = dc_block(x)
    else:
        x = np.stack([dc_block(x[:, c]) for c in range(x.shape[1])], axis=1)
    env = np.max(np.abs(x), axis=1) if x.ndim == 2 else np.abs(x)
    peak = float(env.max())
    above = np.nonzero(env > peak * 10 ** (-58 / 20))[0]
    end = min(len(x), int(above[-1]) + ms(12))
    x = x[:end]
    # Fundido de entrada (0,5 ms) y de salida (15 ms o el 25 % si es muy corto): sin clics.
    fin = ms(0.5)
    fout = min(ms(15), len(x) // 4)
    w = np.ones(len(x))
    w[:fin] = np.sin(np.linspace(0, np.pi / 2, fin)) ** 2
    w[-fout:] = np.cos(np.linspace(0, np.pi / 2, fout)) ** 2
    x = x * (w[:, None] if x.ndim == 2 else w)
    peak = float(np.max(np.abs(x)))
    return x * (10 ** (PEAK_DB / 20) / peak)


def true_peak(x):
    """Pico real (entre muestras): sobremuestrea x4 por FFT. Devuelve amplitud lineal."""
    peak = 0.0
    for c in (x.T if x.ndim == 2 else [x]):
        up = np.fft.irfft(np.fft.rfft(c), len(c) * 4) * 4.0
        peak = max(peak, float(np.max(np.abs(up))))
    return peak


def encode_ogg(x, path):
    """Codifica con libvorbis (calidad 6) a través de ffmpeg; `+bitexact` hace el archivo reproducible."""
    channels = 1 if x.ndim == 1 else x.shape[1]
    cmd = ["ffmpeg", "-v", "error", "-y", "-f", "f32le", "-ar", str(SR), "-ac", str(channels), "-i", "pipe:0",
           "-map_metadata", "-1", "-c:a", "libvorbis", "-q:a", "6",
           "-fflags", "+bitexact", "-flags:a", "+bitexact", str(path)]  # opciones de salida: serie Ogg fija
    data = np.ascontiguousarray(x, dtype="<f4").tobytes()
    res = subprocess.run(cmd, input=data, capture_output=True)
    if res.returncode != 0:
        raise RuntimeError("ffmpeg falló con %s: %s" % (path, res.stderr.decode(errors="replace")))


def decode_ogg(path, channels):
    """Lee el OGG tal y como lo oirá el juego (float64, [n] o [n, canales])."""
    res = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-f", "f32le", "-acodec", "pcm_f32le", "-"],
                         capture_output=True, check=True)
    x = np.frombuffer(res.stdout, dtype="<f4").astype(np.float64)
    return x.reshape(-1, channels) if channels > 1 else x


def encode_normalized(x, path):
    """Codifica y ajusta la ganancia hasta que el pico real del OGG decodificado sea PEAK_DB.

    Vorbis rebasa los picos de los transitorios agudos hasta 2 dB, así que normalizar antes de
    codificar no basta: se codifica, se mide lo decodificado y se corrige (2 o 3 vueltas).
    Devuelve la señal decodificada final.
    """
    channels = 1 if x.ndim == 1 else x.shape[1]
    gain = 1.0
    best = None
    for _ in range(8):
        encode_ogg(x * gain, path)
        dec = decode_ogg(path, channels)
        err = PEAK_DB - 20 * np.log10(true_peak(dec))
        if best is None or abs(err) < abs(best[0]):
            best = (err, gain, dec)
        if abs(err) < 0.1:
            break
        gain *= 10 ** (0.8 * err / 20)  # amortiguado: el códec no es lineal con transitorios muy agudos
    if best[1] != gain or abs(err) >= 0.1:
        encode_ogg(x * best[1], path)  # deja en disco el mejor intento, no el último
    return best[2]


# ---------------------------------------------------------------------------
# Barridos de espada
# ---------------------------------------------------------------------------

def _swoosh(rng, dur, f_lo, f_hi, f_end, rise, fall, q, body_hz, body, air, whistle, turb, body_peak=(2.6, 2.0)):
    """Barrido: ruido rosa por un paso banda que sube hasta `f_hi` y baja a `f_end` (efecto Doppler).

    La envolvente es una campana (`rise`, `fall`); encima van un soplido grave (`body`), aire
    agudo (`air`), un silbido estrecho que sigue al barrido (`whistle`, el «shing» de la hoja) y
    turbulencia (modulación lenta de amplitud).
    """
    n = sec(dur)
    shape = bump(n, rise, fall)
    peak_i = int(np.argmax(shape))
    s = shape ** 0.7
    fc = np.where(np.arange(n) < peak_i, f_lo * (f_hi / f_lo) ** s, f_end * (f_hi / f_end) ** s)
    am = np.clip(1.0 + turb * smooth_noise(n, rng, 45), 0.4, 1.8)

    main = unit(bp2(noise(n, rng, -3.0), fc, q) * shape * am)
    airy = unit(hp(noise(n, rng), 3500, 2) * shape ** 2.4 * am)
    low = unit(lp(noise(n, rng, -3.0), body_hz, 2) * bump(n, *body_peak) * (0.8 + 0.2 * am))
    sing = unit(bp2(noise(n, rng), np.minimum(fc * 1.3, 9000), 30.0) * shape ** 1.6)
    return main + air * airy + body * low + whistle * sing


@sound("swing", "sword_swing_light", 3, mix_db=-4.0, dur=(0.22, 0.55))
def sword_swing_light(rng, v):
    p = [dict(dur=0.30, lo=560, hi=2900, end=1150, rise=1.5, fall=2.4, q=1.8, body_hz=230, body=0.18, air=0.22, whistle=0.07),
         dict(dur=0.34, lo=480, hi=2400, end=950, rise=1.8, fall=2.7, q=1.7, body_hz=200, body=0.25, air=0.18, whistle=0.10),
         dict(dur=0.27, lo=700, hi=3500, end=1400, rise=1.3, fall=2.2, q=2.0, body_hz=250, body=0.14, air=0.30, whistle=0.05)][v]
    y = _swoosh(rng, p["dur"], p["lo"], p["hi"], p["end"], p["rise"], p["fall"], p["q"],
                p["body_hz"], p["body"], p["air"], p["whistle"], turb=0.20)
    y = hp(y, 130, 2)
    y = np.concatenate([taper(y, 0.03), np.zeros(sec(0.06))])
    return reverb(y, rng, rt60=0.22, wet=0.05, damp=0.3)


@sound("swing", "sword_swing_heavy", 2, mix_db=-3.0, dur=(0.45, 0.95))
def sword_swing_heavy(rng, v):
    p = [dict(dur=0.62, lo=200, hi=1400, end=400, rise=2.0, fall=2.8, q=1.3, body_hz=170, body=0.55, air=0.10, whistle=0.04),
         dict(dur=0.72, lo=170, hi=1150, end=330, rise=2.3, fall=3.0, q=1.2, body_hz=140, body=0.65, air=0.08, whistle=0.03)][v]
    y = _swoosh(rng, p["dur"], p["lo"], p["hi"], p["end"], p["rise"], p["fall"], p["q"],
                p["body_hz"], p["body"], p["air"], p["whistle"], turb=0.30, body_peak=(3.4, 1.7))
    y = hp(y, 60, 2)
    y = np.concatenate([taper(y, 0.05), np.zeros(sec(0.12))])
    return reverb(y, rng, rt60=0.35, wet=0.09, damp=0.3)


# ---------------------------------------------------------------------------
# Golpe de espada en carne o cuero
# ---------------------------------------------------------------------------

@sound("hit_flesh", "hit_flesh", 3, mix_db=-1.0, dur=(0.2, 0.6))
def hit_flesh(rng, v):
    p = [  # 1: cuero (golpe seco con chasquido) · 2: carne (tajo húmedo) · 3: gambesón (cuerpo y tela)
        dict(f0=150, f1=95, thump=0.032, body_hz=520, body_tau=0.050, slap_hz=1700, slap_tau=0.014, mode=300, snap=0.50, cut=0.25, cloth=0.15, drive=2.2),
        dict(f0=125, f1=80, thump=0.045, body_hz=380, body_tau=0.070, slap_hz=1200, slap_tau=0.020, mode=240, snap=0.18, cut=0.80, cloth=0.05, drive=1.8),
        dict(f0=135, f1=88, thump=0.055, body_hz=420, body_tau=0.085, slap_hz=1000, slap_tau=0.026, mode=260, snap=0.20, cut=0.30, cloth=0.60, drive=1.8)][v]
    n = ms(420)
    thump = pk(sine_sweep(n, p["f0"], p["f1"], 0.02) * edecay(n, p["thump"], 0.0012))
    body = pk(bp2(noise(n, rng, -3.0), p["body_hz"], 0.9) * edecay(n, p["body_tau"], 0.0008))
    slap = pk(bp2(noise(n, rng, -3.0), p["slap_hz"], 0.9) * edecay(n, p["slap_tau"], 0.0004))
    snap = pk(hp(noise(n, rng), 3200, 2) * edecay(n, 0.005, 0.0001))
    modes = pk(modal(n, [p["mode"] * r for r in (1.0, 1.62, 2.51)], [0.09, 0.07, 0.045], [1.0, 0.7, 0.5], rng))
    y = 0.50 * thump + 1.0 * body + 0.85 * slap + p["snap"] * snap + 0.50 * modes

    nc = ms(130)
    tc = tvec(nc)
    fc = 900.0 + 3000.0 * np.exp(-tc / 0.035)
    cut = unit(bp2(noise(nc, rng), fc, 2.2)) * bump(nc, 1.0, 2.2)
    place(y, cut, 0.004, p["cut"] * 0.65)

    if p["cloth"] > 0.0:  # roce de tela o correa: ruido medio modulado por granos
        nr = ms(220)
        rustle = unit(bp2(noise(nr, rng, -3.0), 1400, 1.0)) * bump(nr, 1.3, 2.0)
        rustle *= np.clip(1.0 + 0.7 * smooth_noise(nr, rng, 90), 0.1, 2.0)
        place(y, rustle, 0.012, p["cloth"] * 0.30)

    y = sat(hp(y, 80, 1), p["drive"])
    y = lp(y, 10000, 1)
    y = np.concatenate([taper(y, 0.07), np.zeros(ms(40))])
    return reverb(y, rng, rt60=0.22, wet=0.07, damp=0.3)


# ---------------------------------------------------------------------------
# Golpe en escudo de madera
# ---------------------------------------------------------------------------

@sound("hit_shield", "hit_shield_wood", 3, mix_db=-1.0, dur=(0.2, 0.8))
def hit_shield_wood(rng, v):
    p = [  # 1: tabla plana · 2: golpe fuerte con crujido · 3: contra el embrazo de hierro (con ring)
        dict(f=270, t60=1.0, crack=0.35, rattle=0.25, boss=0.0, thump=0.8),
        dict(f=235, t60=1.3, crack=0.55, rattle=0.45, boss=0.0, thump=1.0),
        dict(f=305, t60=0.9, crack=0.45, rattle=0.2, boss=0.45, thump=0.6)][v]
    n = ms(500)
    ratios = np.array([1.0, 1.63, 2.38, 3.51, 4.92, 6.8])
    jitter = rng.uniform(0.985, 1.015, len(ratios))
    freqs = p["f"] * ratios * jitter
    t60s = np.array([0.13, 0.10, 0.08, 0.06, 0.04, 0.028]) * p["t60"]
    wood = pk(modal(n, freqs, t60s, [1.0, 0.8, 0.6, 0.42, 0.28, 0.16], rng))
    thump = pk(sine_sweep(n, 150, 90, 0.02) * edecay(n, 0.035, 0.0015))
    knock = pk(bp2(noise(n, rng), 2300, 1.0) * edecay(n, 0.005, 0.00008))
    crack = pk(hp(noise(n, rng), 3800, 2) * edecay(n, 0.0025, 0.00005))
    # Traqueteo: tablas sueltas que vibran, ruido de 1 kHz modulado por granos durante 100 ms.
    rat = pk(bp2(noise(n, rng), 1100, 2.0) * edecay(n, 0.04, 0.001)
             * np.clip(0.4 + smooth_noise(n, rng, 160), 0.0, 2.5))
    y = 0.85 * wood + p["thump"] * 0.25 * thump + 1.0 * knock + 1.2 * p["crack"] * crack + p["rattle"] * 0.6 * rat
    if p["boss"] > 0.0:
        bf = np.array([1480.0, 3340.0, 5230.0, 7900.0]) * rng.uniform(0.97, 1.03)
        boss = pk(modal(n, bf, [0.45, 0.25, 0.14, 0.08], [1.0, 0.6, 0.35, 0.2], rng))
        ring = pk(modal(n, bf * 1.004, [0.45, 0.25, 0.14, 0.08], [1.0, 0.6, 0.35, 0.2], rng))
        y = y + p["boss"] * 0.45 * (boss + 0.7 * ring)
    y = sat(y, 1.8)
    y = lp(y, 11000, 1)
    y = np.concatenate([taper(y, 0.07), np.zeros(ms(40))])
    return reverb(y, rng, rt60=0.3, wet=0.08, damp=0.3)


# ---------------------------------------------------------------------------
# Choque de metal contra metal (parada)
# ---------------------------------------------------------------------------

BAR_RATIOS = np.array([1.0, 2.756, 5.404, 8.933, 13.344, 18.64])  # barra libre: una hoja es una barra


def _blade_ring(n, f0, t60, rng, gain):
    """Hoja de acero golpeada: modos de barra libre, cada uno con un gemelo desafinado (los batidos)."""
    freqs = []
    amps = []
    t60s = []
    for k, r in enumerate(BAR_RATIOS):
        a = gain / (1.0 + 0.55 * k)
        t = t60 / (1.0 + 0.55 * k)
        freqs.append(f0 * r * rng.uniform(0.995, 1.005))
        amps.append(a)
        t60s.append(t)
        freqs.append(f0 * r * rng.uniform(1.0015, 1.006))
        amps.append(a * 0.7)
        t60s.append(t * 0.9)
    return modal(n, freqs, t60s, amps, rng)


def _metal_cloud(n, rng, count, f_lo, f_hi, t60_lo, t60_hi):
    """Nube de modos inarmónicos: al chocar dos piezas de acero suenan decenas de modos a la vez."""
    freqs = np.exp(rng.uniform(np.log(f_lo), np.log(f_hi), count))
    t60s = rng.uniform(t60_lo, t60_hi, count) / (1.0 + freqs / 5000.0)
    amps = rng.uniform(0.2, 1.0, count) / (1.0 + freqs / 3500.0)
    return modal(n, freqs, t60s, amps, rng)


@sound("parry", "clash_metal", 2, mix_db=-2.0, dur=(0.3, 1.6))
def clash_metal(rng, v):
    p = [dict(a=1260, b=1610, t60=0.70, cloud=(0.06, 0.28), scrape=0.0, noise=1.0, thud=0.30),    # parada seca y brillante
         dict(a=930, b=1175, t60=1.05, cloud=(0.08, 0.42), scrape=0.55, noise=1.0, thud=0.50)][v]  # choque pesado con arrastre
    n = sec(1.5)
    ring = pk(_blade_ring(n, p["a"], p["t60"], rng, 1.0) + 0.8 * _blade_ring(n, p["b"], p["t60"] * 0.9, rng, 1.0))
    cloud = pk(_metal_cloud(n, rng, 44, 900, 12000, *p["cloud"]))

    # Impacto: ráfaga de ruido agudo + ruido «metálico» (ruido por modulación en anillo con senos inarmónicos).
    burst = pk(hp(noise(n, rng), 1400, 2) * edecay(n, 0.007, 0.00005))
    tn = tvec(n)
    ringmod = np.sin(TWO_PI * 2870 * tn) + 0.7 * np.sin(TWO_PI * 4630 * tn + 1.0)
    metallic = pk(bp2(noise(n, rng), 3600, 0.8) * ringmod * edecay(n, 0.035, 0.0001))
    thud = pk(sine_sweep(n, 330, 170, 0.012) * edecay(n, 0.022, 0.0005))
    # Solo el impacto se satura: saturar los modos que suenan mucho tiempo crea tonos de diferencia graves.
    y = 0.55 * ring + 0.95 * cloud + sat(0.85 * p["noise"] * burst + 0.55 * metallic + p["thud"] * thud, 1.4)

    if p["scrape"] > 0.0:  # filo que se desliza sobre el otro: ruido que baja de 7,5 a 2,5 kHz
        ns = sec(0.22)
        ts = tvec(ns)
        fc = 2500.0 + 5000.0 * np.exp(-ts / 0.07)
        sc = unit(bp2(noise(ns, rng), fc, 3.5)) * bump(ns, 0.7, 1.8)
        place(y, sc, 0.01, p["scrape"] * 0.6)
    y = np.concatenate([taper(y, 0.2), np.zeros(sec(0.1))])
    return reverb(y, rng, rt60=0.45, wet=0.14, damp=0.45, predelay=0.003)


# ---------------------------------------------------------------------------
# Pasos
# ---------------------------------------------------------------------------

def _dirt_foot(rng, f_hi, f_lo, tau, lp_hz, crunch_n, crunch_hz, crunch_gain, mid_hz):
    m = ms(300)
    thump = pk(sine_sweep(m, f_hi * 1.25, f_lo * 1.25, 0.02) * edecay(m, tau, 0.003))
    low = pk(lp(noise(m, rng), lp_hz, 2) * edecay(m, tau * 0.9, 0.0025))
    mid = pk(bp2(noise(m, rng, -3.0), mid_hz, 0.9) * edecay(m, 0.045, 0.002))
    g = grains(m, rng, crunch_n, 0.040, 0.2, amp_tau=0.08)
    crunch = svf(g, crunch_hz, 2.5, "bp") + 0.8 * svf(g, crunch_hz * 0.45, 1.8, "bp")
    crunch = pk(crunch)
    return hp(0.30 * thump + 0.60 * low + 0.90 * mid + crunch_gain * crunch, 85, 2)


@sound("step_dirt", "step_dirt", 3, mix_db=-9.0, dur=(0.2, 0.6), grainy=True)
def step_dirt(rng, v):
    p = [dict(f=(105, 65), tau=0.040, lp=320, toe=0.105, toe_g=0.50, n=80, hz=3000, cg=0.9, scuff=0.35, mid=650),
         dict(f=(90, 55), tau=0.050, lp=280, toe=0.125, toe_g=0.55, n=110, hz=2500, cg=1.1, scuff=0.45, mid=550),
         dict(f=(118, 72), tau=0.035, lp=360, toe=0.090, toe_g=0.45, n=65, hz=3500, cg=0.75, scuff=0.28, mid=760)][v]
    n = ms(420)
    out = np.zeros(n)
    heel_t = 0.035
    heel = _dirt_foot(rng, p["f"][0], p["f"][1], p["tau"], p["lp"], p["n"], p["hz"], p["cg"], p["mid"])
    place(out, heel, heel_t, 1.0)
    toe = _dirt_foot(rng, p["f"][0] * 1.35, p["f"][1] * 1.3, p["tau"] * 0.6, p["lp"] * 1.5,
                     int(p["n"] * 0.5), p["hz"] * 1.15, p["cg"] * 0.8, p["mid"] * 1.4)
    place(out, toe, heel_t + p["toe"], p["toe_g"])
    # Arrastre del pie antes de pisar.
    ns = ms(120)
    scuff = unit(bp2(noise(ns, rng, -3.0), 1800, 0.9)) * bump(ns, 1.6, 1.2)
    place(out, scuff, 0.0, p["scuff"] * 0.30)
    out = lp(out, 7000, 2)
    return taper(out, 0.08)


def _stone_foot(rng, f, click, grit_n):
    m = ms(260)
    clk = pk(hp(noise(m, rng), 2500, 2) * edecay(m, 0.0018, 0.00005))
    tock = pk(modal(m, [f * r for r in (1.0, 1.58, 2.41, 3.9)], [0.05, 0.034, 0.022, 0.014], [1.0, 0.6, 0.4, 0.25], rng))
    thump = pk(sine_sweep(m, 160, 115, 0.01) * edecay(m, 0.02, 0.001))
    g = grains(m, rng, grit_n, 0.04, 0.18, amp_tau=0.06)
    grit = pk(svf(g, 5800, 3.0, "bp") + 0.5 * svf(g, 2600, 2.5, "bp"))
    return hp(click * clk + 0.85 * tock + 0.14 * thump + 0.25 * grit, 110, 2)


@sound("step_stone", "step_stone", 3, mix_db=-8.0, dur=(0.3, 1.0), grainy=True)
def step_stone(rng, v):
    p = [dict(f=720, click=0.7, toe=0.100, toe_g=0.50, grit=6),
         dict(f=610, click=0.85, toe=0.118, toe_g=0.55, grit=9),
         dict(f=860, click=0.6, toe=0.088, toe_g=0.42, grit=5)][v]
    n = ms(800)
    out = np.zeros(n)
    place(out, _stone_foot(rng, p["f"], p["click"], p["grit"]), 0.01, 1.0)
    place(out, _stone_foot(rng, p["f"] * 1.25, p["click"] * 0.7, p["grit"] // 2), 0.01 + p["toe"], p["toe_g"])
    out = sat(out, 1.5)
    out = taper(out, 0.08)
    return reverb(out, rng, rt60=0.55, wet=0.34, damp=0.35, predelay=0.004)


# ---------------------------------------------------------------------------
# Cuerpo que cae
# ---------------------------------------------------------------------------

@sound("body", "body_fall", 1, mix_db=-3.0, dur=(0.6, 1.8), grainy=True)
def body_fall(rng, v):
    n = sec(1.1)
    y = np.zeros(n)
    thump = pk(sine_sweep(n, 120, 62, 0.05) * edecay(n, 0.09, 0.004))
    lows = pk(lp(noise(n, rng), 230, 2) * edecay(n, 0.09, 0.003))
    slap = pk(bp2(noise(n, rng, -3.0), 520, 0.9) * edecay(n, 0.045, 0.002))
    y += 0.45 * thump + 0.9 * lows + 1.0 * slap

    # Deslizamiento de cuero y tela: ruido de 400 a 2000 Hz con grano, entre 20 y 450 ms.
    nr = ms(460)
    slide = unit(bp2(noise(nr, rng, -3.0), 800, 0.8)) * bump(nr, 0.9, 1.8)
    slide *= np.clip(1.0 + 0.6 * smooth_noise(nr, rng, 85), 0.1, 2.2)
    place(y, slide, 0.02, 0.38)

    # Tintineo del equipo: pinchazos metálicos al azar, cada vez más flojos.
    for _ in range(7):
        t0 = rng.uniform(0.03, 0.42)
        f0 = rng.uniform(900, 3300)
        ring = modal(ms(260), [f0, f0 * 2.41, f0 * 3.93], [rng.uniform(0.05, 0.18), 0.07, 0.04], [1.0, 0.45, 0.25], rng)
        ring *= np.exp(-t0 / 0.25) * rng.uniform(0.5, 1.0)
        place(y, pk(ring), t0, 0.17)

    # Asiento: los miembros caen un momento después.
    settle = pk(sine_sweep(ms(400), 90, 55, 0.04) * edecay(ms(400), 0.07, 0.004))
    settle += 0.6 * pk(lp(noise(ms(400), rng), 160, 2) * edecay(ms(400), 0.05, 0.003))
    settle += 0.5 * pk(bp2(noise(ms(400), rng, -3.0), 600, 0.9) * edecay(ms(400), 0.03, 0.003))
    place(y, settle, 0.27, 0.36)
    y = sat(hp(y, 55, 2), 1.4)
    y = lp(y, 8500, 1)
    y = np.concatenate([taper(y, 0.1), np.zeros(sec(0.2))])
    return reverb(y, rng, rt60=0.5, wet=0.15, damp=0.3, predelay=0.003)


# ---------------------------------------------------------------------------
# Poción
# ---------------------------------------------------------------------------

def _bubble(rng, f0, rise, tau, attack=0.004):
    n = sec(tau * 6)
    t = tvec(n)
    f = f0 * (1.0 + rise * t)
    ph = TWO_PI * np.cumsum(f) / SR
    return (np.sin(ph) + 0.25 * np.sin(2.0 * ph)) * np.exp(-t / tau) * (1.0 - np.exp(-t / attack))


@sound("potion", "potion_drink", 1, mix_db=-6.0, dur=(0.8, 2.2), grainy=True)
def potion_drink(rng, v):
    n = sec(1.7)
    y = np.zeros(n)
    # Corcho: pop hueco (resonancia de botella que baja) y un chasquido de ruido.
    pn = ms(260)
    pop = pk(sine_sweep(pn, 760, 380, 0.012) * edecay(pn, 0.032, 0.0003))
    pop += 0.7 * pk(bp2(noise(pn, rng), 1500, 2.5) * edecay(pn, 0.01, 0.0002))
    place(y, pop, 0.0, 0.85)
    # Tres tragos: burbuja grave que sube, soplido de garganta y chapoteo.
    for k, t0 in enumerate((0.34, 0.62, 0.90)):
        t0 += rng.uniform(-0.015, 0.015)
        f0 = rng.uniform(210, 290) * (1.0 - 0.07 * k)
        place(y, pk(_bubble(rng, f0, 7.0, 0.055, 0.006)), t0, 0.85)
        place(y, pk(_bubble(rng, f0 * 1.5, 6.0, 0.035, 0.005)), t0 + 0.012, 0.35)
        gn = ms(190)
        throat = unit(lp(noise(gn, rng, -3.0), 520, 2)) * bump(gn, 1.4, 1.8)
        place(y, throat, t0 - 0.05, 0.26)
        slosh = unit(lp(bp2(noise(gn, rng, -3.0), 850, 1.4), 2200, 1)) * bump(gn, 1.2, 2.0) \
            * np.clip(1.0 + 0.8 * smooth_noise(gn, rng, 70), 0.1, 2.2)
        place(y, slosh, t0 - 0.04, 0.16)
    # Burbujeo menudo del líquido.
    for _ in range(16):
        t0 = rng.uniform(0.16, 1.28)
        f0 = float(np.exp(rng.uniform(np.log(650), np.log(2600))))
        place(y, pk(_bubble(rng, f0, 8.0, rng.uniform(0.007, 0.02), 0.002)), t0, rng.uniform(0.04, 0.16))
    # Destello final: dos parciales de cristal con temblor, como un reflejo.
    sn = sec(0.55)
    ts = tvec(sn)
    shim = (np.sin(TWO_PI * 1760 * ts) + 0.6 * np.sin(TWO_PI * 2640 * ts + 0.7) + 0.3 * np.sin(TWO_PI * 3960 * ts))
    shim *= bump(sn, 1.6, 2.4) * (1.0 + 0.35 * np.sin(TWO_PI * 6.5 * ts))
    place(y, shim, 1.0, 0.075)
    y = lp(y, 12000, 1)
    y = np.concatenate([taper(y, 0.1), np.zeros(sec(0.2))])
    return reverb(y, rng, rt60=0.35, wet=0.10, damp=0.4)


# ---------------------------------------------------------------------------
# Interfaz
# ---------------------------------------------------------------------------

@sound("ui", "ui_click", 1, mix_db=-8.0, dur=(0.04, 0.3))
def ui_click(rng, v):
    n = ms(120)
    tick = pk(modal(n, [1650, 2980, 4400], [0.022, 0.014, 0.008], [1.0, 0.55, 0.25], rng))
    click = pk(bp2(noise(n, rng), 4200, 1.0) * edecay(n, 0.0018, 0.00006))
    body = pk(sine_sweep(n, 980, 640, 0.008) * edecay(n, 0.010, 0.0003))
    y = 1.0 * tick + 0.7 * click + 0.35 * body
    y = lp(y, 9500, 1)
    y = np.concatenate([taper(y, 0.04), np.zeros(ms(40))])
    return reverb(y, rng, rt60=0.18, wet=0.05)


def _chime(n, f, rng):
    """Campanilla pulsada: parciales casi armónicos que se apagan más deprisa cuanto más agudos."""
    ratios = [0.5, 1.0, 2.0, 3.0, 4.07, 5.4]
    t60s = [0.30, 0.60, 0.34, 0.22, 0.14, 0.10]
    amps = [0.18, 1.0, 0.5, 0.28, 0.16, 0.09]
    bell = pk(modal(n, [f * r for r in ratios], t60s, amps, rng))
    strike = pk(bp2(noise(n, rng), 3800, 1.0) * edecay(n, 0.002, 0.00005))
    return bell + 0.10 * strike


@sound("ui", "ui_confirm", 1, mix_db=-8.0, dur=(0.3, 1.4), stereo=True)
def ui_confirm(rng, v):
    n = sec(1.0)
    y = np.zeros(n)
    place(y, _chime(n, 587.3, rng), 0.0, 0.75)   # re
    place(y, _chime(n, 880.0, rng), 0.105, 1.0)  # la: una quinta que sube
    y = np.concatenate([taper(y, 0.15), np.zeros(sec(0.3))])
    return reverb_stereo(y, rng, rt60=0.7, wet=0.22, damp=0.4, predelay=0.006)


# ---------------------------------------------------------------------------
# Cuerno de captura del fuerte
# ---------------------------------------------------------------------------

def _formant(f):
    """Campana del cuerno: resonancias anchas hacia 500 Hz y 1,2 kHz, y caída por encima de 3 kHz."""
    return (0.5 + 1.0 / (1.0 + ((f - 520.0) / 380.0) ** 2) + 0.5 / (1.0 + ((f - 1250.0) / 500.0) ** 2)) \
        / (1.0 + (f / 2400.0) ** 2) ** 1.2


def _brass_note(rng, f0, dur, attack, release, scoop_cents, detune_cents):
    """Nota de metal: aditiva, con armónicos que se abren con la fuerza, arrastre de afinación y soplido."""
    n = sec(dur + release * 2.4)
    t = tvec(n)
    env = 1.0 - np.exp(-t / (attack / 2.5))
    env = env * np.where(t > dur, np.exp(-(t - dur) / (release / 3.2)), 1.0)
    env = env * (1.0 + 0.10 * np.sin(np.pi * np.clip(t / dur, 0, 1)))  # ligero hinchado a mitad de nota
    env = np.clip(env, 0.0, 1.0)
    f = f0 * 2.0 ** (detune_cents / 1200.0) * 2.0 ** (-(scoop_cents / 1200.0) * np.exp(-t / 0.05))
    f = f * (1.0 + 0.0035 * smooth_noise(n, rng, 6.0))
    ph = TWO_PI * np.cumsum(f) / SR
    sig = np.zeros(n)
    h = 1
    while h * f0 * 1.03 < 0.45 * SR and h <= 44:
        a = h ** -0.85 * _formant(h * f0)
        sig += a * env ** (0.55 + 0.32 * h) * np.sin(h * ph + rng.uniform(0, TWO_PI))
        h += 1
    sig *= np.clip(1.0 + 0.012 * smooth_noise(n, rng, 70.0), 0.9, 1.1)  # temblor de labios
    breath = unit(bp2(noise(n, rng), 1300, 0.9)) * (np.exp(-t / 0.10) * (1 - np.exp(-t / 0.01)) + 0.18 * env)
    return sig / np.max(np.abs(sig)) + 0.045 * breath


@sound("alert", "horn_fort_capture", 1, mix_db=-5.0, dur=(1.0, 3.0), stereo=True)
def horn_fort_capture(rng, v):
    n = sec(1.7)
    left = np.zeros(n)
    right = np.zeros(n)
    # Dos llamadas cortas sobre re y una larga sobre la: «tu-tu-TUUU».
    for t0, f0, dur, atk, rel, vol in ((0.0, 146.83, 0.17, 0.040, 0.10, 0.80),
                                       (0.27, 146.83, 0.17, 0.040, 0.10, 0.85),
                                       (0.53, 220.0, 0.56, 0.055, 0.24, 1.00)):
        a = _brass_note(rng, f0, dur, atk, rel, 70.0, -3.0)  # dos voces casi a la par: grosor, no coro
        b = _brass_note(rng, f0, dur, atk, rel, 60.0, +3.0)
        place(left, a, t0, 0.80 * vol)
        place(right, a, t0, 0.30 * vol)
        place(right, b, t0, 0.80 * vol)
        place(left, b, t0, 0.30 * vol)
    dry = sat(np.stack([left, right], axis=1), 1.5)  # el metal se vuelve más brillante al apretar
    dry = np.concatenate([dry, np.zeros((sec(0.8), 2))])
    return reverb_stereo(dry, rng, rt60=1.1, wet=0.30, damp=0.35, predelay=0.012)


# ---------------------------------------------------------------------------
# Programa principal
# ---------------------------------------------------------------------------

def sound_files():
    """(entrada de catálogo, índice de variación, nombre de archivo sin extensión) de cada sonido."""
    for s in SOUNDS:
        for v in range(s["count"]):
            yield s, v, "%s_%02d" % (s["name"], v + 1)


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
        x = encode_normalized(x, path)  # a partir de aquí, la señal decodificada
        active = np.max(np.abs(x), axis=1) if x.ndim == 2 else np.abs(x)
        active = active > active.max() * 10 ** (-30 / 20)
        levels["%s/%s" % (s["category"], fname)] = dict(
            duracion_s=round(len(x) / SR, 3),
            canales=1 if x.ndim == 1 else x.shape[1],
            pico_dbfs=round(20 * np.log10(np.max(np.abs(x))), 2),
            pico_real_dbfs=round(20 * np.log10(true_peak(x)), 2),
            rms_activo_dbfs=round(20 * np.log10(rms(x[active])), 2),
            volume_db=s["mix_db"])
        total += 1
        print("%-34s %5.2f s  %s  (%.1f s)" % (fname, len(x) / SR, "estéreo" if x.ndim == 2 else "mono   ", time.time() - t0))

    if not args.only:
        meta = dict(
            generador="tools/audio/synth_sfx.py",
            nota="volume_db es el recorte de volumen que debe aplicar el reproductor para igualar categorías; "
                 "todos los archivos tienen el mismo pico real (%.1f dBFS) medido sobre el OGG decodificado." % PEAK_DB,
            sonidos=levels)
        (out_root / "niveles.json").write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print("%d sonidos en %.1f s" % (total, time.time() - t_start))
    return 0


if __name__ == "__main__":
    sys.exit(main())
