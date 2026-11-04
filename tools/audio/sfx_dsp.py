"""Synthesis tools for Eldmark's sounds (ART-11): processing, measurements, encoding and registration.

Everything comes from synthesis and processing with numpy (no scipy) and is converted to OGG Vorbis with ffmpeg. This module
does not generate sounds: `sfx_combat.py` and `sfx_world.py` (the catalog) and `synth_sfx.py` (the program) use it.

    filtered noise     swings, hits, footsteps (time-varying state-variable filter)
    resonant modes     wood, metal and small bells (sum of decaying sines)
    additive synthesis the horn and the voices (harmonics that open up with effort, formants)
    grains             gravel, jingles, bubbles, rattles
    echoes and rooms   outdoor echo, early reflections and reverb by FFT convolution (interface only)

Finishing: each sound is normalized by the loudness of its active part (K weighting) with a true
peak ceiling of -1.5 dBTP, measured on the already-decoded OGG (Vorbis overshoots high-frequency peaks, so it is
encoded, measured and corrected). The level measurement that goes into niveles.json and the one the checker uses
are the same (`measure_levels`).
"""

import subprocess
from pathlib import Path

import numpy as np

SR = 44100
PEAK_DB = -1.5       # true peak ceiling (dBTP, oversampled) of each already-encoded OGG
LOUD_DB = -18.5      # target loudness of the active part (K weighting, dB): all files are matched to this
ROOT = Path(__file__).resolve().parents[2]
OUT_ROOT = ROOT / "assets" / "audio" / "sfx"
TWO_PI = 2.0 * np.pi


# ---------------------------------------------------------------------------
# Basic utilities
# ---------------------------------------------------------------------------

def ms(milliseconds):
    """Milliseconds to samples."""
    return int(round(milliseconds * SR / 1000.0))


def sec(seconds):
    return int(round(seconds * SR))


def tvec(n):
    return np.arange(n) / SR


def rms(x):
    return float(np.sqrt(np.mean(np.square(x)))) + 1e-12


def unit(x):
    """Scales to RMS 1 (for continuous layers, like the swings)."""
    return x / rms(x)


def pk(x):
    """Scales to peak 1 (for transient layers)."""
    return x / (np.max(np.abs(x)) + 1e-12)


def place(dst, src, start_s, gain=1.0):
    """Adds `src` into `dst` starting at `start_s` seconds (trims whatever does not fit)."""
    i = sec(start_s)
    if i >= len(dst) or i + len(src) <= 0:
        return
    a = max(i, 0)
    b = min(len(dst), i + len(src))
    dst[a:b] += gain * src[a - i:b - i]


def sat(x, drive=1.5):
    """Soft saturation (tanh) preserving the peak: gives body to the hits."""
    p = np.max(np.abs(x)) + 1e-12
    return np.tanh(drive * x / p) / np.tanh(drive) * p


def noise(n, rng, slope_db=0.0):
    """White noise (slope 0) or colored with `slope_db` dB per octave (-3 = pink, -6 = brown)."""
    w = rng.standard_normal(n)
    if slope_db == 0.0:
        return w
    spec = np.fft.rfft(w)
    f = np.fft.rfftfreq(n, 1.0 / SR)
    f[0] = f[1]
    spec *= (f / 1000.0) ** (slope_db / 6.0206)
    return unit(np.fft.irfft(spec, n))


def smooth_noise(n, rng, rate_hz):
    """Slow noise (mean 0, deviation 1) for modulations: interpolates random points."""
    m = max(4, int(n / SR * rate_hz * 3) + 4)
    pts = rng.standard_normal(m)
    x = np.interp(np.linspace(0, m - 1, n), np.arange(m), pts)
    return x / (np.std(x) + 1e-12)


# ---------------------------------------------------------------------------
# Filters
# ---------------------------------------------------------------------------

def svf(x, fc, q=0.7071, mode="lp"):
    """State-variable filter (TPT, Zavalishin). `fc` and `q` can be per-sample arrays.

    Modes: lp (low-pass), bp (band-pass with gain 1 at the center), hp (high-pass), notch.
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
    """Two-stage band-pass: 12 dB per octave slopes (a single stage lets too much treble through)."""
    return svf(svf(x, fc, q, "bp"), fc, q, "bp")


def taper(x, seconds=0.06):
    """Cosine fade at the end of a buffer whose layers have not fallen silent (avoids the step)."""
    k = min(len(x) // 2, sec(seconds))
    out = np.array(x, dtype=np.float64)
    out[-k:] *= np.cos(np.linspace(0.0, np.pi / 2, k)) ** 2
    return out


def dc_block(x):
    """Removes DC offset and subsonics (via FFT, zero phase)."""
    n = len(x)
    pad = sec(0.3)  # zero padding: keeps the filter from wrapping the start around to the end
    nfft = n + 2 * pad
    spec = np.fft.rfft(np.concatenate([np.zeros(pad), x, np.zeros(pad)]))
    f = np.fft.rfftfreq(nfft, 1.0 / SR)
    spec *= 1.0 / (1.0 + (22.0 / np.maximum(f, 1e-3)) ** 4)
    return np.fft.irfft(spec, nfft)[pad:pad + n]


# ---------------------------------------------------------------------------
# Envelopes and oscillators
# ---------------------------------------------------------------------------

def edecay(n, tau, attack=0.0005):
    """Exponential decay (time constant `tau` in s) with a soft attack."""
    t = tvec(n)
    e = np.exp(-t / tau)
    if attack > 0:
        e *= 1.0 - np.exp(-t / attack)
    return e


def bump(n, a, b):
    """Bell curve u^a (1-u)^b normalized to 1; the peak falls at a / (a + b) of the duration."""
    u = (np.arange(n) + 0.5) / n
    y = u ** a * (1.0 - u) ** b
    return y / y.max()


def sine_sweep(n, f_start, f_end, tau_f):
    """Sine whose frequency falls (or rises) exponentially from `f_start` to `f_end`."""
    t = tvec(n)
    f = f_end + (f_start - f_end) * np.exp(-t / tau_f)
    return np.sin(TWO_PI * np.cumsum(f) / SR)


def modal(n, freqs, t60s, amps, rng=None, attack=0.0002):
    """Sum of decaying sines (modal synthesis). `t60s` in s down to -60 dB."""
    t = tvec(n)
    out = np.zeros(n)
    for f, t60, a in zip(freqs, t60s, amps):
        if f >= 0.46 * SR:
            continue
        phase = rng.uniform(0, TWO_PI) if rng is not None else 0.0
        out += a * np.exp(-6.9078 * t / t60) * np.sin(TWO_PI * f * t + phase)
    return out * (1.0 - np.exp(-t / attack))


def grains(n, rng, count, scale_s, max_s, amp_tau=None):
    """Impulse train with random sign and amplitude, denser at the start (exponential)."""
    x = np.zeros(n)
    times = np.minimum(rng.exponential(scale_s, count), max_s)
    idx = np.minimum((times * SR).astype(int), n - 1)
    amps = rng.uniform(0.25, 1.0, count) * rng.choice([-1.0, 1.0], count)
    if amp_tau is not None:
        amps = amps * np.exp(-times / amp_tau)
    np.add.at(x, idx, amps)
    return x


# ---------------------------------------------------------------------------
# Reverb
# ---------------------------------------------------------------------------

def make_ir(rng, rt60, damp=0.4, predelay=0.0, early=1.0):
    """Impulse response: noise that decays faster the higher it is (`damp` = high RT60 / low RT60)."""
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
    pad = sec(0.15)  # zero padding: the zero-phase filter cannot wrap the start around to the end
    padded = np.concatenate([np.zeros(pad), diffuse, np.zeros(pad)])
    fp = np.fft.rfftfreq(len(padded), 1.0 / SR)
    padded = np.fft.irfft(np.fft.rfft(padded) / (1.0 + (130.0 / np.maximum(fp, 1.0)) ** 4), len(padded))
    diffuse = padded[pad:pad + n]  # no low-frequency mud
    diffuse *= 1.0 - np.exp(-t / 0.006)  # soft fade-in of the tail
    ir = np.zeros(pd + n)
    ir[pd:] = diffuse * 0.5
    if early > 0:
        for tap_s in np.sort(rng.uniform(0.004, 0.035, 7)):
            amp = early * rng.uniform(0.4, 1.0) * np.exp(-tap_s / 0.03) * rng.choice([-1.0, 1.0])
            j = pd + sec(tap_s)
            ir[j:j + 3] += amp * np.array([0.5, 1.0, 0.5]) * 0.6
    return ir / np.sqrt(np.sum(ir * ir))


def reverb(x, rng, rt60=0.4, wet=0.15, damp=0.4, predelay=0.0, early=1.0):
    """Adds `wet` times the reverberated signal (unit-energy IR: wet 0.3 = -10 dB). Same length."""
    n = len(x)
    ir = make_ir(rng, rt60, damp, predelay, early)
    nfft = 1 << (n + len(ir)).bit_length()
    y = np.fft.irfft(np.fft.rfft(x, nfft) * np.fft.rfft(ir, nfft), nfft)[:n]
    return x + wet * y


def reverb_stereo(x, rng, **kw):
    """Two reverbs with different responses (decorrelated) over a mono or stereo signal."""
    left = x if x.ndim == 1 else x[:, 0]
    right = x if x.ndim == 1 else x[:, 1]
    return np.stack([reverb(left, rng, **kw), reverb(right, rng, **kw)], axis=1)


# ---------------------------------------------------------------------------
# Outdoor echo and envelopes
# ---------------------------------------------------------------------------

def outdoor_echo(x, taps, damp_hz=3200.0, tail=0.12):
    """Open-field echo: delayed copies of the signal, each darker and quieter (bouncing off a
    hillside or a wall), instead of a room's reverb.

    `taps` is a list of (delay in s, gain, pan from -1 to 1). The direct signal stays centered.
    Returns stereo with `tail` extra s so the last bounce fits.
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
    """Asymmetric fixed-peak envelope at `t_pk` s: rises with constant `tau_r` and falls with `tau_f`.

    exp(-(|t - t_pk| / tau)^p): with p > 1 the top is rounded and the stretch within 6 dB of the peak lasts
    about 0.8 · (tau_r + tau_f).
    """
    dt = tvec(n) - t_pk
    tau = np.where(dt < 0, tau_r, tau_f)
    return np.exp(-(np.abs(dt) / tau) ** p)


def smoothstep(x):
    x = np.clip(x, 0.0, 1.0)
    return x * x * (3.0 - 2.0 * x)


# ---------------------------------------------------------------------------
# Measurements (used by the generator and the checker: a single definition)
# ---------------------------------------------------------------------------

def env10(x):
    """RMS envelope in a 10 ms window. If stereo, mean power of the channels."""
    pw = x * x if x.ndim == 1 else np.mean(x * x, axis=1)
    w = max(1, int(round(SR * 0.010)))
    return np.sqrt(np.convolve(pw, np.ones(w) / w, mode="same") + 1e-18)


def active_mask(x, floor_db=-30.0):
    """Samples of the active part: the 10 ms envelope within 30 dB of its maximum."""
    e = env10(x)
    return e > e.max() * 10 ** (floor_db / 20)


def span_db(x, drop_db=6.0):
    """Span (s) between the first and the last time the 10 ms envelope is within `drop_db` of the peak."""
    e = env10(x)
    above = np.nonzero(e > e.max() * 10 ** (-drop_db / 20))[0]
    return float((above[-1] - above[0]) / SR)


def band_fraction(x, lo, hi, t0=0.0, t1=None):
    """Fraction of the energy (unwindowed FFT, mono or mean of channels) between `lo` and `hi` Hz, from `t0` to `t1` s."""
    mono = x if x.ndim == 1 else x.mean(axis=1)
    seg = mono[sec(t0):None if t1 is None else sec(t1)]
    if len(seg) < 32:
        return 0.0
    spec = np.abs(np.fft.rfft(seg)) ** 2
    f = np.fft.rfftfreq(len(seg), 1.0 / SR)
    keep = f >= 20.0  # DC offset and subsonics do not count
    total = spec[keep].sum() + 1e-18
    return float(spec[(f >= lo) & (f < hi)].sum() / total)


def fit_band(layers, gains, key, lo, hi, target):
    """Mixes the layers `layers` (dict name -> signal) with `gains` and adjusts the gain of `key` until the
    fraction of the mix's energy between `lo` and `hi` Hz is `target`. Returns (mix, gains).

    It is the way to guarantee the energy distribution the quality bar asks for without depending on the luck of the noise.
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
    """Magnitude of the ITU-R BS.1770 K weighting (high shelf and high-pass) at the frequencies `f`."""
    z = np.exp(-1j * TWO_PI * f / SR)
    # High shelf.
    f0, gdb, q = 1681.974450955533, 3.999843853973347, 0.7071752369554196
    k = np.tan(np.pi * f0 / SR)
    vh = 10 ** (gdb / 20)
    vb = vh ** 0.499666774155
    a0 = 1 + k / q + k * k
    b = ((vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0)
    a = (1.0, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0)
    h1 = (b[0] + b[1] * z + b[2] * z * z) / (a[0] + a[1] * z + a[2] * z * z)
    # RLB high-pass.
    f0, q = 38.13547087602444, 0.5003270373238773
    k = np.tan(np.pi * f0 / SR)
    a0 = 1 + k / q + k * k
    a = (1.0, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0)
    h2 = (1 - 2 * z + z * z) / (a[0] + a[1] * z + a[2] * z * z)
    return np.abs(h1 * h2)


def k_weighted(x):
    """Signal with K weighting applied (magnitude, zero phase, via FFT with zero padding)."""
    cols = [x] if x.ndim == 1 else [x[:, c] for c in range(x.shape[1])]
    out = []
    for c in cols:
        pad = sec(0.2)
        nfft = 1 << (len(c) + 2 * pad).bit_length()
        spec = np.fft.rfft(c, nfft) * _k_response(np.fft.rfftfreq(nfft, 1.0 / SR))
        out.append(np.fft.irfft(spec, nfft)[:len(c)])
    return out[0] if x.ndim == 1 else np.stack(out, axis=1)


def true_peak(x):
    """True peak (between samples): oversamples x4 via FFT. Returns linear amplitude."""
    peak = 0.0
    for c in (x.T if x.ndim == 2 else [x]):
        up = np.fft.irfft(np.fft.rfft(c), len(c) * 4) * 4.0
        peak = max(peak, float(np.max(np.abs(up))))
    return peak


def to_db(v):
    return 20.0 * np.log10(max(float(v), 1e-9))


def measure_levels(x):
    """Levels of an already-decoded sound. It is the measurement used by niveles.json and by the checker."""
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
# Catalog and finishing
# ---------------------------------------------------------------------------

SOUNDS = []


def sound(category, name, count, mix_db, dur, stereo=False, grainy=False, peak_s=None, pitch=1.05, vol_db=2.0,
          dry=True):
    """Registers a builder `fn(rng, v) -> array` that is called for v = 0..count-1.

    `mix_db`: suggested volume trim (goes into niveles.json). `dur`: (min, max) in s that the
    checker accepts. `grainy`: made of loose impulses on purpose (gravel, bubbles, jingles, several
    impacts), so the checker does not look for clicks in it. `peak_s`: (instant, tolerance) in s where the
    peak of the 10 ms envelope falls (the swings, to line up with the hit's active window).
    `pitch` and `vol_db`: recommended randomizer (AudioStreamRandomizer: random_pitch and
    random_volume_offset_db). `dry`: no baked-in reverb (everything that goes in 3D; only the interface
    keeps a room). The file is named <name>_NN.ogg.
    """
    def deco(fn):
        SOUNDS.append(dict(category=category, name=name, count=count, mix_db=mix_db, dur=dur, stereo=stereo,
                           grainy=grainy, peak_s=peak_s, pitch=pitch, vol_db=vol_db, dry=dry, fn=fn))
        return fn
    return deco


def sound_files():
    """(catalog entry, variation index, file name without extension) of each sound."""
    for s in SOUNDS:
        for v in range(s["count"]):
            yield s, v, "%s_%02d" % (s["name"], v + 1)


def finalize(x):
    """Removes DC offset, trims the trailing silence, applies fades and leaves the peak at PEAK_DB (the final
    loudness is set by `encode_normalized`)."""
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
    # Fade-in (0.5 ms) and fade-out (15 ms or 25 % if very short): no clicks.
    fin = ms(0.5)
    fout = min(ms(15), len(x) // 4)
    w = np.ones(len(x))
    w[:fin] = np.sin(np.linspace(0, np.pi / 2, fin)) ** 2
    w[-fout:] = np.cos(np.linspace(0, np.pi / 2, fout)) ** 2
    x = x * (w[:, None] if x.ndim == 2 else w)
    peak = float(np.max(np.abs(x)))
    return x * (10 ** (PEAK_DB / 20) / peak)


def encode_ogg(x, path):
    """Encodes with libvorbis (quality 6) through ffmpeg; `+bitexact` makes the file reproducible."""
    channels = 1 if x.ndim == 1 else x.shape[1]
    cmd = ["ffmpeg", "-v", "error", "-y", "-f", "f32le", "-ar", str(SR), "-ac", str(channels), "-i", "pipe:0",
           "-map_metadata", "-1", "-c:a", "libvorbis", "-q:a", "6",
           "-fflags", "+bitexact", "-flags:a", "+bitexact", str(path)]  # output options: fixed Ogg serial
    data = np.ascontiguousarray(x, dtype="<f4").tobytes()
    res = subprocess.run(cmd, input=data, capture_output=True)
    if res.returncode != 0:
        raise RuntimeError("ffmpeg falló con %s: %s" % (path, res.stderr.decode(errors="replace")))


def decode_ogg(path, channels):
    """Reads the OGG exactly as the game will play it (float64, [n] or [n, channels])."""
    res = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-f", "f32le", "-acodec", "pcm_f32le", "-"],
                         capture_output=True, check=True)
    x = np.frombuffer(res.stdout, dtype="<f4").astype(np.float64)
    return x.reshape(-1, channels) if channels > 1 else x


def encode_normalized(x, path, loud_db=LOUD_DB):
    """Encodes and adjusts the gain until the loudness of the decoded OGG's active part is
    `loud_db` without exceeding PEAK_DB of true peak.

    Matching by loudness and not by peak keeps a sustained horn from sounding twice as loud as a dry
    hit with the same peak. If a sound has a very high peak relative to its body, the ceiling wins
    (it ends up below `loud_db`; the checker notes it). Vorbis overshoots the peaks of high-frequency
    transients by up to 2 dB, so it is encoded, the decoded result is measured and corrected (2 or 3 rounds).
    Returns (final decoded signal, limited by the ceiling).
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
        gain *= 10 ** (0.8 * adj / 20)  # damped: the codec is not linear with very sharp transients
    if best[1] != gain or abs(adj) >= 0.1:
        encode_ogg(x * best[1], path)  # leaves the best attempt on disk, not the last one
    return best[2], best[3]
