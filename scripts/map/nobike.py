"""No-bike ways (expressways, steps, bicycle=no) and the points where they meet
the rideable network, for the app's safety checks. Build time only.

    python -I scripts/map/nobike.py layers.pickle   # cyclingskibidi/nobike.json
    python -I scripts/map/nobike.py --check         # self-checks, no data

Output cyclingskibidi/nobike.json, a JSON object with sorted keys:
    {"lines": [{"kind": "expressway"|"nobike"|"steps", "name": String,
                "pts": [[lat, lon], ...]}],
     "entrances": [{"kind": ..., "name": String, "lat": Double, "lon": Double}]}
Lines are clipped to Singapore and thinned so no two kept points are over
THIN_M apart. An entrance is a node inside Singapore shared by a non-steps
no-bike way and a way roads.py may route on. Coordinates are rounded to 6 dp;
everything is sorted, so the same input gives the same bytes.
"""
import json, math, os, pickle, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from roads import CLASS, metres, rideable   # one definition of rideable, not a copy

OUT = os.path.join(os.path.dirname(__file__), "../../cyclingskibidi/nobike.json")
# The plan thins at 50 m, with 80 m as the fallback if the file is over 500 KB.
# Even after clipping to Singapore and dropping staircase entrances the build is
# ~1.6 MB at 80 m (14.4k OSM way fragments and 2.8k entrances dominate), so it
# uses the fallback. thin() still honours any gap and --check pins the 50 m
# contract.
THIN_M = 80.0

def kind(tags):
    """What makes this way no-bike for the app, or None if it is fine to ride."""
    hw = tags.get("highway")
    if hw in ("motorway", "motorway_link"): return "expressway"
    if hw == "steps": return "steps"
    if hw is not None and tags.get("bicycle") == "no": return "nobike"
    return None

def thin(pts, gap=THIN_M):
    """Keep first and last and drop points until the last kept is gap metres
    back; split any single segment longer than gap so no gap is over gap."""
    if len(pts) < 2: return list(pts)
    out = [pts[0]]
    since = 0.0
    for a, b in zip(pts, pts[1:]):
        seg = metres(a, b)
        if seg > gap:
            if out[-1] != a: out.append(a)
            n = math.ceil(seg / gap)
            for j in range(1, n):
                t = j / n
                out.append((a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t))
            out.append(b)
            since = 0.0
        elif since + seg > gap:
            if out[-1] != a: out.append(a)
            since = seg
        else:
            since += seg
    if out[-1] != pts[-1]: out.append(pts[-1])
    return out

def inside(lon, lat, polys):
    """Point in any (outer ring, holes) polygon of (lon, lat) rings (ray casting).
    Same test as scripts/places/build.py; that module builds at import time, so
    this is a copy rather than an import."""
    def ring(r):
        hit = False
        for (x1, y1), (x2, y2) in zip(r, r[1:] + r[:1]):
            if (y1 > lat) != (y2 > lat) and lon < x1 + (lat - y1) * (x2 - x1) / (y2 - y1): hit = not hit
        return hit
    return any(ring(o) and not any(ring(h) for h in hs) for o, hs in polys)

def entrances(ways, sg):
    """Where no-bike ways share a node with a way roads.py would route on.

    ways is [(tags, pts, node_refs)] in (lon, lat) order, as in the pickle.
    Steps are lines only: a staircase entrance every 60 m would make the
    off-route alarm fire constantly. Only points inside Singapore count.
    One entry per (kind, lat, lon), preferring a non-empty name."""
    ride = set()
    for tags, _, refs in ways:
        if rideable(tags): ride.update(refs)
    found = {}
    for tags, pts, refs in ways:
        k = kind(tags)
        if k is None or k == "steps": continue
        name = tags.get("name", "")
        seen = set()
        for ref, (lon, lat) in zip(refs, pts):
            if ref not in ride or ref in seen or not inside(lon, lat, sg): continue
            seen.add(ref)
            key = (k, round(lat, 6), round(lon, 6))
            old = found.get(key)
            if old is None or (not old and name): found[key] = name
    out = [{"kind": k, "name": n, "lat": lat, "lon": lon} for (k, lat, lon), n in found.items()]
    out.sort(key=lambda e: (e["kind"], e["name"], e["lat"], e["lon"]))
    return out

def build(ways, sg):
    """The JSON-ready lines and entrances for the ways inside Singapore."""
    lines = []
    for tags, pts, _ in ways:
        k = kind(tags)
        if k is None or not any(inside(lon, lat, sg) for lon, lat in pts): continue
        lines.append({"kind": k, "name": tags.get("name", ""),
                      "pts": [[round(lat, 6), round(lon, 6)] for lon, lat in thin(pts)]})
    lines.sort(key=lambda l: (l["kind"], l["name"], l["pts"]))
    return {"lines": lines, "entrances": entrances(ways, sg)}

def main():
    L = pickle.load(open(sys.argv[1], "rb"))
    sg = L.get("sg")
    if not sg: sys.exit("no Singapore boundary in the pickle: re-run scripts/map/extract.py")
    data = build(L["roads"], sg)
    with open(OUT, "w") as f:
        json.dump(data, f, sort_keys=True, separators=(",", ":"))
        f.write("\n")
    counts = {}
    for line in data["lines"]: counts[line["kind"]] = counts.get(line["kind"], 0) + 1
    print(f"{len(data['lines'])} lines {counts}, {len(data['entrances'])} entrances, "
          f"{os.path.getsize(OUT)} bytes")

def check():
    assert kind({"highway": "motorway"}) == "expressway"
    assert kind({"highway": "motorway_link"}) == "expressway"
    assert kind({"highway": "steps"}) == "steps"
    assert kind({"highway": "footway", "bicycle": "no"}) == "nobike"
    assert kind({"highway": "residential"}) is None
    assert kind({"highway": "footway", "bicycle": "yes"}) is None

    sg = [([(103.0, 1.30), (103.1, 1.30), (103.1, 1.40), (103.0, 1.40)], [])]
    assert inside(103.05, 1.35, sg) and not inside(103.2, 1.35, sg)

    link = ({"highway": "motorway_link"},
            [(103.0, 1.30), (103.001, 1.30), (103.002, 1.30)], [1, 2, 3])
    home = ({"highway": "residential"},
            [(103.002, 1.30), (103.003, 1.30)], [3, 4])
    e = entrances([link, home], sg)
    assert len(e) == 1, e
    assert e[0] == {"kind": "expressway", "name": "", "lat": 1.3, "lon": 103.002}, e
    other = ({"highway": "motorway"},
             [(103.002, 1.30), (103.004, 1.30)], [3, 5])
    assert entrances([link, other], sg) == [], entrances([link, other], sg)
    stair = ({"highway": "steps"},
             [(103.002, 1.30), (103.003, 1.30)], [3, 6])
    assert entrances([stair, home], sg) == [], entrances([stair, home], sg)   # steps are lines only
    assert [l["kind"] for l in build([stair], sg)["lines"]] == ["steps"]

    out_link = ({"highway": "motorway_link"},
                [(103.2, 1.35), (103.3, 1.35)], [7, 8])
    out_home = ({"highway": "residential"},
                [(103.3, 1.35), (103.31, 1.35)], [8, 9])
    assert entrances([out_link, out_home], sg) == []                          # outside Singapore
    assert build([out_link], sg)["lines"] == []
    cross = ({"highway": "motorway"}, [(103.2, 1.35), (103.05, 1.35)], [10, 11])
    assert len(build([cross], sg)["lines"]) == 1                              # any point inside keeps it

    unnamed = ({"highway": "motorway_link"},
               [(103.002, 1.30), (103.004, 1.30)], [3, 12])
    named = ({"highway": "motorway", "name": "PIE"},
             [(103.002, 1.30), (103.005, 1.30)], [3, 13])
    want = [{"kind": "expressway", "name": "PIE", "lat": 1.3, "lon": 103.002}]
    assert entrances([unnamed, named, home], sg) == want                      # name wins
    assert entrances([named, unnamed, home], sg) == want

    line = [(103.0, 1.30 + i * 0.0001) for i in range(101)]   # ~11 m apart
    t = thin(line, 50.0)
    assert t[0] == line[0] and t[-1] == line[-1]
    assert len(t) < len(line)
    assert max(metres(a, b) for a, b in zip(t, t[1:])) <= 50.0 + 1e-6
    long = [(103.0, 1.30), (103.0, 1.3012)]                   # one ~133 m segment
    lt = thin(long, 50.0)
    assert lt[0] == long[0] and lt[-1] == long[-1]
    assert max(metres(a, b) for a, b in zip(lt, lt[1:])) <= 50.0 + 1e-6
    dt = thin(line)                                           # the build's gap
    assert dt[0] == line[0] and dt[-1] == line[-1]
    assert max(metres(a, b) for a, b in zip(dt, dt[1:])) <= THIN_M + 1e-6
    mixed = [(103.0, 1.30), (103.0, 1.3006), (103.0, 1.3020)]  # short, then > THIN_M
    mt = thin(mixed)
    assert mt[0] == mixed[0] and mt[-1] == mixed[-1]
    assert max(metres(a, b) for a, b in zip(mt, mt[1:])) <= THIN_M + 1e-6
    print("nobike checks passed")

if __name__ == "__main__":
    if sys.argv[1:2] == ["--check"]: check()
    else: main()
