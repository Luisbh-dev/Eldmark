"""Herramientas de síntesis de los sonidos de Eldmark (ART-11): procesado, medidas, codificación y registro.

Todo sale de síntesis y procesado con numpy (sin scipy) y se pasa a OGG Vorbis con ffmpeg. Este módulo
no genera sonidos: lo usan `sfx_combat.py` y `sfx_world.py` (el catálogo) y `synth_sfx.py` (el programa).

    ruido filtrado   barridos, golpes, pasos (filtro de estado variable en el tiempo)
    modos resonantes madera, metal y campanillas (suma de senos que se apagan)
    sintesis aditiva el cuerno y las voces (armónicos que se abren con la fuerza, formantes)
    granos           gravilla, tintineos, burbujas, traqueteos
    ecos y salas     eco exterior, primeras reflexiones y reverberación por convolución FFT (solo interfaz)

Acabado: cada sonido se normaliza por sonoridad de su parte activa (ponderación K) con un techo de
pico real de -1,5 dBTP, medido sobre el OGG ya decodificado (Vorbis rebasa los picos agudos, así que se
codifica, se mide y se corrige). La medida de niveles que va a niveles.json y la que usa el comprobador
son la misma (`measure_levels`).
"""

import subprocess
from pathlib import Path

import numpy as np

SR = 44100
PEAK_DB = -1.5       # techo de pico real (dBTP, sobremuestreado) de cada OGG ya codificado
LOUD_DB = -18.5      # sonoridad objetivo de la parte activa (ponderación K, dB): todos los archivos igualan a esto
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
# Eco exterior y envolventes
# ---------------------------------------------------------------------------

def outdoor_echo(x, taps, damp_hz=3200.0, tail=0.12):
    """Eco de campo abierto: copias retrasadas de la señal, cada una más oscura y más baja (rebote en una
    ladera o una muralla), en lugar de la reverberación de una sala.

    `taps` es una lista de (retardo en s, ganancia, panorama de -1 a 1). La señal directa queda centrada.
    Devuelve estéreo con `tail` s de más para que quepa el último rebote.
    """
    mono = x if x.ndim == 1 else x.mean(axis=1)
    last = max(t for t, _, _ in taps)
    n = len(mono) + sec(last + tail)
    out = np.zeros((n, 2))
    out[:len(mono), 0] += mono
    out[:len(mono), 1] += mono
    for k, (delay, gain, pan) in enumerate(taps):
        dark = lp(np.concatenate([mono, np.zeros(sec(0.05))]), damp_hz / (1.0 + 0.55 * k), 2)
        ang = (pan + 1.0) * np.pi / 4.0
        i = sec(delay)
        j = min(n, i + len(dark))
        out[i:j, 0] += gain * np.cos(ang) * dark[:j - i] * 1.4142
        out[i:j, 1] += gain * np.sin(ang) * dark[:j - i] * 1.4142
    return out


def peak_env(n, t_pk, tau_r, tau_f, p=1.6):
    """Envolvente asimétrica de pico fijo en `t_pk` s: sube con constante `tau_r` y baja con `tau_f`.

    exp(-(|t - t_pk| / tau)^p): con p > 1 la cima es redondeada y el tramo a menos de 6 dB del pico dura
    unas 0,8 · (tau_r + tau_f).
    """
    dt = tvec(n) - t_pk
    tau = np.where(dt < 0, tau_r, tau_f)
    return np.exp(-(np.abs(dt) / tau) ** p)


def smoothstep(x):
    x = np.clip(x, 0.0, 1.0)
    return x * x * (3.0 - 2.0 * x)


# ---------------------------------------------------------------------------
# Medidas (las usan el generador y el comprobador: una sola definición)
# ---------------------------------------------------------------------------

def env10(x):
    """Envolvente RMS en ventana de 10 ms. Si es estéreo, potencia media de los canales."""
    pw = x * x if x.ndim == 1 else np.mean(x * x, axis=1)
    w = max(1, int(round(SR * 0.010)))
    return np.sqrt(np.convolve(pw, np.ones(w) / w, mode="same") + 1e-18)


def active_mask(x, floor_db=-30.0):
    """Muestras de la parte activa: la envolvente de 10 ms a menos de 30 dB de su máximo."""
    e = env10(x)
    return e > e.max() * 10 ** (floor_db / 20)


def span_db(x, drop_db=6.0):
    """Tramo (s) entre la primera y la última vez que la envolvente de 10 ms está a menos de `drop_db` del pico."""
    e = env10(x)
    above = np.nonzero(e > e.max() * 10 ** (-drop_db / 20))[0]
    return float((above[-1] - above[0]) / SR)


def band_fraction(x, lo, hi, t0=0.0, t1=None):
    """Fracción de la energía (FFT sin ventana, mono o media de canales) entre `lo` y `hi` Hz, de `t0` a `t1` s."""
    mono = x if x.ndim == 1 else x.mean(axis=1)
    seg = mono[sec(t0):None if t1 is None else sec(t1)]
    if len(seg) < 32:
        return 0.0
    spec = np.abs(np.fft.rfft(seg)) ** 2
    f = np.fft.rfftfreq(len(seg), 1.0 / SR)
    keep = f >= 20.0  # la continua y los subsónicos no cuentan
    total = spec[keep].sum() + 1e-18
    return float(spec[(f >= lo) & (f < hi)].sum() / total)


def fit_band(layers, gains, key, lo, hi, target):
    """Mezcla las capas `layers` (dict nombre -> señal) con `gains` y ajusta la ganancia de `key` hasta que la
    fracción de energía de la mezcla entre `lo` y `hi` Hz sea `target`. Devuelve (mezcla, ganancias).

    Es la forma de garantizar el reparto de energía que pide el listón sin depender de la suerte del ruido.
    """
    g = dict(gains)
    y = None
    for _ in range(14):
        y = sum(g[k] * layers[k] for k in layers)
        f = band_fraction(y, lo, hi)
        if abs(f - target) <= 0.015 * target + 0.002:
            break
        g[key] = float(np.clip(g[key] * (target / max(f, 1e-4)) ** 0.5, 1e-3, 60.0))
    return y, g


def _k_response(f):
    """Módulo de la ponderación K de ITU-R BS.1770 (estante de agudos y paso alto) en las frecuencias `f`."""
    z = np.exp(-1j * TWO_PI * f / SR)
    # Estante de agudos.
    f0, gdb, q = 1681.974450955533, 3.999843853973347, 0.7071752369554196
    k = np.tan(np.pi * f0 / SR)
    vh = 10 ** (gdb / 20)
    vb = vh ** 0.499666774155
    a0 = 1 + k / q + k * k
    b = ((vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0)
    a = (1.0, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0)
    h1 = (b[0] + b[1] * z + b[2] * z * z) / (a[0] + a[1] * z + a[2] * z * z)
    # Paso alto RLB.
    f0, q = 38.13547087602444, 0.5003270373238773
    k = np.tan(np.pi * f0 / SR)
    a0 = 1 + k / q + k * k
    a = (1.0, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0)
    h2 = (1 - 2 * z + z * z) / (a[0] + a[1] * z + a[2] * z * z)
    return np.abs(h1 * h2)


def k_weighted(x):
    """Señal con la ponderación K aplicada (módulo, fase cero, por FFT con relleno de ceros)."""
    cols = [x] if x.ndim == 1 else [x[:, c] for c in range(x.shape[1])]
    out = []
    for c in cols:
        pad = sec(0.2)
        nfft = 1 << (len(c) + 2 * pad).bit_length()
        spec = np.fft.rfft(c, nfft) * _k_response(np.fft.rfftfreq(nfft, 1.0 / SR))
        out.append(np.fft.irfft(spec, nfft)[:len(c)])
    return out[0] if x.ndim == 1 else np.stack(out, axis=1)


def true_peak(x):
    """Pico real (entre muestras): sobremuestrea x4 por FFT. Devuelve amplitud lineal."""
    peak = 0.0
    for c in (x.T if x.ndim == 2 else [x]):
        up = np.fft.irfft(np.fft.rfft(c), len(c) * 4) * 4.0
        peak = max(peak, float(np.max(np.abs(up))))
    return peak


def to_db(v):
    return 20.0 * np.log10(max(float(v), 1e-9))


def measure_levels(x):
    """Niveles de un sonido ya decodificado. Es la medida de niveles.json y la del comprobador."""
    mask = active_mask(x)
    pw = x * x if x.ndim == 1 else np.mean(x * x, axis=1)
    kw = k_weighted(x)
    kpw = kw * kw if kw.ndim == 1 else np.mean(kw * kw, axis=1)
    return dict(
        dur=len(x) / SR,
        channels=1 if x.ndim == 1 else x.shape[1],
        peak_db=to_db(np.max(np.abs(x))),
        true_peak_db=to_db(true_peak(x)),
        rms_db=10 * np.log10(float(np.mean(pw[mask])) + 1e-18),
        loud_db=10 * np.log10(float(np.mean(kpw[mask])) + 1e-18),
        peak_t=float(np.argmax(env10(x))) / SR)


# ---------------------------------------------------------------------------
# Catálogo y acabado
# ---------------------------------------------------------------------------

SOUNDS = []


def sound(category, name, count, mix_db, dur, stereo=False, grainy=False, peak_s=None, pitch=1.05, vol_db=2.0,
          dry=True):
    """Registra un constructor `fn(rng, v) -> array` que se llama para v = 0..count-1.

    `mix_db`: recorte de volumen sugerido (va a niveles.json). `dur`: (mín, máx) en s que admite el
    comprobador. `grainy`: hecho de impulsos sueltos a propósito (gravilla, burbujas, tintineos, varios
    impactos), así que el comprobador no busca clics en él. `peak_s`: (instante, tolerancia) en s donde cae
    el pico de la envolvente de 10 ms (los barridos, para cuadrar con la ventana activa del golpe).
    `pitch` y `vol_db`: aleatorizador recomendado (AudioStreamRandomizer: random_pitch y
    random_volume_offset_db). `dry`: sin reverberación horneada (todo lo que va en 3D; solo la interfaz
    conserva una sala). El archivo se llama <name>_NN.ogg.
    """
    def deco(fn):
        SOUNDS.append(dict(category=category, name=name, count=count, mix_db=mix_db, dur=dur, stereo=stereo,
                           grainy=grainy, peak_s=peak_s, pitch=pitch, vol_db=vol_db, dry=dry, fn=fn))
        return fn
    return deco


def sound_files():
    """(entrada de catálogo, índice de variación, nombre de archivo sin extensión) de cada sonido."""
    for s in SOUNDS:
        for v in range(s["count"]):
            yield s, v, "%s_%02d" % (s["name"], v + 1)


def finalize(x):
    """Quita continua, recorta el silencio final, aplica fundidos y deja el pico en PEAK_DB (la sonoridad
    final la fija `encode_normalized`)."""
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


def encode_normalized(x, path, loud_db=LOUD_DB):
    """Codifica y ajusta la ganancia hasta que la sonoridad de la parte activa del OGG decodificado sea
    `loud_db` sin pasar de PEAK_DB de pico real.

    Igualar por sonoridad y no por pico evita que un cuerno sostenido suene el doble de fuerte que un golpe
    seco que tiene el mismo pico. Si un sonido tiene un pico muy alto frente a su cuerpo, manda el techo
    (queda por debajo de `loud_db`; el comprobador lo anota). Vorbis rebasa los picos de los transitorios
    agudos hasta 2 dB, así que se codifica, se mide lo decodificado y se corrige (2 o 3 vueltas).
    Devuelve (señal decodificada final, limitado por el techo).
    """
    channels = 1 if x.ndim == 1 else x.shape[1]
    m = measure_levels(x)
    gain = 10 ** (min(loud_db - m["loud_db"], PEAK_DB - m["true_peak_db"]) / 20)
    best = None
    adj = 0.0
    for _ in range(8):
        encode_ogg(x * gain, path)
        dec = decode_ogg(path, channels)
        m = measure_levels(dec)
        want_loud = loud_db - m["loud_db"]
        want_peak = PEAK_DB - m["true_peak_db"]
        adj = min(want_loud, want_peak)
        if best is None or abs(adj) < abs(best[0]):
            best = (adj, gain, dec, want_peak < want_loud)
        if abs(adj) < 0.1:
            break
        gain *= 10 ** (0.8 * adj / 20)  # amortiguado: el códec no es lineal con transitorios muy agudos
    if best[1] != gain or abs(adj) >= 0.1:
        encode_ogg(x * best[1], path)  # deja en disco el mejor intento, no el último
    return best[2], best[3]
