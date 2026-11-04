"""Removes the neck wedge of the Ranger outfit that peeks out at the nape of the Superhero head.

The Male_Ranger outfit (Modular Character Outfits - Fantasy) is designed for the Regular body;
with the Superhero head that Eldmark uses, the back of Male_Ranger_Body's neck rises above
the edge of the doublet (y = 1.52-1.60 m) on the outside of the nape skin and shows up as a
brown wedge right where the over-the-shoulder camera looks. That piece is always inside or behind the
head's neck, so its triangles are nullified (all three indices point to the same
vertex: a degenerate triangle, which is not drawn). No vertices are moved and the number of
indices does not change: only Male_Ranger_Body's index buffer in Male_Ranger.bin changes.

It is idempotent (repeating it changes nothing). Usage, from the repo root:

    python -I tools/assets/fix_ranger_collar.py

Afterwards you have to force a re-import of the .gltf (Godot does not watch the .bin): delete
.godot/imported/Male_Ranger.gltf-* and run godot --headless --path . --import.
"""

import json
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUTFIT = ROOT / "assets/models/characters/outfits/ranger/Male_Ranger"
BODY_MESH = "Male_Ranger_Body"
# Wedge zone: above the edge of the doublet's collar (y = 1.506-1.509, which stays
# because it covers the head seam), in the back half (the model faces +Z) and near
# the axis.
MIN_Y = 1.513
MAX_Z = -0.06
MAX_ABS_X = 0.08


def accessor(gltf, data, index):
    acc = gltf["accessors"][index]
    view = gltf["bufferViews"][acc["bufferView"]]
    offset = view.get("byteOffset", 0) + acc.get("byteOffset", 0)
    return acc, view, offset


def main() -> int:
    gltf = json.loads(OUTFIT.with_suffix(".gltf").read_text(encoding="utf-8"))
    data = bytearray(OUTFIT.with_suffix(".bin").read_bytes())
    mesh = next(m for m in gltf["meshes"] if m["name"] == BODY_MESH)
    primitive = mesh["primitives"][0]
    pos_acc, pos_view, pos_offset = accessor(gltf, data, primitive["attributes"]["POSITION"])
    stride = pos_view.get("byteStride", 12)
    positions = [struct.unpack_from("<3f", data, pos_offset + k * stride) for k in range(pos_acc["count"])]
    idx_acc, _, idx_offset = accessor(gltf, data, primitive["indices"])
    fmt = {5123: "H", 5125: "I"}[idx_acc["componentType"]]
    size = struct.calcsize(fmt)

    def in_wedge(k: int) -> bool:
        x, y, z = positions[k]
        return y > MIN_Y and z < MAX_Z and abs(x) < MAX_ABS_X

    removed = 0
    for t in range(idx_acc["count"] // 3):
        base = idx_offset + t * 3 * size
        tri = struct.unpack_from("<3" + fmt, data, base)
        if tri[0] == tri[1] == tri[2]:
            continue
        if all(in_wedge(k) for k in tri):
            struct.pack_into("<3" + fmt, data, base, tri[0], tri[0], tri[0])
            removed += 1
    if removed:
        OUTFIT.with_suffix(".bin").write_bytes(bytes(data))
    print("Triángulos anulados: %d" % removed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
