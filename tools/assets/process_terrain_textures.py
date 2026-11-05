"""Processes the terrain's CC0 Poly Haven textures (ART-55).

Input: ../Eldmark-raw/texturas_polyhaven_2k/extracted/<id>/<id>_{diff,nor_gl,rough,disp,ao}_2k.*
Output: assets/textures/terrain/polyhaven/<id>_alb_ht.png (desaturated albedo, with the height in the
alpha, as Terrain3D requires) and <id>_nrm_rough.png (OpenGL normal, with the roughness in the alpha), at
1024 x 1024 for the albedo and 512 x 512 for the normal (each family of the same size, a Terrain3D requirement; the
normal at 512 so that the server package, which carries every resource in the repo, stays under the 35 MB
of tests/test_export_config.gd).

Style (docs/art.md): stylized and muted, so it is desaturated, the contrast is compressed a little
and part of the ambient occlusion is baked into the color. Usage: python tools/assets/process_terrain_textures.py
"""
import os
import sys
from pathlib import Path

import numpy as np
from PIL import Image



def find_raw() -> Path:
    """Folder of the original textures: the ELDMARK_RAW environment variable (which points to Eldmark-raw) or, if it is not
    set, the first Eldmark-raw found in the repo's parent directories."""
    sub = Path("texturas_polyhaven_2k") / "extracted"
    if os.environ.get("ELDMARK_RAW"):
        return Path(os.environ["ELDMARK_RAW"]) / sub
    for parent in Path(__file__).resolve().parents:
        if (parent / "Eldmark-raw").is_dir():
            return parent / "Eldmark-raw" / sub
    return Path(__file__).resolve().parents[3] / "Eldmark-raw" / sub


RAW = find_raw()
OUT = Path(__file__).resolve().parents[2] / "assets" / "textures" / "terrain" / "polyhaven"
SIZE = 1024
NORMAL_SIZE = 512

# id: (saturation, brightness, contrast, share of AO in the color, normal strength)
SETS: dict[str, tuple[float, float, float, float, float]] = {
    "grass_ground": (0.62, 0.95, 0.9, 0.5, 1.0),
    "dirt_floor": (0.55, 0.9, 0.9, 0.5, 1.0),
    "ground_grey": (0.5, 1.0, 0.85, 0.5, 1.0),
    "rock_boulder_dry": (0.5, 0.95, 0.9, 0.6, 1.3),
    "rocky_trail": (0.5, 0.95, 0.9, 0.5, 1.0),
    "damp_beach_sand": (0.5, 0.82, 0.9, 0.5, 1.0),
    "snow_02": (0.45, 1.0, 0.8, 0.4, 1.0),
    "forest_ground_06": (0.55, 0.85, 0.9, 0.5, 1.0),
}


def load(set_id: str, kind: str, ext: str, mode: str, size: int = SIZE) -> np.ndarray:
    path = RAW / set_id / f"{set_id}_{kind}_2k.{ext}"
    image = Image.open(path)
    if image.mode.startswith("I;16") or image.mode == "I":
        array = np.asarray(image, dtype=np.float32) / 65535.0
        image = Image.fromarray(np.clip(array * 255.0, 0, 255).astype(np.uint8))
    image = image.convert(mode).resize((size, size), Image.LANCZOS)
    return np.asarray(image, dtype=np.float32) / 255.0


def process(set_id: str, sat: float, bright: float, contrast: float, ao_share: float, normal_strength: float) -> None:
    diffuse = load(set_id, "diff", "jpg", "RGB")
    ao = load(set_id, "ao", "jpg", "L")[..., None]
    height = load(set_id, "disp", "png", "L")
    rough = load(set_id, "rough", "jpg", "L", NORMAL_SIZE)
    normal = load(set_id, "nor_gl", "png", "RGB", NORMAL_SIZE)

    luma = (diffuse * np.array([0.299, 0.587, 0.114], dtype=np.float32)).sum(axis=2, keepdims=True)
    color = luma + (diffuse - luma) * sat
    mean = color.mean()
    color = (color - mean) * contrast + mean
    color = color * bright * (1.0 - ao_share + ao_share * ao)
    color = np.clip(color, 0.0, 1.0)

    lo, hi = np.percentile(height, [2, 98])
    height = np.clip((height - lo) / max(hi - lo, 1e-4), 0.0, 1.0)

    vec = normal * 2.0 - 1.0
    vec[..., 0:2] *= normal_strength
    length = np.sqrt((vec ** 2).sum(axis=2, keepdims=True))
    vec = vec / np.maximum(length, 1e-4)
    normal = vec * 0.5 + 0.5

    alb = np.concatenate([color, height[..., None]], axis=2)
    nrm = np.concatenate([normal, np.clip(rough, 0.0, 1.0)[..., None]], axis=2)
    OUT.mkdir(parents=True, exist_ok=True)
    Image.fromarray((alb * 255.0 + 0.5).astype(np.uint8), "RGBA").save(OUT / f"{set_id}_alb_ht.png", optimize=True)
    Image.fromarray((nrm * 255.0 + 0.5).astype(np.uint8), "RGBA").save(OUT / f"{set_id}_nrm_rough.png", optimize=True)
    print("ok", set_id)


if __name__ == "__main__":
    only = sys.argv[1:]
    for key, params in SETS.items():
        if not only or key in only:
            process(key, *params)
