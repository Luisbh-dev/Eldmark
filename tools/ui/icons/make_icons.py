#!/usr/bin/env python3
"""Generates the interface icons (ART-12): SVG layers, painting and backgrounds.

The icons are loose shapes (PNG with a transparent background) plus a background per category that the slot
draws underneath. Everything is Eldmark's own content, made by code: there is nothing third-party.

Two steps, with the engine's rasteriser in between (`build_icons.sh` chains them):

    python3 tools/ui/icons/make_icons.py layers   # draws the shapes and writes the SVG layers
    godot --headless --path . -s res://tools/ui/icons/rasterize_icons.gd
    python3 tools/ui/icons/make_icons.py paint    # composes, paints and writes the PNGs in assets/

Output:
    assets/ui/icons/<name>.png              128 px shape, no background (large: bars, inventory)
    assets/ui/icons/small/<state>_14.png    small variant of the states, at the exact size of
    assets/ui/icons/small/<state>_26.png    StatusIcons (18 and 30 px minus a 2 px border per side)
    assets/ui/icons/backgrounds/<cat>.png   128 px backgrounds per category, full-bleed and frameless

The intermediate layers go to build/iconos/capas (Git ignores them). Icon names can be passed at the
end to regenerate only those.
"""

import json
import os
import shutil
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import glyphs  # noqa: E402
import paint  # noqa: E402
import svgkit  # noqa: E402

ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
ASSETS = os.path.join(ROOT, "assets", "ui", "icons")
LAYERS = os.path.join(ROOT, "build", "iconos", "capas")
MANIFEST = os.path.join(LAYERS, "manifest.json")

BIG_SIDE = 256       # rasterisation side of the large icons (downscaled to 128)
FINAL_SIDE = 128
SMALL_SIZES = (14, 26)   # native sides of the small states
SMALL_SS = 6             # supersampling factor of the small ones
SMALL_OW = {14: 2.6, 26: 2.0}   # outline proportionally thicker the smaller it is
SMALL_FILL = 0.90        # fraction of the square that the shape fills (outline included)


def seed_of(name):
    return zlib.crc32(name.encode("utf-8"))


def _write_layers(job_name, shapes, side, fit, ow_scale=1.0, shadow=1.0):
    folder = os.path.join(LAYERS, job_name)
    os.makedirs(folder, exist_ok=True)
    entries = []
    for i, layer in enumerate(svgkit.layers(shapes, side, fit, ow_scale, shadow)):
        stem = "%02d_%s" % (i, layer["kind"])
        with open(os.path.join(folder, stem + ".svg"), "w", encoding="utf-8", newline="\n") as handle:
            handle.write(layer["svg"])
        meta = {k: v for k, v in layer.items() if k != "svg"}
        meta["png"] = "%s/%s.png" % (job_name, stem)
        entries.append(meta)
    return entries


def build_layers(only):
    if os.path.isdir(LAYERS) and not only:
        shutil.rmtree(LAYERS)
    os.makedirs(LAYERS, exist_ok=True)
    manifest = {"jobs": []}
    if only and os.path.exists(MANIFEST):
        with open(MANIFEST, encoding="utf-8") as handle:
            manifest = json.load(handle)
        manifest["jobs"] = [j for j in manifest["jobs"] if j["base"] not in only]
    for name, (category, title, builder) in glyphs.ICONS.items():
        if only and name not in only:
            continue
        shapes = builder()
        fit = svgkit.fit_transform(shapes, **glyphs.FIT.get(name, {}))
        bbox, cover = svgkit.measure(shapes)
        manifest["jobs"].append({
            "name": name, "base": name, "category": category, "title": title, "small": False,
            "res": BIG_SIDE, "final": FINAL_SIDE, "fit": fit, "cover_raw": round(cover, 3),
            "out": os.path.relpath(os.path.join(ASSETS, name + ".png"), ROOT).replace("\\", "/"),
            "layers": _write_layers(name, shapes, BIG_SIDE, fit),
        })
    for name, (category, title, builder) in glyphs.SMALL_ICONS.items():
        if only and name not in only:
            continue
        for size in SMALL_SIZES:
            shapes = builder()
            ow_scale = SMALL_OW[size]
            fit = svgkit.fit_square(shapes, SMALL_FILL, ow_scale)
            res = size * SMALL_SS
            job = "%s_%d" % (name, size)
            manifest["jobs"].append({
                "name": job, "base": name, "category": category, "title": title, "small": True,
                "res": res, "final": size, "fit": fit, "cover_raw": 0.0,
                "out": os.path.relpath(os.path.join(ASSETS, "small", job + ".png"), ROOT).replace("\\", "/"),
                "layers": _write_layers(job, shapes, res, fit, ow_scale, 0.5),
            })
    with open(MANIFEST, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(manifest, handle, indent=1)
    print("%d trabajos de capas en %s" % (len(manifest["jobs"]), LAYERS))


def build_paint(only):
    with open(MANIFEST, encoding="utf-8") as handle:
        manifest = json.load(handle)
    os.makedirs(os.path.join(ASSETS, "small"), exist_ok=True)
    os.makedirs(os.path.join(ASSETS, "backgrounds"), exist_ok=True)
    count = 0
    for job in manifest["jobs"]:
        if only and job["base"] not in only:
            continue
        img = paint.paint_figure(job, LAYERS, job["res"], seed_of(job["name"]), job["small"])
        img = paint.reduce(img, job["final"])
        out = os.path.join(ROOT, job["out"])
        img.save(out)
        count += 1
    print("%d figuras pintadas" % count)
    if not only:
        for category in svgkit.CATEGORIES:
            paint.make_tile(category, 128).save(os.path.join(ASSETS, "backgrounds", category + ".png"))
        print("%d fondos" % len(svgkit.CATEGORIES))


def main(argv):
    if len(argv) < 2 or argv[1] not in ("layers", "paint"):
        print(__doc__)
        return 1
    only = set(argv[2:])
    if argv[1] == "layers":
        build_layers(only)
    else:
        build_paint(only)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
