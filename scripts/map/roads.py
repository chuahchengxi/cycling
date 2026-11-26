"""Bundled road network for offline routing: cyclable OSM ways in Singapore as a
compact directed graph. Build time only; see extract.py for the input.

    python -I scripts/map/roads.py layers.pickle

Output cyclingskibidi/roads.bin, little-endian (must match RoadGraph.swift):
    "RDG1", n:u32, m:u32,
    lat:i32[n] lon:i32[n] (degrees * 1e6), first:u32[n+1] (CSR row starts),
    to:u32[m], len:u16[m] (half-metres), cls:u8[m]
Classes: 0 cycleway, 1 path/footway, 2 minor road, 3 tertiary, 4 secondary,
5 primary, 6 trunk. Expressways and steps are left out: no cycling there.
"""
import math, os, pickle, struct, sys   # pickle: our own extract.py output, never downloaded
from collections import defaultdict

OUT = os.path.join(os.path.dirname(__file__), "../../cyclingskibidi/roads.bin")
CLASS = {"cycleway": 0, "footway": 1, "path": 1, "pedestrian": 1, "track": 1, "bridleway": 1,
         "living_street": 2, "residential": 2, "service": 2, "unclassified": 2,
         "tertiary": 3, "tertiary_link": 3, "secondary": 4, "secondary_link": 4,
         "primary": 5, "primary_link": 5, "trunk": 6, "trunk_link": 6}
SIMPLIFY_M = 2.0      # Douglas-Peucker tolerance between junctions
MIN_COMPONENT = 50    # drop islands of road too small to route on

def metres(a, b):
    dl = math.radians(b[1] - a[1]); dn = math.radians(b[0] - a[0])
    h = math.sin(dl / 2) ** 2 + math.cos(math.radians(a[1])) * math.cos(math.radians(b[1])) * math.sin(dn / 2) ** 2
    return 2 * 6371008.8 * math.asin(math.sqrt(h))

def rdp(pts, tol):
    """Indices to keep from pts (lon,lat), first and last always."""
    if len(pts) < 3: return list(range(len(pts)))
    k = math.cos(math.radians(pts[0][1])) * 111195
    xy = [(p[0] * k, p[1] * 111195) for p in pts]
    keep, stack = {0, len(pts) - 1}, [(0, len(pts) - 1)]
    while stack:
        i, j = stack.pop()
        (x1, y1), (x2, y2) = xy[i], xy[j]
        dx, dy = x2 - x1, y2 - y1
        L = math.hypot(dx, dy) or 1e-9
        best, bi = 0, None
        for t in range(i + 1, j):
            d = abs(dy * (xy[t][0] - x1) - dx * (xy[t][1] - y1)) / L
            if d > best: best, bi = d, t
        if bi is not None and best > tol:
            keep.add(bi); stack += [(i, bi), (bi, j)]
    return sorted(keep)

def rideable(tags):
    """Whether a way may be cycled: a road class we route on, not an area, and
    not tagged bicycle=no or private access (unless bicycles are explicitly let in)."""
    hw = tags.get("highway")
    if hw not in CLASS or tags.get("area") == "yes": return False
    if tags.get("bicycle") == "no": return False
    if tags.get("access") in ("private", "no") and tags.get("bicycle") not in ("yes", "designated"): return False
    return True

def main():
    L = pickle.load(open(sys.argv[1], "rb"))
    ways = []
    for tags, pts, refs in L["roads"]:
        if not rideable(tags): continue
        c = CLASS[tags["highway"]]
        ow = tags.get("oneway", "no")
        if c < 2 or tags.get("oneway:bicycle") == "no": ow = "no"
        ways.append((c, ow, pts, refs))

    uses = defaultdict(int)
    for _, _, _, refs in ways:
        for i, r in enumerate(refs):
            uses[r] += 2 if i in (0, len(refs) - 1) else 1

    index, coords = {}, []
    def node(ref, p):
        if ref not in index:
            index[ref] = len(coords); coords.append(p)
        return index[ref]

    edges = []   # (a, b, half-metres, cls)
    for c, ow, pts, refs in ways:
        cut = [0] + [i for i in range(1, len(refs) - 1) if uses[refs[i]] > 1] + [len(refs) - 1]
        for s, e in zip(cut, cut[1:]):
            keep = [s + k for k in rdp(pts[s:e + 1], SIMPLIFY_M)]
            for i, j in zip(keep, keep[1:]):
                a, b = node(refs[i], pts[i]), node(refs[j], pts[j])
                if a == b: continue
                d = min(65535, round(sum(metres(pts[t], pts[t + 1]) for t in range(i, j)) * 2))
                if ow in ("yes", "true", "1"): edges.append((a, b, d, c))
                elif ow == "-1": edges.append((b, a, d, c))
                else: edges += [(a, b, d, c), (b, a, d, c)]

    # Keep components big enough to route on (undirected connectivity).
    adj = defaultdict(list)
    for a, b, _, _ in edges: adj[a].append(b); adj[b].append(a)
    comp, sizes = {}, []
    for s in range(len(coords)):
        if s in comp or s not in adj: continue
        cid, stack, n = len(sizes), [s], 0
        comp[s] = cid
        while stack:
            u = stack.pop(); n += 1
            for v in adj[u]:
                if v not in comp: comp[v] = cid; stack.append(v)
        sizes.append(n)
    alive = [comp.get(i) is not None and sizes[comp[i]] >= MIN_COMPONENT for i in range(len(coords))]
    remap, kept = {}, []
    for i, ok in enumerate(alive):
        if ok: remap[i] = len(kept); kept.append(coords[i])
    edges = sorted((remap[a], remap[b], d, c) for a, b, d, c in edges if alive[a] and alive[b])

    n, m = len(kept), len(edges)
    first = [0] * (n + 1)
    for a, _, _, _ in edges: first[a + 1] += 1
    for i in range(n): first[i + 1] += first[i]
    with open(OUT, "wb") as f:
        f.write(b"RDG1" + struct.pack("<II", n, m))
        f.write(struct.pack(f"<{n}i", *[round(p[1] * 1e6) for p in kept]))
        f.write(struct.pack(f"<{n}i", *[round(p[0] * 1e6) for p in kept]))
        f.write(struct.pack(f"<{n + 1}I", *first))
        f.write(struct.pack(f"<{m}I", *[e[1] for e in edges]))
        f.write(struct.pack(f"<{m}H", *[e[2] for e in edges]))
        f.write(struct.pack(f"<{m}B", *[e[3] for e in edges]))
    print(f"{n} nodes, {m} directed edges, {len(sizes)} components (largest {max(sizes)}), {os.path.getsize(OUT)} bytes")

if __name__ == "__main__":
    main()
