"""Quita la cuña del cuello del traje Ranger que asoma por la nuca de la cabeza Superhero.

El traje Male_Ranger (Modular Character Outfits - Fantasy) está pensado para el cuerpo Regular;
con la cabeza Superhero que usa Eldmark, la parte trasera del cuello de Male_Ranger_Body sube por
encima del borde del jubón (y = 1,52-1,60 m) por fuera de la piel de la nuca y se ve como una
cuña parda justo donde mira la cámara al hombro. Ese trozo queda siempre dentro o detrás del
cuello de la cabeza, así que sus triángulos se anulan (los tres índices apuntan al mismo
vértice: triángulo degenerado, que no se dibuja). No se mueven vértices ni cambia el número de
índices: solo cambia el búfer de índices de Male_Ranger_Body en Male_Ranger.bin.

Es idempotente (repetirlo no cambia nada). Uso, desde la raíz del repo:

    python -I tools/assets/fix_ranger_collar.py

Después hay que forzar la reimportación del .gltf (Godot no vigila el .bin): borrar
.godot/imported/Male_Ranger.gltf-* y ejecutar godot --headless --path . --import.
"""

import json
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUTFIT = ROOT / "assets/models/characters/outfits/ranger/Male_Ranger"
BODY_MESH = "Male_Ranger_Body"
# Zona de la cuña: por encima del borde del cuello del jubón (y = 1,506-1,509, que se queda
# porque tapa la costura de la cabeza), en la mitad trasera (el modelo mira hacia +Z) y cerca
# del eje.
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
