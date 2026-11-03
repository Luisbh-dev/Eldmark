#!/usr/bin/env python
"""Une los fotogramas sueltos de las tiras (anim_strips.gd y strip_recorder.gd) en rejillas de 4 x 3 con rótulos.

Entrada: <raw>/<accion>/<ventana>/{game,side,front}_NN.png y meta.json.
Salida:  <out>/animacion/<vista>/<accion>[__<ventana>].png con vista en
         camara_juego, lado y frente (sandbox y tiras del jugador local) y remoto y remoto_lado (tiras `rem_*`,
         vistas desde otro cliente de verdad: cámara del juego y cámara lateral propia).

Cada celda lleva su rótulo: nº de fotograma, tiempo (s), acción de combate de la simulación y, en la segunda línea,
el clip de combate que enseña la capa de animación con su instante y su velocidad (o la velocidad del personaje, o la
fase de aire). Una tira vista desde otro cliente marca los fotogramas con otro cuerpo delante (TAPADO) y los golpes
que el cliente vio en ese intervalo (BLOQUEADO, PARADA, GOLPE...).

Uso: python compose_strips.py <raw> <out> [--only=a,b] [--prefix=npc_]
"""
import json
import os
import sys

from PIL import Image, ImageDraw, ImageFont

# clave del fotograma, carpeta de salida, nombre de la vista en el subtítulo
VIEWS = [
    ("game", "camara_juego", "cámara del juego"),
    ("side", "lado", "de lado"),
    ("front", "frente", "de frente"),
]
# Las tiras de otro cliente (rem_*) van a sus propias carpetas.
REMOTE_VIEWS = [
    ("game", "remoto", "cámara del juego siguiendo al remoto"),
    ("side", "remoto_lado", "cámara lateral propia sobre el remoto"),
]
COLS = 4
HEADER = 64
LABEL_H = 40
PAD = 4


def _font(size):
    for name in ("segoeui.ttf", "arial.ttf", "DejaVuSans.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default()


F_HEAD = _font(22)
F_SUB = _font(15)
F_CELL = _font(14)


def views_for(act_id):
    return REMOTE_VIEWS if act_id.startswith("rem_") else VIEWS


def _cell_lines(fr):
    """Las dos líneas de rótulo de un fotograma."""
    first = "%d  t=%.2fs  %s" % (fr["k"] + 1, fr["t"], fr["action"])
    clip = fr.get("clip") or ""
    if clip:
        second = "%s@%.2f" % (clip.split("/")[-1], fr.get("clip_t", 0.0))
        if fr.get("clip_speed"):
            second += "  x%.2f" % fr["clip_speed"]
    elif fr.get("air") and fr["air"] != "GROUNDED":
        second = "aire:%s" % fr["air"]
    else:
        second = "sin clip de combate  v=%.1f" % fr.get("speed", 0.0)
    return first, second


def compose(raw_dir, out_dir, act_id, win_name):
    base = os.path.join(raw_dir, act_id, win_name)
    meta_path = os.path.join(base, "meta.json")
    if not os.path.exists(meta_path):
        return []
    with open(meta_path, encoding="utf-8") as fh:
        meta = json.load(fh)
    frames = meta["frames"]
    n = len(frames)
    written = []
    for key, folder, view_name in views_for(act_id):
        first = os.path.join(base, "%s_%02d.png" % (key, 0))
        if not os.path.exists(first):
            continue
        im0 = Image.open(first).convert("RGB")
        cw, ch = im0.size
        rows = (n + COLS - 1) // COLS
        sheet = Image.new("RGB", (COLS * cw + (COLS + 1) * PAD, HEADER + rows * (ch + PAD) + PAD), (18, 18, 20))
        d = ImageDraw.Draw(sheet)
        title = "%s%s" % (meta.get("title", act_id), "" if win_name in ("ciclo", "") else "  [%s]" % win_name)
        d.text((10, 6), title, font=F_HEAD, fill=(240, 240, 240))
        t0 = frames[0]["t"]
        t1 = frames[-1]["t"]
        sub = "vista: %s  |  %d fotogramas, t=%.2f-%.2f s (%d ticks)  |  arma: %s" % (
            view_name, n, t0, t1, frames[-1]["rt"] - frames[0]["rt"], meta.get("weapon", ""))
        d.text((10, 34), sub, font=F_SUB, fill=(170, 200, 230))
        if meta.get("note"):
            d.text((sheet.width - 10 - d.textlength(meta["note"], font=F_SUB), 34), meta["note"], font=F_SUB, fill=(200, 190, 140))
        for i, fr in enumerate(frames):
            p = os.path.join(base, "%s_%02d.png" % (key, i))
            im = Image.open(p).convert("RGB")
            x = PAD + (i % COLS) * (cw + PAD)
            y = HEADER + (i // COLS) * (ch + PAD)
            sheet.paste(im, (x, y))
            d.rectangle([x, y + ch - LABEL_H, x + cw, y + ch], fill=(0, 0, 0))
            line1, line2 = _cell_lines(fr)
            d.text((x + 4, y + ch - LABEL_H + 3), line1, font=F_CELL, fill=(255, 255, 255))
            d.text((x + 4, y + ch - LABEL_H + 21), line2, font=F_CELL, fill=(190, 220, 255))
            tags = []
            if key == "game" and fr.get("occluded"):
                tags.append(("TAPADO", (255, 150, 90)))
            if fr.get("hit"):
                tags.append((fr["hit"], (255, 220, 90)))
            tx = x + cw - 6
            for text, color in tags:
                w = d.textlength(text, font=F_CELL)
                tx -= w
                d.text((tx, y + ch - LABEL_H + 3), text, font=F_CELL, fill=color)
                tx -= 8
        sub_dir = os.path.join(out_dir, "animacion", folder)
        os.makedirs(sub_dir, exist_ok=True)
        name = act_id if win_name in ("ciclo", "") else "%s__%s" % (act_id, win_name)
        sheet.save(os.path.join(sub_dir, name + ".png"), optimize=False, compress_level=4)
        written.append(os.path.join("animacion", folder, name + ".png").replace("\\", "/"))
        print("ok", folder, name)
    return written


def compose_all(raw_dir, out_dir, only=None, prefix=None):
    """Compone todas las tiras de [raw_dir] (o solo las de [only] / con [prefix]). Devuelve las rutas escritas."""
    written = []
    if not os.path.isdir(raw_dir):
        return written
    for act_id in sorted(os.listdir(raw_dir)):
        if only and act_id not in only:
            continue
        if prefix and not act_id.startswith(prefix):
            continue
        adir = os.path.join(raw_dir, act_id)
        if not os.path.isdir(adir):
            continue
        for win in sorted(os.listdir(adir)):
            if os.path.isdir(os.path.join(adir, win)):
                written.extend(compose(raw_dir, out_dir, act_id, win))
    return written


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    raw_dir, out_dir = argv[1], argv[2]
    only = set()
    prefix = None
    for a in argv[3:]:
        if a.startswith("--only="):
            only = set(a[7:].split(","))
        elif a.startswith("--prefix="):
            prefix = a[9:]
    compose_all(raw_dir, out_dir, only or None, prefix)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
