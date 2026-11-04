"""Extracts only the head (and neck) from Quaternius's full Superhero_Male body.

The Modular Character Outfits README says that with clothing only the base body's head is
needed: the whole body clips through the clothes. The Standard version of Universal Base
Characters only ships full bodies, so the body mesh is cut down here, keeping the
triangles whose vertices are weighted mostly to the head/neck bones.

Usage: python -I split_head.py <input.gltf> <output.gltf> [weight threshold, 0.2 by default]
"""
import json, os, struct, sys

COMP_SIZE = {5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4}
COMP_FMT = {5120: 'b', 5121: 'B', 5122: 'h', 5123: 'H', 5125: 'I', 5126: 'f'}
NCOMP = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4, 'MAT4': 16}

BODY_NODE = 'SuperHero_Male'
KEEP_BONES = ('Head', 'neck_01')
IMAGE_URI_FIXES = {
    'T_Hair_1_Normal_png.png': 'T_Hair_1_Normal.png',
    'T_Eye_Normal_png.png': 'T_Eye_Normal.png',
}


def accessor_bytes(js, binbuf, idx):
    a = js['accessors'][idx]
    bv = js['bufferViews'][a['bufferView']]
    csize = COMP_SIZE[a['componentType']]
    n = NCOMP[a['type']]
    elem = csize * n
    stride = bv.get('byteStride', elem)
    base = bv.get('byteOffset', 0) + a.get('byteOffset', 0)
    return [binbuf[base + i * stride: base + i * stride + elem] for i in range(a['count'])]


def unpack(js, idx, raw):
    a = js['accessors'][idx]
    fmt = '<' + COMP_FMT[a['componentType']] * NCOMP[a['type']]
    return [struct.unpack(fmt, r) for r in raw]


def main(src, dst, threshold):
    with open(src, 'r', encoding='utf-8') as f:
        js = json.load(f)
    with open(os.path.join(os.path.dirname(src), js['buffers'][0]['uri']), 'rb') as f:
        binbuf = f.read()

    nodes = js['nodes']
    skin = js['skins'][0]
    joint_names = [nodes[j]['name'] for j in skin['joints']]
    keep_joints = {joint_names.index(b) for b in KEEP_BONES}

    body_node = next(n for n in nodes if n.get('name') == BODY_NODE)
    mesh = js['meshes'][body_node['mesh']]
    assert len(mesh['primitives']) == 1
    prim = mesh['primitives'][0]
    attrs = prim['attributes']

    joints = unpack(js, attrs['JOINTS_0'], accessor_bytes(js, binbuf, attrs['JOINTS_0']))
    weights = unpack(js, attrs['WEIGHTS_0'], accessor_bytes(js, binbuf, attrs['WEIGHTS_0']))
    head_weight = []
    for jv, wv in zip(joints, weights):
        head_weight.append(sum(w for j, w in zip(jv, wv) if j in keep_joints))

    indices = [v[0] for v in unpack(js, prim['indices'], accessor_bytes(js, binbuf, prim['indices']))]
    kept_tris = []
    for t in range(0, len(indices), 3):
        tri = indices[t:t + 3]
        if all(head_weight[v] >= threshold for v in tri):
            kept_tris.append(tri)
    used = sorted({v for tri in kept_tris for v in tri})
    remap = {old: new for new, old in enumerate(used)}
    print('vértices %d -> %d, triángulos %d -> %d' % (
        len(head_weight), len(used), len(indices) // 3, len(kept_tris)))

    # New buffer: all the accessors still in use are copied, compacting the body's.
    out = bytearray()
    new_views = []
    new_accessors = []

    def add_accessor(src_idx, raw_elems, target, minmax=None):
        a = dict(js['accessors'][src_idx])
        while len(out) % 4:
            out.append(0)
        offset = len(out)
        for r in raw_elems:
            out.extend(r)
        view = {'buffer': 0, 'byteOffset': offset, 'byteLength': len(out) - offset}
        if target:
            view['target'] = target
        new_views.append(view)
        a['bufferView'] = len(new_views) - 1
        a.pop('byteOffset', None)
        a['count'] = len(raw_elems)
        if minmax is not None:
            a['min'], a['max'] = minmax
        new_accessors.append(a)
        return len(new_accessors) - 1

    for m in js['meshes']:
        for p in m['primitives']:
            is_body = p is prim
            new_attrs = {}
            for name, idx in p['attributes'].items():
                raw = accessor_bytes(js, binbuf, idx)
                minmax = None
                if is_body:
                    raw = [raw[v] for v in used]
                if name == 'POSITION':
                    vals = unpack(js, idx, raw)
                    minmax = ([min(v[k] for v in vals) for k in range(3)],
                              [max(v[k] for v in vals) for k in range(3)])
                new_attrs[name] = add_accessor(idx, raw, 34962, minmax)
            p['attributes'] = new_attrs
            raw_idx = accessor_bytes(js, binbuf, p['indices'])
            if is_body:
                ctype = js['accessors'][p['indices']]['componentType']
                fmt = '<' + COMP_FMT[ctype]
                raw_idx = [struct.pack(fmt, remap[v]) for tri in kept_tris for v in tri]
            p['indices'] = add_accessor(p['indices'], raw_idx, 34963)
            for key in ('targets',):
                assert key not in p
    for s in js['skins']:
        raw = accessor_bytes(js, binbuf, s['inverseBindMatrices'])
        s['inverseBindMatrices'] = add_accessor(s['inverseBindMatrices'], raw, None)
    assert not js.get('animations')

    js['accessors'] = new_accessors
    js['bufferViews'] = new_views
    bin_name = os.path.splitext(os.path.basename(dst))[0] + '.bin'
    js['buffers'] = [{'byteLength': len(out), 'uri': bin_name}]
    for im in js.get('images', []):
        im['uri'] = IMAGE_URI_FIXES.get(im['uri'], im['uri'])
    # The node keeps its name (SuperHero_Male): if it were named the same as the file, Godot
    # would rename the root of the imported scene.
    mesh['name'] = 'SuperHero_Male_Head'
    js['asset']['extras'] = {
        'eldmark': 'Cabeza recortada de Superhero_Male_FullBody (Quaternius, CC0) por split_head.py',
    }
    with open(os.path.join(os.path.dirname(dst), bin_name), 'wb') as f:
        f.write(out)
    with open(dst, 'w', encoding='utf-8', newline='\n') as f:
        json.dump(js, f, indent=1)
        f.write('\n')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2], float(sys.argv[3]) if len(sys.argv) > 3 else 0.2)
