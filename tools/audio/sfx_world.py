"""Catalog of Eldmark's world sounds (ART-11): footsteps, potion, interface, horns and voices.

Footsteps, potion and voices are dry (reverb is added by the engine per zone). The horn carries
the echo of an outdoor bounce instead of a room; the interface keeps its short reverb.

    step_dirt/    footsteps on dirt: 8 variations, the heel lands in the first 5 ms
    step_stone/   footsteps on stone: a click and 2 to 6 kHz scrape plus a dull 80 to 150 Hz thud (8)
    potion/       drinking a potion: 40 ms cork, three gulps and a flash at the end
    ui/           click and confirmation (plucked string, wood and small bell; keeps the D-A motif)
    alert/        horns for a fort won and lost, with one timbre per realm (6)
    hollow/       voices of the Hollow: wounds (4) and death (2)

See `synth_sfx.py` for usage and `sfx_dsp.py` for the tools.
"""

import numpy as np

from sfx_dsp import (SR, bp2, bump, edecay, grains, hp, lp, modal, ms, noise, outdoor_echo, pk, place, reverb,
                     reverb_stereo, sat, sec, sine_sweep, smooth_noise, smoothstep, sound, svf, taper, tvec, unit)


def _jit(rng, value, spread):
    return value * rng.uniform(1.0 - spread, 1.0 + spread)


def _strata(v, count, mult):
    """A value from 0 to 1 that runs through the variations in a different order for each `mult` (coprime with `count`),
    so that two parameters do not rise and fall together between variations."""
    return ((v * mult) % count) / max(1, count - 1)


# ---------------------------------------------------------------------------
# Footsteps on stone
# ---------------------------------------------------------------------------

def _stone_strike(rng, crack_hz, crack_tau, scuff_hz, thud_hz, thud_tau, grit_n, mid_g, click_g):
    """A boot landing on stone: a dry click, a 2 to 6 kHz scrape and a dull 80 to 150 Hz thud.

    The wooden "tock" of the first version (a narrow mode around 700 Hz) is gone: what is left of the
    body is a broad, low-Q noise 12 dB below the click.
    """
    m = ms(220)
    click = pk(hp(noise(m, rng), 2500, 2) * edecay(m, 0.0015, 0.00004))
    crack = pk(bp2(noise(m, rng), crack_hz, 0.9) * edecay(m, crack_tau, 0.0002))
    ns = ms(150)
    scuff = unit(bp2(noise(ns, rng, -3.0), scuff_hz, 0.7)) * edecay(ns, 0.026, 0.002)
    scuff *= np.clip(1.0 + 0.8 * smooth_noise(ns, rng, 120), 0.1, 2.3)
    thud = pk(sine_sweep(m, thud_hz * 1.25, thud_hz * 0.75, 0.012) * edecay(m, thud_tau, 0.0008))
    mid = pk(bp2(noise(m, rng, -3.0), 700.0, 0.8) * edecay(m, 0.012, 0.0005))  # dense and low-Q
    g = grains(m, rng, grit_n, 0.03, 0.12, amp_tau=0.05)
    grit = pk(svf(g, 5200, 3.0, "bp") + 0.5 * svf(g, 2900, 2.5, "bp"))
    y = click_g * click + 1.6 * crack + 0.28 * mid_g * mid + 0.80 * thud + 0.20 * grit
    place(y, scuff, 0.002, 0.50)
    return hp(y, 70, 2)


@sound("step_stone", "step_stone", 8, mix_db=-11.0, dur=(0.15, 0.6), grainy=True, pitch=1.05, vol_db=2.0)
def step_stone(rng, v):
    """Eight different footsteps: heel (the hit, strong) and toe (softer and higher) at 90-140 ms."""
    crack_hz = 2200.0 + 3400.0 * _strata(v, 8, 3)       # click: 2.2 to 5.6 kHz
    thud_hz = 80.0 + 70.0 * _strata(v, 8, 5)            # dull thud: 80 to 150 Hz
    toe_at = 0.090 + 0.050 * _strata(v, 8, 7)
    toe_g = 0.36 + 0.24 * _strata(v, 8, 3)
    heel = _stone_strike(rng, _jit(rng, crack_hz, 0.06), _jit(rng, 0.0085, 0.25), _jit(rng, 2200.0 + 2400.0 * _strata(v, 8, 7), 0.12), thud_hz,
                         _jit(rng, 0.024, 0.2), 4 + int(5 * _strata(v, 8, 5)), 1.0, 0.85 + 0.3 * _strata(v, 8, 7))
    toe = _stone_strike(rng, _jit(rng, crack_hz * 1.18, 0.06), _jit(rng, 0.007, 0.25), _jit(rng, 3900, 0.2), thud_hz * 1.2,
                        _jit(rng, 0.016, 0.2), 3, 0.8, 0.9)
    out = np.zeros(ms(300))
    place(out, heel, 0.0, 1.0)
    place(out, toe, toe_at, toe_g)
    out = sat(out, 1.4)
    return taper(lp(out, 5200.0 + 7000.0 * _strata(v, 8, 5), 1), 0.07)


# ---------------------------------------------------------------------------
# Footsteps on dirt
# ---------------------------------------------------------------------------

def _dirt_strike(rng, f_hi, f_lo, tau, lp_hz, crunch_n, crunch_hz, crunch_gain, mid_hz):
    m = ms(260)
    thump = pk(sine_sweep(m, f_hi * 1.25, f_lo * 1.25, 0.02) * edecay(m, tau, 0.0025))
    low = pk(lp(noise(m, rng), lp_hz, 2) * edecay(m, tau * 0.9, 0.0020))
    mid = pk(bp2(noise(m, rng, -3.0), mid_hz, 0.9) * edecay(m, 0.040, 0.0015))
    tap = pk(bp2(noise(m, rng), 1500.0, 1.0) * edecay(m, 0.003, 0.00006))  # the heel comes in within the first 5 ms
    g = grains(m, rng, crunch_n, 0.040, 0.2, amp_tau=0.08)
    crunch = svf(g, crunch_hz, 2.5, "bp") + 0.8 * svf(g, crunch_hz * 0.45, 1.8, "bp")
    crunch = pk(crunch)
    return hp(0.30 * thump + 0.60 * low + 0.85 * mid + 0.55 * tap + crunch_gain * crunch, 85, 2)


@sound("step_dirt", "step_dirt", 8, mix_db=-12.0, dur=(0.15, 0.6), grainy=True, pitch=1.05, vol_db=2.0)
def step_dirt(rng, v):
    """Eight footsteps on gravelly dirt. No prior drag: the heel is the first thing heard."""
    f_hi = 80.0 + 50.0 * _strata(v, 8, 3)
    tau = 0.030 + 0.040 * _strata(v, 8, 5)
    lp_hz = 220.0 + 260.0 * _strata(v, 8, 7)
    crunch_n = 40 + int(110 * _strata(v, 8, 3))
    crunch_hz = 1800.0 + 2900.0 * _strata(v, 8, 5)
    mid_hz = 420.0 + 620.0 * _strata(v, 8, 7)
    toe_at = 0.095 + 0.040 * _strata(v, 8, 5)
    toe_g = 0.40 + 0.20 * _strata(v, 8, 7)
    out = np.zeros(ms(380))
    heel = _dirt_strike(rng, f_hi, f_hi * 0.6, tau, lp_hz, crunch_n, _jit(rng, crunch_hz, 0.08), 0.9, _jit(rng, mid_hz, 0.08))
    place(out, heel, 0.0, 1.0)
    toe = _dirt_strike(rng, f_hi * 1.35, f_hi * 0.8, tau * 0.6, lp_hz * 1.5, crunch_n // 2, crunch_hz * 1.15, 0.7, mid_hz * 1.4)
    place(out, toe, toe_at, toe_g)
    # The sole dragging the dirt, after stepping, and low.
    ns = ms(200)
    scuff = unit(bp2(noise(ns, rng, -3.0), _jit(rng, 1400.0 + 1200.0 * _strata(v, 8, 3), 0.15), 0.9)) * edecay(ns, 0.045, 0.004)
    place(out, scuff, 0.01, 0.20 + 0.14 * _strata(v, 8, 5))
    out = lp(out, 4200.0 + 4200.0 * _strata(v, 8, 7), 2)
    return taper(out, 0.08)


# ---------------------------------------------------------------------------
# Potion
# ---------------------------------------------------------------------------

def _bubble(rng, f0, rise, tau, attack=0.004):
    n = sec(tau * 6)
    t = tvec(n)
    f = f0 * (1.0 + rise * t)
    ph = 2 * np.pi * np.cumsum(f) / SR
    return (np.sin(ph) + 0.25 * np.sin(2.0 * ph)) * np.exp(-t / tau) * (1.0 - np.exp(-t / attack))


@sound("potion", "potion_drink", 1, mix_db=-7.0, dur=(0.8, 2.2), grainy=True, pitch=1.04, vol_db=1.5)
def potion_drink(rng, v):
    n = sec(1.7)
    y = np.zeros(n)
    # Cork: a dry "pop" of 40 ms at most (it used to be a 380 Hz tone lasting 150 ms: it sounded like a "bup").
    pn = ms(40)
    pop = pk(sine_sweep(pn, 1050, 640, 0.005) * edecay(pn, 0.0065, 0.0002))
    pop += 0.8 * pk(bp2(noise(pn, rng), 1900, 1.8) * edecay(pn, 0.0035, 0.0001))
    pop += 0.5 * pk(hp(noise(pn, rng), 3500, 2) * edecay(pn, 0.0015, 0.00005))
    place(y, taper(pop, 0.012), 0.0, 0.85)
    # Three gulps: a low bubble that rises, a throat breath and a splash.
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
    # Fine bubbling of the liquid (from 0.16 s on, well separated from the cork).
    for _ in range(16):
        t0 = rng.uniform(0.16, 1.28)
        f0 = float(np.exp(rng.uniform(np.log(650), np.log(2600))))
        place(y, pk(_bubble(rng, f0, 8.0, rng.uniform(0.007, 0.02), 0.002)), t0, rng.uniform(0.04, 0.16))
    # Final flash: two crystal partials with tremolo (A, and its fifth), like a glint: the D-A motif.
    sn = sec(0.55)
    ts = tvec(sn)
    shim = (np.sin(2 * np.pi * 1760 * ts) + 0.6 * np.sin(2 * np.pi * 2640 * ts + 0.7) + 0.3 * np.sin(2 * np.pi * 3960 * ts))
    shim *= bump(sn, 1.6, 2.4) * (1.0 + 0.35 * np.sin(2 * np.pi * 6.5 * ts))
    place(y, shim, 1.0, 0.075)
    y = lp(y, 12000, 1)
    return taper(y, 0.1)


# ---------------------------------------------------------------------------
# Interface
# ---------------------------------------------------------------------------

@sound("ui", "ui_click", 1, mix_db=-10.0, dur=(0.04, 0.3), pitch=1.03, vol_db=1.0, dry=False)
def ui_click(rng, v):
    n = ms(120)
    tick = pk(modal(n, [1650, 2980, 4400], [0.022, 0.014, 0.008], [1.0, 0.55, 0.25], rng))
    click = pk(bp2(noise(n, rng), 4200, 1.0) * edecay(n, 0.0018, 0.00006))
    body = pk(sine_sweep(n, 980, 640, 0.008) * edecay(n, 0.010, 0.0003))
    y = 1.0 * tick + 0.7 * click + 0.35 * body
    y = lp(y, 9500, 1)
    y = np.concatenate([taper(y, 0.04), np.zeros(ms(40))])
    return reverb(y, rng, rt60=0.18, wet=0.05)


def _pluck(n, f, rng, t60=0.9, bright=1.0):
    """Plucked string: partials of a stiff string (slightly inharmonic) that decay faster the higher
    they are, plus the fingernail click and the resonance of the wooden body."""
    t = tvec(n)
    hs = np.arange(1, 15)
    fr = f * hs * np.sqrt(1.0 + 0.0004 * hs * hs)
    amps = hs ** -1.15 * np.exp(-hs * 0.05 * bright)
    string = modal(n, fr, t60 / (1.0 + 0.45 * hs), amps, rng)
    nail = pk(bp2(noise(n, rng), 3200, 1.2) * edecay(n, 0.003, 0.00005))
    box = pk(modal(n, [240.0, 385.0, 590.0], [0.07, 0.05, 0.035], [1.0, 0.6, 0.35], rng))
    return pk(string) + 0.22 * nail + 0.18 * box


def _small_bell(n, f, rng):
    """Hand bell: inharmonic partials that die out fast (copper, not crystal)."""
    return pk(modal(n, [f * r for r in (1.0, 2.31, 4.18, 6.69)], [0.50, 0.28, 0.16, 0.09], [1.0, 0.55, 0.32, 0.18], rng))


@sound("ui", "ui_confirm", 1, mix_db=-9.0, dur=(0.3, 1.4), stereo=True, pitch=1.03, vol_db=1.0, dry=False)
def ui_confirm(rng, v):
    """Two plucked-string notes, D and A (the fifth that rises from the horn), with a touch of wood and a
    copper bell over the second. It is no longer the clean harmonic chime of the first version."""
    n = sec(1.0)
    y = np.zeros(n)
    tick = pk(modal(ms(60), [820.0, 1380.0, 2250.0], [0.014, 0.01, 0.007], [1.0, 0.6, 0.3], rng))  # wood / parchment
    place(y, tick, 0.0, 0.40)
    place(y, _pluck(n, 587.3, rng, 0.85, 1.0), 0.0, 0.80)                 # re
    place(y, _pluck(n, 880.0, rng, 1.0, 0.85), 0.105, 1.0)                # la
    place(y, _small_bell(sec(0.6), 1760.0, rng), 0.11, 0.17)
    y = np.concatenate([taper(y, 0.15), np.zeros(sec(0.3))])
    return reverb_stereo(y, rng, rt60=0.5, wet=0.14, damp=0.4, predelay=0.006)


# ---------------------------------------------------------------------------
# Fort horns: won (a rising fifth) and lost (a falling one), with one timbre per realm
# ---------------------------------------------------------------------------

# Each realm has its own instrument: a low war horn (Vardheim), a bright bugle (Solmarch) and a nasal,
# harsh bronze horn (Askarra). `fm` are the tube's resonances (center Hz, width Hz, gain).
_HORNS = {
    "vardheim": dict(d=73.42, a=110.0, fm=((330, 260, 1.0), (760, 400, 0.7), (1500, 700, 0.25)), rolloff=1500,
                     harm=0.80, open=0.42, atk=0.075, breath=0.10, breath_hz=700, buzz=0.0, vib=(5.0, 6.0), tempo=1.05),
    "solmarch": dict(d=293.66, a=440.0, fm=((1150, 600, 1.0), (2500, 900, 0.8), (4200, 1500, 0.25)), rolloff=5200,
                     harm=0.60, open=0.50, atk=0.030, breath=0.055, breath_hz=2400, buzz=0.0, vib=(5.5, 9.0), tempo=0.85),
    "askarra": dict(d=146.83, a=220.0, fm=((650, 300, 0.8), (1250, 450, 1.0), (2300, 700, 0.55)), rolloff=3200,
                    harm=0.62, open=0.46, atk=0.050, breath=0.09, breath_hz=1300, buzz=0.20, vib=(5.0, 12.0), tempo=1.0),
}


def _horn_note(rng, f0, dur, attack, release, cfg, swell, drop_cents):
    """A brass note, a single voice: additive, with harmonics that open up with effort (more in the
    crescendo of the long note), pitch slide on attack, slight vibrato, breath and a pitch drop
    of `drop_cents` on release."""
    n = sec(dur + release * 2.4)
    t = tvec(n)
    sustain = np.where(t < dur, 1.0, np.exp(-(t - dur) / (release / 3.2)))
    env = (1.0 - np.exp(-t / (attack / 2.5))) * sustain
    prog = np.clip(t / dur, 0.0, 1.0)
    swell_curve = (1.0 + swell * (smoothstep(prog) - 0.5) * 2.0) if swell >= 0 else (1.0 + swell * smoothstep(prog))
    env = np.clip(env * swell_curve / (1.0 + abs(swell)), 0.0, 1.5)
    # Pitch: initial slide, vibrato that arrives late, drop on release and a lip tremble.
    cents = (-62.0 * np.exp(-t / 0.05)
             - drop_cents * smoothstep((t - dur) / (release * 0.9))
             + cfg["vib"][1] * smoothstep((t - 0.15) / 0.30) * np.sin(2 * np.pi * cfg["vib"][0] * t + rng.uniform(0, 6.28))
             + 3.0 * smooth_noise(n, rng, 6.0))
    f = f0 * 2.0 ** (cents / 1200.0)
    ph = 2 * np.pi * np.cumsum(f) / SR
    sig = np.zeros(n)
    h = 1
    while h * f0 * 1.03 < 0.45 * SR and h <= 48:
        hf = h * f0
        res = 0.25 + sum(g / (1.0 + ((hf - c) / bw) ** 2) for c, bw, g in cfg["fm"])
        a = h ** -cfg["harm"] * res / (1.0 + (hf / cfg["rolloff"]) ** 2) ** 1.2
        sig += a * np.clip(env, 0.0, 1.0) ** (0.45 + cfg["open"] * h) * np.sin(h * ph + rng.uniform(0, 6.28))
        h += 1
    sig = sig / (np.max(np.abs(sig)) + 1e-12)
    sig *= np.clip(1.0 + 0.012 * smooth_noise(n, rng, 70.0), 0.9, 1.1)
    if cfg["buzz"] > 0:  # the lips buzz: harsh amplitude modulation
        sig *= 1.0 + cfg["buzz"] * np.sin(2 * np.pi * (f0 * 0.5 + 40.0) * t + 3.0 * smooth_noise(n, rng, 20.0))
    puff = np.exp(-t / 0.09) * (1.0 - np.exp(-t / 0.008))
    breath = unit(bp2(noise(n, rng), cfg["breath_hz"], 0.9)) * (puff + 0.22 * env + 0.20 * np.clip(env, 0, 1) * smoothstep(prog))
    return sig + cfg["breath"] * breath


def _horn_call(rng, cfg, notes, tail=0.5):
    """Horn phrase of a single centered voice, with outdoor echo (bounces of 150 to 300 ms)."""
    total = max(t0 + d + r * 2.4 for t0, f, d, a, r, vol, sw, dr in notes) + tail
    y = np.zeros(sec(total))
    for t0, f, d, a, r, vol, sw, dr in notes:
        place(y, _horn_note(rng, f, d, a, r, cfg, sw, dr), t0, vol)
    y = sat(y, 1.45)  # the metal gets brighter when pressed
    return outdoor_echo(y, [(0.18, 0.36, -0.55), (0.27, 0.24, 0.65), (0.41, 0.13, -0.25)], damp_hz=3000.0)


def _horn_won(rng, realm):
    c = _HORNS[realm]
    k = c["tempo"]
    d, a = c["d"], c["a"]
    # "tu-tu-TUUU": two short calls on D and a long one on A (the rising fifth), with the crescendo.
    return _horn_call(rng, c, [(0.0, d, 0.19 * k, c["atk"], 0.11, 0.62, 0.0, 30.0),
                               (0.31 * k, d, 0.19 * k, c["atk"], 0.11, 0.72, 0.0, 30.0),
                               (0.63 * k, a, 0.66 * k, c["atk"] * 1.35, 0.30, 1.0, 0.8, 38.0)])


def _horn_lost(rng, realm):
    c = _HORNS[realm]
    k = c["tempo"]
    d, a = c["d"], c["a"]
    # Two slow falling notes (A and D): the second dies out and sinks 50 cents. Sadness, not triumph.
    return _horn_call(rng, c, [(0.0, a, 0.40 * k, c["atk"] * 1.2, 0.18, 0.85, 0.2, 32.0),
                               (0.58 * k, d, 0.98 * k, c["atk"] * 1.5, 0.62, 1.0, -0.45, 50.0)], tail=0.6)


@sound("alert", "horn_fort_won_vardheim", 1, mix_db=-1.0, dur=(1.0, 3.2), stereo=True, pitch=1.0, vol_db=0.0)
def horn_fort_won_vardheim(rng, v):
    return _horn_won(rng, "vardheim")


@sound("alert", "horn_fort_won_solmarch", 1, mix_db=-1.0, dur=(0.8, 3.0), stereo=True, pitch=1.0, vol_db=0.0)
def horn_fort_won_solmarch(rng, v):
    return _horn_won(rng, "solmarch")


@sound("alert", "horn_fort_won_askarra", 1, mix_db=-1.0, dur=(0.9, 3.0), stereo=True, pitch=1.0, vol_db=0.0)
def horn_fort_won_askarra(rng, v):
    return _horn_won(rng, "askarra")


@sound("alert", "horn_fort_lost_vardheim", 1, mix_db=-1.0, dur=(1.0, 3.6), stereo=True, pitch=1.0, vol_db=0.0)
def horn_fort_lost_vardheim(rng, v):
    return _horn_lost(rng, "vardheim")


@sound("alert", "horn_fort_lost_solmarch", 1, mix_db=-1.0, dur=(0.8, 3.4), stereo=True, pitch=1.0, vol_db=0.0)
def horn_fort_lost_solmarch(rng, v):
    return _horn_lost(rng, "solmarch")


@sound("alert", "horn_fort_lost_askarra", 1, mix_db=-1.0, dur=(0.9, 3.4), stereo=True, pitch=1.0, vol_db=0.0)
def horn_fort_lost_askarra(rng, v):
    return _horn_lost(rng, "askarra")


# ---------------------------------------------------------------------------
# Voices of the Hollow: undead soldiers of the old garrison of Eld
# ---------------------------------------------------------------------------

def _res(f, fc, bw):
    return 1.0 / (1.0 + ((f - fc) / bw) ** 2)


def _hollow_voice(rng, dur, f_start, f_end, vowel_a, vowel_b, breath, rasp, fry_hz, attack, release, rattle, jitter=0.035):
    """Undead voice by source and filter: glottal pulse (sum of harmonics with a pitch that falls and trembles),
    three formants that move from one vowel to another, a breath of air through the same formants, a
    "broken voice" tremor at `fry_hz` and a growl an octave lower. No reverb: dry like the rest.

    `vowel_*` are (F1, F2, F3) in Hz. `rattle` is the strength of the final death rattle (air bursts at 20-30 Hz).
    """
    n = sec(dur)
    t = tvec(n)
    u = t / dur
    glide = smoothstep(u ** 0.7)
    f0 = f_start * (f_end / f_start) ** glide
    f0 = f0 * (1.0 + jitter * smooth_noise(n, rng, 13.0))
    ph = 2 * np.pi * np.cumsum(f0) / SR
    f1 = vowel_a[0] + (vowel_b[0] - vowel_a[0]) * glide
    f2 = vowel_a[1] + (vowel_b[1] - vowel_a[1]) * glide
    f3 = vowel_a[2] + (vowel_b[2] - vowel_a[2]) * glide
    voiced = np.zeros(n)
    h = 1
    while h * float(f0.min()) < 6000.0 and h <= 70:
        hf = h * f0
        formants = 1.0 * _res(hf, f1, 90.0 + 0.10 * f1) + 0.60 * _res(hf, f2, 130.0 + 0.08 * f2) + 0.22 * _res(hf, f3, 260.0) + 0.004
        voiced += (h ** -(1.45 - 0.30 * rasp)) * formants * np.sin(h * ph + rng.uniform(0, 6.28))
        h += 1
    voiced = voiced / (np.max(np.abs(voiced)) + 1e-12)
    # Growl: a subharmonic (an octave lower) that gives weight and roughness.
    growl = np.sin(0.5 * ph + 1.0) * _res(0.5 * f0, f1, 200.0)
    voiced = voiced + rasp * 0.55 * growl
    # Broken voice: the source cuts out in bursts.
    fry = np.clip(0.55 + 0.9 * np.abs(np.sin(np.pi * np.cumsum(fry_hz * (1.0 + 0.3 * smooth_noise(n, rng, 8.0))) / SR)), 0.0, 1.0)
    voiced *= 0.35 + 0.65 * fry
    voiced = sat(voiced, 1.0 + 0.9 * rasp)
    # Breath: noise through the moving formants.
    air = unit(svf(svf(noise(n, rng), f2, 2.5, "bp"), f1 * 1.3, 1.5, "bp")) + 0.5 * unit(bp2(noise(n, rng), f2 * 1.4, 1.5))
    env = (1.0 - np.exp(-t / attack)) * np.exp(-np.clip(t - dur * 0.45, 0.0, None) / release)
    y = voiced * env + breath * air * (0.4 * np.exp(-t / 0.08) + 0.6 * env * (0.5 + 0.5 * u))
    # Roughness: high noise that comes out on each glottal pulse (the voice of a chest that no longer has clean air).
    pulse = np.maximum(np.sin(ph), 0.0) ** 2
    y = y + (0.07 + 0.13 * rasp) * unit(bp2(noise(n, rng), 3600.0, 0.6)) * pulse * env
    if rattle > 0:  # death rattle: low air bursts at 20-30 Hz that space out
        gate = np.clip(np.sin(2 * np.pi * np.cumsum(28.0 - 14.0 * u) / SR), 0.0, 1.0) ** 2
        rat = unit(lp(noise(n, rng, -3.0), 700, 2)) * gate * smoothstep((u - 0.45) / 0.3) * np.exp(-np.clip(u - 0.7, 0.0, None) / 0.12)
        y = y + rattle * rat
    return y


# Vowels: (F1, F2, F3) in Hz.
_VOW_A = (720.0, 1150.0, 2500.0)   # a
_VOW_O = (480.0, 900.0, 2400.0)    # o
_VOW_E = (550.0, 1750.0, 2500.0)   # e
_VOW_U = (330.0, 780.0, 2300.0)    # u


@sound("hollow", "hollow_hurt", 4, mix_db=-4.0, dur=(0.15, 0.7), grainy=True, pitch=1.06, vol_db=2.0)
def hollow_hurt(rng, v):
    """A Hollow's wound: a short, low, harsh groan, with breath."""
    p = [dict(dur=0.36, f=(140, 88), a=_VOW_A, b=_VOW_O, rasp=0.55, breath=0.30),
         dict(dur=0.30, f=(165, 105), a=_VOW_E, b=_VOW_A, rasp=0.70, breath=0.25),
         dict(dur=0.44, f=(120, 72), a=_VOW_A, b=_VOW_U, rasp=0.60, breath=0.38),
         dict(dur=0.28, f=(185, 120), a=_VOW_A, b=_VOW_E, rasp=0.80, breath=0.22)][v]
    y = _hollow_voice(rng, p["dur"], _jit(rng, p["f"][0], 0.05), _jit(rng, p["f"][1], 0.05), p["a"], p["b"],
                      p["breath"], p["rasp"], fry_hz=_jit(rng, 34.0, 0.15), attack=0.012, release=0.10, rattle=0.0)
    y = hp(y, 60, 2)
    return taper(lp(y, 5200, 2), 0.06)


@sound("hollow", "hollow_death", 2, mix_db=-3.0, dur=(0.6, 2.0), grainy=True, pitch=1.05, vol_db=2.0)
def hollow_death(rng, v):
    """A Hollow's death: a long moan that sinks and dies out in a death rattle."""
    p = [dict(dur=1.15, f=(118, 46), a=_VOW_A, b=_VOW_U, rasp=0.65, breath=0.45, rattle=0.55),
         dict(dur=1.30, f=(100, 40), a=_VOW_O, b=_VOW_U, rasp=0.75, breath=0.50, rattle=0.70)][v]
    y = _hollow_voice(rng, p["dur"], _jit(rng, p["f"][0], 0.05), _jit(rng, p["f"][1], 0.05), p["a"], p["b"],
                      p["breath"], p["rasp"], fry_hz=_jit(rng, 26.0, 0.15), attack=0.05, release=0.30, rattle=p["rattle"])
    y = hp(y, 50, 2)
    return taper(lp(y, 4800, 2), 0.15)
