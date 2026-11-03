"""Catálogo de sonidos de combate de Eldmark (ART-11): todo en seco, para el sonido 3D.

La reverberación no va horneada: la pone el motor (buses o reverberación de Area3D por zona) para que un
interior y un vado al aire libre suenen distinto. Aquí solo hay lo que es del propio golpe.

    swing/        barridos de espada: 6 ligeros (0,20-0,25 s) y 3 fuertes (0,40-0,50 s) con el pico fijo
    hit_flesh/    golpes de espada en carne
    hit_leather/  en cuero
    hit_gambeson/ en gambesón (tela acolchada)
    hit_mail/     en cota de malla
    hit_shield/   golpe en escudo de madera (5) y acero contra el embrazo o el borde (bloqueo con metal, 3)
    parry/        parada: «shing» brillante con arrastre de filo (4)
    body/         caída de un cuerpo: torso, miembros y arma (3, una con armadura)
    dodge/        esquiva: voltereta (3) y paso atrás (2)
    bow/          arco: tensar (2) y soltar (3)
    arrow/        impacto de flecha en carne (3) y en madera (2)

Ver `synth_sfx.py` para el uso y `sfx_dsp.py` para las herramientas.
"""

import numpy as np

from sfx_dsp import (SR, bp2, bump, edecay, fit_band, grains, hp, lp, modal, ms, noise, peak_env, pk, place, sat,
                     sec, sine_sweep, smooth_noise, smoothstep, sound, svf, taper, tvec, unit)


def _jit(rng, value, spread):
    """`value` con una variación uniforme de ±`spread` (relativa), para que cada variación sea distinta."""
    return value * rng.uniform(1.0 - spread, 1.0 + spread)


# ---------------------------------------------------------------------------
# Barridos de espada
# ---------------------------------------------------------------------------

def _doppler(n, t_pk, s, f_rise, f_peak, f_fall):
    """Frecuencia central por muestra que sube con la amplitud hasta el pico y baja después (Doppler):
    `s` es la amplitud normalizada (0 a 1) elevada a un exponente que redondea la subida."""
    t = tvec(n)
    return np.where(t < t_pk, f_rise + (f_peak - f_rise) * s, f_fall + (f_peak - f_fall) * s)


def _swoosh(rng, dur, t_pk, tau_r, tau_f, p, bands, f_lo, f_hi, f_end, q, body, whistle, air, tail, tail_tau,
            turb, fit_frac):
    """Barrido con la envolvente asimétrica y el pico en `t_pk`.

    Capas: ruido rosa por un paso banda que sube con la amplitud hasta `f_hi` y baja a `f_end` (efecto
    Doppler de verdad: la frecuencia sigue a la amplitud), un cuerpo grave que hace lo mismo en
    `body[0]`..`body[1]`..`body[2]`, el aire agudo, un silbido estrecho que sigue al barrido y una cola de
    soplo que sobrevive al paso de la hoja. La capa grave se ajusta hasta que la banda `bands` lleve
    `fit_frac` de la energía.
    """
    n = sec(dur)
    t = tvec(n)
    a = peak_env(n, t_pk, tau_r, tau_f, p)
    s = a ** 0.55
    fc = _doppler(n, t_pk, s, f_lo, f_hi, f_end)
    am = np.clip(1.0 + turb * smooth_noise(n, rng, 45), 0.4, 1.8)

    main = unit(bp2(noise(n, rng, -3.0), fc, q) * a * am)
    airy = unit(hp(noise(n, rng), 4200, 2) * a ** 2.2 * am)
    sing = unit(bp2(noise(n, rng), np.minimum(fc * 1.55, 9500), 28.0) * a ** 1.5)
    fb = _doppler(n, t_pk, s, body[0], body[1], body[2])
    low = unit(bp2(noise(n, rng, -3.0), fb, 1.1) * a ** 0.75 * (0.85 + 0.15 * am))
    tail_env = tail * smoothstep((t - t_pk + 0.03) / 0.03) * np.exp(-np.clip(t - t_pk, 0.0, None) / tail_tau)
    soplo = unit(bp2(noise(n, rng, -3.0), f_end * (1.0 + 0.45 * s), 0.8) * tail_env)

    layers = {"main": main, "air": airy, "sing": sing, "low": low, "tail": soplo}
    gains = {"main": 1.0, "air": air, "sing": whistle, "low": body[3], "tail": 1.0}
    y, _ = fit_band(layers, gains, "low", bands[0], bands[1], fit_frac)
    y = hp(y, 90, 2)
    # Cierre explícito: el soplo no debe alargar el archivo más de la duración pedida.
    return taper(y, 0.05)


@sound("swing", "sword_swing_light", 6, mix_db=-5.0, dur=(0.20, 0.25), peak_s=(0.09, 0.012), pitch=1.05, vol_db=2.0)
def sword_swing_light(rng, v):
    # Seis caracteres: 1 limpio · 2 grave y lento · 3 agudo y seco · 4 aireado · 5 con silbido · 6 ancho.
    p = [dict(dur=0.225, tau_r=0.034, tau_f=0.027, f_lo=620, f_hi=3300, f_end=1250, q=2.6, whistle=0.10, air=0.22, turb=0.20),
         dict(dur=0.235, tau_r=0.030, tau_f=0.024, f_lo=520, f_hi=2500, f_end=1000, q=2.0, whistle=0.07, air=0.15, turb=0.20),
         dict(dur=0.215, tau_r=0.031, tau_f=0.024, f_lo=800, f_hi=4300, f_end=1600, q=3.0, whistle=0.12, air=0.34, turb=0.15),
         dict(dur=0.230, tau_r=0.035, tau_f=0.029, f_lo=600, f_hi=3000, f_end=1200, q=1.5, whistle=0.03, air=0.30, turb=0.34),
         dict(dur=0.220, tau_r=0.033, tau_f=0.026, f_lo=680, f_hi=3700, f_end=1400, q=3.6, whistle=0.15, air=0.18, turb=0.12),
         dict(dur=0.240, tau_r=0.036, tau_f=0.030, f_lo=560, f_hi=2850, f_end=1100, q=2.2, whistle=0.08, air=0.26, turb=0.25)][v]
    return _swoosh(rng, p["dur"], 0.090, _jit(rng, p["tau_r"], 0.05), _jit(rng, p["tau_f"], 0.05), 1.6, (250, 600),
                   _jit(rng, p["f_lo"], 0.05), _jit(rng, p["f_hi"], 0.05), _jit(rng, p["f_end"], 0.05), p["q"],
                   (_jit(rng, 260, 0.08), _jit(rng, 520, 0.08), _jit(rng, 300, 0.08), 0.8), p["whistle"], p["air"],
                   tail=0.11, tail_tau=0.075, turb=p["turb"], fit_frac=0.27)


@sound("swing", "sword_swing_heavy", 3, mix_db=-4.0, dur=(0.40, 0.50), peak_s=(0.20, 0.018), pitch=1.05, vol_db=2.0)
def sword_swing_heavy(rng, v):
    p = [dict(dur=0.44, tau_r=0.068, tau_f=0.050, f_lo=210, f_hi=1400, f_end=420, q=1.3, whistle=0.04, air=0.08, turb=0.22),
         dict(dur=0.46, tau_r=0.074, tau_f=0.056, f_lo=150, f_hi=1250, f_end=280, q=1.1, whistle=0.02, air=0.05, turb=0.24),
         dict(dur=0.45, tau_r=0.064, tau_f=0.047, f_lo=240, f_hi=1500, f_end=480, q=1.5, whistle=0.06, air=0.12, turb=0.20)][v]
    return _swoosh(rng, p["dur"], 0.200, _jit(rng, p["tau_r"], 0.04), _jit(rng, p["tau_f"], 0.04), 1.5, (120, 400),
                   _jit(rng, p["f_lo"], 0.05), _jit(rng, p["f_hi"], 0.05), _jit(rng, p["f_end"], 0.05), p["q"],
                   (_jit(rng, 130, 0.08), _jit(rng, 330, 0.08), _jit(rng, 150, 0.08), 1.0), p["whistle"], p["air"],
                   tail=0.13, tail_tau=0.10, turb=p["turb"], fit_frac=0.30)


# ---------------------------------------------------------------------------
# Golpe de espada contra carne, cuero, gambesón y malla
# ---------------------------------------------------------------------------

# Cada material tiene su receta; cada variación sale de ella con variaciones al azar (frecuencias ±10 %,
# duraciones ±20 %). La forma es la del mejor golpe de la primera tanda (el cuero): pico a los pocos
# milisegundos, golpe sordo de 60-120 Hz y casi toda la energía en los primeros 80 ms.
_HIT_RECIPES = {
    "flesh": dict(f0=118, f1=74, thump_tau=0.026, body_hz=380, body_tau=0.040, slap_hz=1200, slap_tau=0.018,
                  snap=0.16, cut=0.80, cloth=0.0, mail=0.0, wet=0.55, mode=240, mode_g=0.25, drive=1.8, frac=0.27),
    "leather": dict(f0=135, f1=82, thump_tau=0.026, body_hz=520, body_tau=0.040, slap_hz=1700, slap_tau=0.014,
                    snap=0.50, cut=0.25, cloth=0.18, mail=0.0, wet=0.0, mode=300, mode_g=0.50, drive=2.2, frac=0.25),
    "gambeson": dict(f0=108, f1=68, thump_tau=0.032, body_hz=420, body_tau=0.048, slap_hz=950, slap_tau=0.020,
                     snap=0.10, cut=0.10, cloth=0.45, mail=0.0, wet=0.0, mode=260, mode_g=0.30, drive=1.7, frac=0.30),
    "mail": dict(f0=128, f1=80, thump_tau=0.028, body_hz=640, body_tau=0.034, slap_hz=2000, slap_tau=0.010,
                 snap=0.45, cut=0.15, cloth=0.0, mail=0.95, wet=0.0, mode=330, mode_g=0.35, drive=2.0, frac=0.24),
}


def _hit(rng, mat, v):
    r = _HIT_RECIPES[mat]
    hard = 0.75 + 0.5 * ((v * 0.618) % 1.0)  # 0,75 a 1,25: golpes más flojos y más fuertes dentro del banco
    n = ms(300)
    f0 = _jit(rng, r["f0"], 0.10)
    f1 = _jit(rng, r["f1"], 0.10)
    thump = pk(sine_sweep(n, f0, f1, 0.014) * edecay(n, _jit(rng, r["thump_tau"], 0.20), 0.0010))
    body = pk(bp2(noise(n, rng, -3.0), _jit(rng, r["body_hz"], 0.10), 0.9) * edecay(n, _jit(rng, r["body_tau"], 0.2), 0.0008))
    slap = pk(bp2(noise(n, rng, -3.0), _jit(rng, r["slap_hz"], 0.12), 0.9) * edecay(n, _jit(rng, r["slap_tau"], 0.2), 0.0004))
    snap = pk(hp(noise(n, rng), _jit(rng, 3200, 0.12), 2) * edecay(n, 0.005, 0.0001))
    mode = _jit(rng, r["mode"], 0.10)
    modes = pk(modal(n, [mode * k for k in (1.0, 1.62, 2.51)], [0.07, 0.055, 0.04], [1.0, 0.7, 0.5], rng))
    rest = 0.95 * body + (0.85 * hard) * slap + r["snap"] * hard * snap + r["mode_g"] * modes

    nc = ms(80)
    tc = tvec(nc)
    cut = unit(bp2(noise(nc, rng), 900.0 + 3000.0 * np.exp(-tc / 0.03), 2.2)) * bump(nc, 0.6, 2.4)
    place(rest, cut, 0.004, r["cut"] * 0.65)

    if r["wet"] > 0.0:  # carne: chapoteo corto, grano de ruido medio con modulación rápida
        nw = ms(70)
        squelch = unit(bp2(noise(nw, rng, -3.0), _jit(rng, 1000, 0.2), 1.3)) * bump(nw, 0.8, 2.2)
        squelch *= np.clip(1.0 + 0.8 * smooth_noise(nw, rng, 110), 0.1, 2.2)
        place(rest, squelch, 0.006, r["wet"] * 0.35)
    if r["cloth"] > 0.0:  # tela, correa o pliegue: roce de 80 ms como mucho y 6 dB por debajo del cuerpo
        nr = ms(80)
        rustle = unit(bp2(noise(nr, rng, -3.0), _jit(rng, 1400, 0.15), 1.0)) * bump(nr, 1.2, 1.8)
        rustle *= np.clip(1.0 + 0.7 * smooth_noise(nr, rng, 90), 0.1, 2.0)
        place(rest, rustle, 0.010, r["cloth"] * 0.16)
    if r["mail"] > 0.0:  # malla: anillos que se agitan, un tintineo de 100 ms como mucho
        nm = ms(110)
        fr = np.exp(rng.uniform(np.log(2200), np.log(7500), 26))
        rings = modal(nm, fr, rng.uniform(0.025, 0.075, 26), rng.uniform(0.3, 1.0, 26) / (1.0 + fr / 6000.0), rng)
        place(rest, pk(rings), 0.002, r["mail"] * 0.38)

    layers = {"thump": thump, "rest": rest}
    y, _ = fit_band(layers, {"thump": 0.6, "rest": 1.0}, "thump", 60, 120, r["frac"])
    y = sat(hp(y, 55, 1), r["drive"])
    y = lp(y, 10000, 1)
    return taper(y, 0.06)


@sound("hit_flesh", "hit_flesh", 5, mix_db=0.0, dur=(0.15, 0.45), pitch=1.05, vol_db=2.0)
def hit_flesh(rng, v):
    return _hit(rng, "flesh", v)


@sound("hit_leather", "hit_leather", 5, mix_db=0.0, dur=(0.15, 0.45), pitch=1.05, vol_db=2.0)
def hit_leather(rng, v):
    return _hit(rng, "leather", v)


@sound("hit_gambeson", "hit_gambeson", 5, mix_db=0.0, dur=(0.15, 0.45), pitch=1.05, vol_db=2.0)
def hit_gambeson(rng, v):
    return _hit(rng, "gambeson", v)


@sound("hit_mail", "hit_mail", 4, mix_db=0.0, dur=(0.15, 0.5), grainy=True, pitch=1.05, vol_db=2.0)
def hit_mail(rng, v):
    return _hit(rng, "mail", v)


# ---------------------------------------------------------------------------
# Escudo: golpe en madera y golpe de acero contra el embrazo
# ---------------------------------------------------------------------------

@sound("hit_shield", "hit_shield_wood", 5, mix_db=-1.0, dur=(0.2, 0.8), pitch=1.05, vol_db=2.0)
def hit_shield_wood(rng, v):
    p = [  # 1: tabla plana · 2: golpe fuerte con crujido · 3: contra el embrazo de hierro (con ring) · 4 y 5: variantes
        dict(f=270, t60=1.0, crack=0.35, rattle=0.25, boss=0.0, thump=0.8),
        dict(f=235, t60=1.3, crack=0.55, rattle=0.45, boss=0.0, thump=1.0),
        dict(f=305, t60=0.9, crack=0.45, rattle=0.2, boss=0.45, thump=0.6),
        dict(f=252, t60=0.85, crack=0.30, rattle=0.40, boss=0.0, thump=0.9),
        dict(f=288, t60=1.1, crack=0.50, rattle=0.15, boss=0.22, thump=0.7)][v]
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
    return taper(y, 0.07)


@sound("hit_shield", "hit_shield_metal", 3, mix_db=-1.0, dur=(0.12, 0.45), grainy=True, pitch=1.05, vol_db=2.0)
def hit_shield_metal(rng, v):
    """Bloqueo con metal: acero contra el escudo. Golpe sordo de madera, un «clanc» corto y el traqueteo del
    borde. No suena como la parada: se apaga en 150-250 ms, sin cola brillante."""
    p = [dict(f=285, boss=0.55, rim=0.35, wood=1.0, rattle=0.40),   # contra el umbo (más metal)
         dict(f=255, boss=0.20, rim=0.75, wood=0.80, rattle=0.55),  # contra el borde (más traqueteo)
         dict(f=300, boss=0.30, rim=0.30, wood=1.15, rattle=0.30)][v]  # contra la cara plana (más madera)
    n = ms(400)
    wood = pk(modal(n, p["f"] * np.array([1.0, 1.63, 2.38, 3.51]) * rng.uniform(0.985, 1.015, 4),
                    [0.10, 0.08, 0.06, 0.04], [1.0, 0.8, 0.6, 0.4], rng))
    thump = pk(sine_sweep(n, 160, 88, 0.02) * edecay(n, 0.03, 0.0015))
    knock = pk(bp2(noise(n, rng), 2100, 1.0) * edecay(n, 0.006, 0.0001))
    # «Clanc»: nube corta de modos de acero (1,2 a 6 kHz) que se apaga en 40-140 ms.
    fr = np.exp(rng.uniform(np.log(1200), np.log(6000), 26))
    clank = pk(modal(n, fr, rng.uniform(0.04, 0.14, 26), rng.uniform(0.3, 1.0, 26) / (1.0 + fr / 4000.0), rng))
    ring = pk(modal(n, [1480.0 * rng.uniform(0.97, 1.03), 2650.0 * rng.uniform(0.97, 1.03)], [0.19, 0.12], [1.0, 0.55], rng))
    rat = pk(bp2(noise(n, rng), 1300, 2.2) * edecay(n, 0.05, 0.001) * np.clip(0.4 + smooth_noise(n, rng, 150), 0.0, 2.5))
    y = (p["wood"] * 0.85 * wood + 0.30 * thump + 0.9 * knock + p["rim"] * 0.7 * clank
         + p["boss"] * 0.45 * ring + p["rattle"] * 0.5 * rat)
    y = sat(y, 1.7)
    y = lp(y, 9000, 1)
    return taper(y, 0.05)


# ---------------------------------------------------------------------------
# Parada de espada contra espada: «shing» brillante con arrastre de filo
# ---------------------------------------------------------------------------

BAR_RATIOS = np.array([1.0, 2.756, 5.404, 8.933, 13.344])  # barra libre: una hoja es una barra
BAR_AMPS = np.array([0.28, 1.0, 0.85, 0.5, 0.3])           # el fundamental, 11 dB por debajo de los modos de hoja
BAR_T60 = np.array([0.50, 0.42, 0.32, 0.22, 0.15])


def _blade_ring(n, f0, scale, rng):
    """Hoja de acero golpeada: modos de barra libre (los de 2 a 11 kHz mandan), cada uno con un gemelo
    desafinado (los batidos)."""
    freqs = []
    amps = []
    t60s = []
    for r, a, t in zip(BAR_RATIOS, BAR_AMPS, BAR_T60):
        freqs.append(f0 * r * rng.uniform(0.996, 1.004))
        amps.append(a)
        t60s.append(t * scale)
        freqs.append(f0 * r * rng.uniform(1.002, 1.007))
        amps.append(a * 0.7)
        t60s.append(t * scale * 0.9)
    return modal(n, freqs, t60s, amps, rng)


@sound("parry", "clash_metal", 4, mix_db=-2.0, dur=(0.35, 1.2), pitch=1.04, vol_db=2.0)
def clash_metal(rng, v):
    # Dos hojas con una razón de frecuencias que no es musical (1,37 a 1,43; nada de 5:4, 4:3 ni 3:2) y una
    # nube de 80 a 150 modos inarmónicos entre 2 y 10 kHz que lleva la cola.
    p = [dict(a=1180, ratio=1.39, scale=0.8, cloud=110, t60=(0.3, 0.8), scrape=0.65, thud=0.25, hard=1.0),    # seca y brillante
         dict(a=930, ratio=1.42, scale=1.0, cloud=140, t60=(0.4, 0.9), scrape=0.85, thud=0.45, hard=1.15),   # pesada, con arrastre largo
         dict(a=1300, ratio=1.37, scale=0.7, cloud=85, t60=(0.3, 0.6), scrape=0.45, thud=0.18, hard=0.9),    # esgrima: corta y fina
         dict(a=1050, ratio=1.41, scale=0.9, cloud=125, t60=(0.35, 0.85), scrape=0.72, thud=0.30, hard=1.0)][v]  # hojas trabadas que resbalan
    n = sec(1.2)
    ring = pk(_blade_ring(n, p["a"], p["scale"], rng) + 0.8 * _blade_ring(n, p["a"] * p["ratio"], p["scale"] * 0.9, rng))
    cnt = p["cloud"]
    fr = np.exp(rng.uniform(np.log(2000), np.log(10000), cnt))
    cloud = pk(modal(n, fr, rng.uniform(*p["t60"], cnt), rng.uniform(0.25, 1.0, cnt) / (1.0 + fr / 9000.0), rng))

    # Impacto: ráfaga de ruido agudo + ruido «metálico» (ruido por modulación en anillo con senos inarmónicos).
    burst = pk(hp(noise(n, rng), 1800, 2) * edecay(n, 0.006, 0.00005))
    tn = tvec(n)
    ringmod = np.sin(2 * np.pi * 3170 * tn) + 0.7 * np.sin(2 * np.pi * 5230 * tn + 1.0)
    metallic = pk(bp2(noise(n, rng), 4200, 0.8) * ringmod * edecay(n, 0.030, 0.0001))
    thud = pk(sine_sweep(n, 330, 170, 0.012) * edecay(n, 0.020, 0.0005))
    # Solo el impacto se satura: saturar los modos que suenan mucho tiempo crea tonos de diferencia graves.
    y = 0.40 * ring + 0.55 * cloud + sat(1.1 * p["hard"] * burst + 0.65 * metallic + p["thud"] * thud, 1.4)

    # Arrastre del filo: banda estrecha de ruido que cae de 9 a 3 kHz mientras una hoja resbala por la otra.
    ns = sec(0.26)
    ts = tvec(ns)
    fc = 3000.0 + 6000.0 * np.exp(-ts / 0.07)
    scrape = unit(bp2(noise(ns, rng), fc, 4.0)) * bump(ns, 0.5, 2.0)
    scrape *= np.clip(1.0 + 0.5 * smooth_noise(ns, rng, 160), 0.2, 1.8)  # el filo no desliza liso
    place(y, scrape, 0.012, p["scrape"] * 0.34)
    return taper(y, 0.2)


# ---------------------------------------------------------------------------
# Cuerpo que cae
# ---------------------------------------------------------------------------

def _body_impact(n, rng, f0, f1, tau, low_hz, slap_hz, slap_tau, click_gain):
    """Un impacto sordo: golpe grave, ruido grave y un transitorio de tela o cuero."""
    thump = pk(sine_sweep(n, f0, f1, 0.05) * edecay(n, tau, 0.003))
    lows = pk(lp(noise(n, rng), low_hz, 2) * edecay(n, tau * 0.9, 0.003))
    slap = pk(bp2(noise(n, rng, -3.0), slap_hz, 0.9) * edecay(n, slap_tau, 0.0010))
    click = pk(hp(noise(n, rng), 1600, 2) * edecay(n, 0.004, 0.0001))
    return thump + 0.8 * lows, 0.7 * slap + click_gain * click


@sound("body", "body_fall", 3, mix_db=-3.0, dur=(0.35, 1.2), grainy=True, pitch=1.05, vol_db=2.0)
def body_fall(rng, v):
    """Tres impactos claros: el torso a los 0 s, los miembros entre 120 y 250 ms y, a veces, el arma o el
    escudo; la tela que se arrastra entra después del primero y mucho más baja. 1: tela · 2: cuero y equipo ·
    3: con armadura (placas que tintinean)."""
    n = sec(0.9)
    t2 = [0.140, 0.185, 0.215][v]
    low = np.zeros(n)
    upper = np.zeros(n)
    # Torso.
    lo1, up1 = _body_impact(n, rng, _jit(rng, 125, 0.08), _jit(rng, 70, 0.1), _jit(rng, 0.045, 0.1), 240, 520, 0.030, 0.25)
    place(low, lo1, 0.0, 1.0)
    place(upper, up1, 0.0, 1.0)
    # Miembros (y el arma o el escudo).
    lo2, up2 = _body_impact(n, rng, _jit(rng, 140, 0.1), _jit(rng, 70, 0.1), 0.050, 260, 700, 0.022, 0.35)
    place(low, lo2, t2, 0.16)
    place(upper, up2, t2, 0.18)
    if v != 0:
        t3 = t2 + rng.uniform(0.075, 0.110)
        lo3, up3 = _body_impact(n, rng, 165, 90, 0.040, 300, 900, 0.018, 0.5)
        place(low, lo3, t3, 0.09)
        place(upper, up3, t3, 0.11)
    # Tela y cuero que se arrastran: entran después del primer impacto y 8 dB más bajas.
    nr = ms(330)
    slide = unit(bp2(noise(nr, rng, -3.0), 800, 0.8)) * bump(nr, 0.9, 1.8)
    slide *= np.clip(1.0 + 0.6 * smooth_noise(nr, rng, 85), 0.1, 2.2)
    place(upper, slide, 0.035 + 0.01 * v, 0.045)
    if v == 2:  # armadura: placas que chocan, una nube corta de modos de acero tras cada impacto
        for t0, g in ((0.0, 0.5), (t2, 0.28), (t2 + 0.09, 0.2), (t2 + 0.19, 0.12)):
            fr = np.exp(rng.uniform(np.log(900), np.log(5500), 22))
            plates = pk(modal(ms(260), fr, rng.uniform(0.05, 0.16, 22), rng.uniform(0.3, 1.0, 22) / (1.0 + fr / 3500.0), rng))
            place(upper, plates, t0, g)
    elif v == 1:  # cuero y equipo: hebillas y correas
        for t0 in (0.01, t2 + 0.01):
            f0 = rng.uniform(1100, 2800)
            ring = modal(ms(200), [f0, f0 * 2.41, f0 * 3.93], [0.07, 0.05, 0.03], [1.0, 0.45, 0.25], rng)
            place(upper, pk(ring), t0, 0.22)
    y, _ = fit_band({"low": low, "upper": upper}, {"low": 1.0, "upper": 1.0}, "low", 20, 150, 0.47)
    y = sat(hp(y, 40, 2), 1.4)
    y = lp(y, 8500, 1)
    return taper(y, 0.1)


# ---------------------------------------------------------------------------
# Esquiva
# ---------------------------------------------------------------------------

def _cloth_whoosh(rng, dur, t_pk, f_lo, f_hi, f_end, q, tau_r=0.06, tau_f=0.08):
    n = sec(dur)
    a = peak_env(n, t_pk, tau_r, tau_f, 1.5)
    fc = _doppler(n, t_pk, a ** 0.6, f_lo, f_hi, f_end)
    return unit(bp2(noise(n, rng, -3.0), fc, q) * a * np.clip(1.0 + 0.4 * smooth_noise(n, rng, 55), 0.3, 1.9))


def _foot_tap(rng, f=95.0, tau=0.028, slap_hz=650.0):
    """Pisada seca de bota sobre tierra: golpe grave, golpe de cuero y un grano de gravilla."""
    m = ms(160)
    thump = pk(sine_sweep(m, f * 1.3, f * 0.7, 0.02) * edecay(m, tau, 0.0015))
    slap = pk(bp2(noise(m, rng, -3.0), slap_hz, 0.9) * edecay(m, 0.018, 0.0006))
    grit = pk(svf(grains(m, rng, 14, 0.02, 0.1, amp_tau=0.04), 3200, 2.2, "bp"))
    return hp(0.8 * thump + 0.7 * slap + 0.25 * grit, 70, 2)


@sound("dodge", "dodge_roll", 3, mix_db=-9.0, dur=(0.3, 0.85), grainy=True, pitch=1.06, vol_db=2.0)
def dodge_roll(rng, v):
    """Voltereta: tela que corta el aire, el roce del hombro y la espalda con el suelo y un apoyo al final."""
    p = [dict(dur=0.60, f=(420, 1800, 650), q=1.0, rub=1100, rub_g=0.75, wh=0.9, tap=(75, 480)),    # capa que ondea
         dict(dur=0.68, f=(700, 3200, 1100), q=1.6, rub=1900, rub_g=0.45, wh=0.7, tap=(95, 760)),   # cuero y equipo
         dict(dur=0.52, f=(560, 2400, 800), q=1.3, rub=2700, rub_g=0.60, wh=0.8, tap=(110, 900))][v]  # rápida, sobre grava
    dur = p["dur"]
    n = sec(dur)
    y = np.zeros(n)
    place(y, _cloth_whoosh(rng, 0.42, 0.13, *p["f"], p["q"]), 0.0, p["wh"])
    # Roce con el suelo: ruido medio con grano, bajo y largo.
    nr = sec(0.34)
    rub = unit(bp2(noise(nr, rng, -3.0), p["rub"], 0.8)) * bump(nr, 1.1, 1.6) * np.clip(1.0 + 0.7 * smooth_noise(nr, rng, 95), 0.1, 2.2)
    place(y, rub, 0.06, p["rub_g"])
    # Contacto del hombro y el apoyo final.
    place(y, _foot_tap(rng, p["tap"][0], 0.04, p["tap"][1]), 0.07, 0.8)
    place(y, _foot_tap(rng, p["tap"][0] * 1.15, 0.03, p["tap"][1] * 1.3), dur - 0.17, 0.85)
    if v == 1:  # con el equipo colgado: unos pocos tintineos
        for t0 in rng.uniform(0.06, 0.34, 4):
            f0 = rng.uniform(1300, 3200)
            place(y, pk(modal(ms(180), [f0, f0 * 2.41], [0.06, 0.04], [1.0, 0.4], rng)), t0, 0.14)
    y = lp(y, 9500, 1)
    return taper(y, 0.07)


@sound("dodge", "dodge_step", 2, mix_db=-9.0, dur=(0.15, 0.5), grainy=True, pitch=1.06, vol_db=2.0)
def dodge_step(rng, v):
    """Paso atrás o salto corto: un corte de aire rápido, la salida del pie y el apoyo."""
    p = [dict(f=(600, 2600, 1000), q=1.4, land=0.165, tap=(105, 800), land_tap=(90, 650)),     # salto atrás corto
         dict(f=(420, 1500, 650), q=0.9, land=0.215, tap=(120, 1000), land_tap=(75, 480))][v]  # paso largo con capa
    n = sec(0.40)
    y = np.zeros(n)
    place(y, _cloth_whoosh(rng, 0.20, 0.07, *p["f"], p["q"], 0.04, 0.05), 0.0, 0.7)
    place(y, _foot_tap(rng, p["tap"][0], 0.022, p["tap"][1]), 0.0, 0.45)
    place(y, _foot_tap(rng, p["land_tap"][0], 0.030, p["land_tap"][1]), p["land"], 0.95)
    y = lp(y, 9500, 1)
    return taper(y, 0.05)


# ---------------------------------------------------------------------------
# Arco: tensar, soltar y flecha clavada
# ---------------------------------------------------------------------------

def _creak(n, rng, rate_a, rate_b, f1, f2):
    """Crujido de madera que se tensa: impulsos de «pegar y soltar» a un ritmo que sube, por dos resonancias."""
    t = tvec(n)
    rate = rate_a + (rate_b - rate_a) * (t / t[-1]) ** 1.3
    rate = rate * (1.0 + 0.25 * smooth_noise(n, rng, 9))
    phase = np.cumsum(rate) / SR
    idx = np.nonzero(np.diff(np.floor(phase)) > 0)[0]
    x = np.zeros(n)
    x[idx] = rng.uniform(0.3, 1.0, len(idx)) * rng.choice([-1.0, 1.0], len(idx))
    res = bp2(x, f1, 7.0) + 0.7 * bp2(x, f2, 6.0)
    # El crujido va a rachas, como la madera que se agarra y resbala.
    burst = np.clip(0.55 + 0.9 * smooth_noise(n, rng, 7), 0.0, 2.0)
    return unit(res) * burst


@sound("bow", "bow_draw", 2, mix_db=-9.0, dur=(0.5, 1.1), grainy=True, pitch=1.04, vol_db=2.0)
def bow_draw(rng, v):
    """Tensar el arco: crujido de la madera y la cuerda, cada vez más tenso, y el tope de la flecha al final."""
    dur = [0.78, 0.92][v]
    n = sec(dur)
    t = tvec(n)
    eff = smoothstep(t / dur) ** 0.8
    done = 1.0 - smoothstep((t - (dur - 0.22)) / 0.14)  # al llegar a la mejilla el arco deja de crujir
    y = _creak(n, rng, [38, 30][v], [92, 80][v], [840, 760][v] * rng.uniform(0.95, 1.05), [1750, 1500][v]) * (0.25 + 0.75 * eff) * done
    # Cuerda que roza los dedos: ruido agudo que sube con el esfuerzo.
    rub = unit(bp2(noise(n, rng), 2600.0 + 900.0 * eff, 4.0)) * eff ** 1.5 * done
    y = y + 0.16 * rub
    # Madera que se carga (grave, casi inaudible, da peso).
    y = y + 0.22 * unit(bp2(noise(n, rng, -3.0), 260.0 + 90.0 * eff, 1.4)) * eff
    # Tope: la flecha llega a la mano, un golpecito seco de madera.
    tick = pk(modal(ms(120), [980.0 * rng.uniform(0.95, 1.05), 1610.0], [0.03, 0.02], [1.0, 0.5], rng))
    place(y, tick, dur - 0.16, 0.9)
    return taper(y, 0.05)


@sound("bow", "bow_release", 3, mix_db=-4.0, dur=(0.2, 0.7), grainy=True, pitch=1.05, vol_db=2.0)
def bow_release(rng, v):
    """Soltar: el latigazo de la cuerda con su vibración, el golpe de las palas y el silbido de la flecha."""
    p = [dict(f0=185, t60=0.32, whoosh=0.40), dict(f0=162, t60=0.40, whoosh=0.30), dict(f0=215, t60=0.28, whoosh=0.45)][v]
    n = ms(600)
    f0 = _jit(rng, p["f0"], 0.04)
    hs = np.arange(1, 15)
    freqs = f0 * hs * (1.0 + 0.0006 * hs * hs)
    string = pk(modal(n, freqs, p["t60"] / np.sqrt(hs), 1.0 / hs ** 0.7, rng))
    snap = pk(hp(noise(n, rng), 2800, 2) * edecay(n, 0.004, 0.0001))
    limb = pk(sine_sweep(n, 150, 95, 0.015) * edecay(n, 0.030, 0.0012))
    wood = pk(modal(n, [430 * rng.uniform(0.95, 1.05), 780, 1330], [0.06, 0.045, 0.03], [1.0, 0.6, 0.35], rng))
    nw = ms(130)
    tw = tvec(nw)
    flight = unit(bp2(noise(nw, rng), 2400.0 + 2600.0 * (tw / tw[-1]), 1.6)) * bump(nw, 0.7, 2.0)
    y = 0.85 * string + 0.6 * snap + 0.8 * limb + 0.35 * wood
    place(y, flight, 0.008, p["whoosh"])
    y = sat(hp(y, 70, 2), 1.5)
    return taper(y, 0.12)


@sound("arrow", "arrow_hit_flesh", 3, mix_db=-2.0, dur=(0.15, 0.5), grainy=True, pitch=1.05, vol_db=2.0)
def arrow_hit_flesh(rng, v):
    """Flecha en carne: «thump» húmedo y corto, un chasquido de cuero y la vibración del asta."""
    p = [dict(f0=150, slap=950, shaft=520), dict(f0=125, slap=800, shaft=440), dict(f0=170, slap=1150, shaft=610)][v]
    n = ms(380)
    thump = pk(sine_sweep(n, p["f0"], p["f0"] * 0.55, 0.014) * edecay(n, 0.030, 0.001))
    slap = pk(bp2(noise(n, rng, -3.0), _jit(rng, p["slap"], 0.1), 0.9) * edecay(n, 0.022, 0.0005))
    thwip = pk(hp(noise(n, rng), 2400, 2) * edecay(n, 0.007, 0.0001))
    sh = _jit(rng, p["shaft"], 0.05)
    t = tvec(n)
    shaft = pk(modal(n, [sh, sh * 2.31, sh * 4.1], [0.10, 0.06, 0.03], [1.0, 0.5, 0.25], rng) * (1.0 + 0.6 * np.sin(2 * np.pi * 42 * t)))
    y = 0.40 * thump + 1.0 * slap + 0.60 * thwip + 0.28 * shaft
    y = sat(hp(y, 60, 2), 1.7)
    return taper(lp(y, 9000, 1), 0.06)


@sound("arrow", "arrow_hit_wood", 2, mix_db=-2.0, dur=(0.2, 0.7), grainy=True, pitch=1.05, vol_db=2.0)
def arrow_hit_wood(rng, v):
    """Flecha en madera (puerta, escudo, empalizada): golpe seco y el «zing» del asta que vibra clavada."""
    p = [dict(f=520, shaft=730), dict(f=640, shaft=860)][v]
    n = ms(600)
    t = tvec(n)
    wood = pk(modal(n, [p["f"] * rng.uniform(0.95, 1.05) * r for r in (1.0, 1.63, 2.38)], [0.08, 0.06, 0.04], [1.0, 0.7, 0.45], rng))
    knock = pk(bp2(noise(n, rng), 2000, 1.0) * edecay(n, 0.005, 0.0001))
    thump = pk(sine_sweep(n, 140, 85, 0.02) * edecay(n, 0.025, 0.001))
    sh = _jit(rng, p["shaft"], 0.04)
    shaft = pk(modal(n, [sh, sh * 2.2, sh * 3.6], [0.32, 0.20, 0.12], [1.0, 0.5, 0.3], rng) * (1.0 + 0.5 * np.sin(2 * np.pi * 47 * t)))
    y = 0.85 * wood + 0.7 * knock + 0.22 * thump + 0.32 * shaft
    y = sat(y, 1.6)
    return taper(lp(y, 10000, 1), 0.08)
