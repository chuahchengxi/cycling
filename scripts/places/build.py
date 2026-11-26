"""Bundled places for offline search, Leisure sights and (later) rest stops.

Reads the layers pickle from scripts/map/extract.py (the same OSM snapshot as
the roads and tiles) and writes cyclingskibidi/places.json (ODbL).
Build time only; the app never goes online. See scripts/map/README.md.

    python -I scripts/places/build.py layers.pickle
    python -I scripts/places/build.py --check          # self-checks, no data needed
"""
import json, math, os, pickle, re, sys, unicodedata   # pickle: our own extract.py output, never downloaded
from collections import Counter, defaultdict

OUT = os.path.join(os.path.dirname(__file__), "../../cyclingskibidi/places.json")
OVERLAY_SRC = os.path.join(os.path.dirname(__file__), "overlay.src.json")
OVERLAY_OUT = os.path.join(os.path.dirname(__file__), "../../cyclingskibidi/places_overlay.json")
PCN = os.path.join(os.path.dirname(__file__), "../../cyclingskibidi/pcn-seed.geojson")
DAYS = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
DAY_LIST = re.compile(r"^(Mo|Tu|We|Th|Fr|Sa|Su)(-(Mo|Tu|We|Th|Fr|Sa|Su))?(,(Mo|Tu|We|Th|Fr|Sa|Su)(-(Mo|Tu|We|Th|Fr|Sa|Su))?)*$")
SPAN = re.compile(r"^(\d\d):(\d\d)-(\d\d):(\d\d)$")
HAWKER_NAME = re.compile(r"\b(hawker|food (cent(re|er)|court)|food village)\b", re.I)
MARKET_NAME = re.compile(r"\bmarket\b", re.I)                 # only for amenity=marketplace
RIVERISH = re.compile(r"\b(river|canal|sungei|drain)\b", re.I)
# Unnamed places of these kinds take this name, and are kept only near a park connector.
NAMELESS = {"playground": "Playground", "toilets": "Toilets", "drinkingWater": "Drinking water",
            "shelter": "Shelter", "repair": "Bike repair station", "bikeParking": "Bike parking",
            "bikeRental": "Bike rental"}
NEAR_PCN_M = 1000
LARGE_M2 = 10_000
AREA_CELL = 0.001     # ~111 m: an outline keeps one point per cell, so no stretch of edge is far from a kept point
RIVER_CELL = 0.0006   # ~67 m: rivers use the 100 m corridor, so finer

def category(t):
    """App category for an OSM tag set, first match wins; None = not a place we ship."""
    leisure, tourism, amenity, name = t.get("leisure"), t.get("tourism"), t.get("amenity"), t.get("name:en") or t.get("name") or ""
    if leisure == "park": return "park"
    if leisure == "nature_reserve": return "nationalPark"
    if t.get("natural") == "beach": return "beach"
    if leisure in ("marina", "stadium"): return leisure
    if tourism == "theme_park": return "amusementPark"
    if tourism in ("museum", "aquarium", "zoo", "attraction", "viewpoint"): return tourism
    if amenity == "food_court": return "hawker"
    if amenity == "place_of_worship": return "worship"
    if amenity in ("library", "cafe"): return amenity
    if t.get("railway") == "station" and t.get("station") in ("subway", "light_rail"): return "station"
    if t.get("shop") == "mall": return "mall"
    if amenity in ("marketplace", "restaurant") and HAWKER_NAME.search(name): return "hawker"
    if amenity == "marketplace" and MARKET_NAME.search(name): return "hawker"
    if t.get("man_made") == "bridge":   # road overpasses aren't sights
        return None if re.search(r"flyover|viaduct|interchange", name, re.I) else "bridge"
    if t.get("waterway") in ("river", "canal"): return "waterway"
    if t.get("landuse") in ("reservoir", "basin") or t.get("natural") == "wetland": return "reservoir"
    if t.get("natural") == "water":   # a lake or reservoir, not the water area of a river or canal
        riverish = t.get("water") in ("river", "canal", "stream", "drain", "ditch") or RIVERISH.search(name)
        return None if riverish else "reservoir"
    if "historic" in t: return "heritage"
    if tourism == "artwork": return "artwork"
    if leisure == "playground": return "playground"
    if amenity == "toilets": return "toilets"
    if amenity in ("drinking_water", "water_point") or t.get("man_made") == "water_tap": return "drinkingWater"
    if amenity == "shelter":
        return None if t.get("shelter_type") == "public_transport" or t.get("highway") == "bus_stop" else "shelter"
    if amenity == "bicycle_repair_station": return "repair"
    if amenity == "bicycle_parking": return "bikeParking"
    if amenity == "bicycle_rental": return "bikeRental"
    if "attraction" in t: return "attraction"                    # e.g. attraction=big_wheel (Singapore Flyer)
    if t.get("man_made") == "pier": return "viewpoint"           # jetties
    if t.get("landuse") == "cemetery" and re.search(r"\bwar\b", name, re.I): return "heritage"
    if t.get("building") == "train_station" and re.search(r"railway station", name, re.I): return "heritage"
    return None

def parse_hours(s):
    """OSM opening_hours -> sorted [[day 0=Mon, from, to]] minutes, or None when
    always open or not understood (the app treats None as open, so a place is
    never hidden by a format we can't read).
    ponytail: the common subset only (day lists, HH:MM spans, off, PH/SH skipped)."""
    s = s.strip()
    if s == "24/7": return None
    week = {}
    for rule in (r.strip() for r in s.split(";")):
        if not rule or rule[:2] in ("PH", "SH"): continue
        head, _, rest = rule.partition(" ")
        if DAY_LIST.match(head):
            days = set()
            for part in head.split(","):
                a, _, b = part.partition("-")
                i, j = DAYS.index(a), DAYS.index(b or a)
                days |= {(i + k) % 7 for k in range((j - i) % 7 + 1)}
            rest = rest.strip()
        else:
            days, rest = set(range(7)), rule
        if rest == "off":
            spans = []
        else:
            spans = []
            for span in (x.strip() for x in rest.split(",")):
                m = SPAN.match(span)
                if not m: return None
                h1, m1, h2, m2 = map(int, m.groups())
                spans.append((h1 * 60 + m1, h2 * 60 + m2))
        for d in days: week[d] = spans
    out = []
    for d, spans in week.items():
        for a, b in spans:
            if b > a: out.append([d, a, b])
            else:                                   # past midnight: the rest spills into the next day
                out.append([d, a, 1440])
                if b > 0: out.append([(d + 1) % 7, 0, b])
    return sorted(out) or None

def grid_thin(points, cell):
    """The first (lon, lat) point in each `cell`-degree grid square, in order:
    every original point stays within about a cell of a kept one."""
    seen, out = set(), []
    for lo, la in points:
        k = (math.floor(la / cell), math.floor(lo / cell))
        if k not in seen: seen.add(k); out.append((lo, la))
    return out

def chains(ways):
    """Indices of ways grouped into chains that share an end point (one river)."""
    parent = list(range(len(ways)))
    def root(i):
        while parent[i] != i: parent[i] = parent[parent[i]]; i = parent[i]
        return i
    ends = {}
    for i, w in enumerate(ways):
        for p in (w[0], w[-1]):
            if p in ends: parent[root(i)] = root(ends[p])
            else: ends[p] = i
    groups = defaultdict(list)
    for i in range(len(ways)): groups[root(i)].append(i)
    return sorted(groups.values())

def inside(lon, lat, polys):
    """Point in any (outer ring, holes) polygon of (lon, lat) rings (ray casting)."""
    def ring(r):
        hit = False
        for (x1, y1), (x2, y2) in zip(r, r[1:] + r[:1]):
            if (y1 > lat) != (y2 > lat) and lon < x1 + (lat - y1) * (x2 - x1) / (y2 - y1): hit = not hit
        return hit
    return any(ring(o) and not any(ring(h) for h in hs) for o, hs in polys)

def fold(name):
    """Case- and accent-insensitive form of a name, with "HC"/"FC" spelled out."""
    n = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode().lower()
    n = re.sub(r"\s+", " ", n).strip()
    return re.sub(r" hc$", " hawker centre", re.sub(r" fc$", " food centre", n))

def resolve(src, records):
    """Our hand-written overlay entries -> ({OSM id or x-slug: entry}, warnings).
    A `match` attaches only when exactly one place has that name and category;
    a hand-added place needs its own sourced coordinate. Never guesses."""
    index = defaultdict(list)
    for r in records: index[(fold(r["name"]), r["category"])].append(r["id"])
    out, warn = {}, []
    for e in src:
        if "match" in e:
            m = e["match"]
            ids = index.get((fold(m["name"]), m["category"]), [])
            # `"all": true` = a person checked that every hit is one place mapped in parts.
            if not ids or (len(ids) > 1 and not e.get("all")):
                warn.append(("UNRESOLVED %s" if not ids else "AMBIGUOUS %%s (%d places)" % len(ids)) % m["name"])
                continue
            for i in ids: out[i] = {k: v for k, v in e.items() if k not in ("match", "all")}
        elif e.get("coord_source") and "lat" in e and "lon" in e:
            out["x-" + re.sub(r"[^a-z0-9]+", "-", fold(e["name"])).strip("-")] = dict(e)
        else:
            warn.append("NO SOURCED COORDINATE %s" % e.get("name"))
    return out, warn

def metres(lat1, lon1, lat2, lon2):
    dl, dn = math.radians(lat2 - lat1), math.radians(lon2 - lon1)
    h = math.sin(dl / 2) ** 2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dn / 2) ** 2
    return 2 * 6371008.8 * math.asin(math.sqrt(h))

if "--check" in sys.argv:
    assert parse_hours("24/7") is None                       # always open = no hours
    assert parse_hours("Mo-Fr 08:00-20:00; Sa,Su 09:00-18:00") == \
        [[d, 480, 1200] for d in range(5)] + [[5, 540, 1080], [6, 540, 1080]]
    assert parse_hours("18:00-02:00") == sorted([[d, 1080, 1440] for d in range(7)] + [[d, 0, 120] for d in range(7)])
    assert parse_hours("Mo-Su 06:00-14:00; We off") == [[d, 360, 840] for d in (0, 1, 3, 4, 5, 6)]
    assert parse_hours("sunrise-sunset") is None              # unknown -> treated as open
    assert parse_hours("Mo-Fr 08:00-17:00; PH off") == [[d, 480, 1020] for d in range(5)]   # PH rules ignored
    assert category({"amenity": "restaurant", "name": "Old Airport Road Food Centre"}) == "hawker"
    assert category({"amenity": "restaurant", "name": "Swensen's"}) is None
    assert category({"amenity": "shelter", "shelter_type": "public_transport"}) is None
    assert category({"amenity": "toilets"}) == "toilets"
    assert category({"man_made": "bridge", "name": "Bedok Reservoir Flyover"}) is None          # road overpasses aren't sights
    assert category({"man_made": "bridge", "name": "Labrador Viaduct"}) is None
    assert category({"man_made": "bridge", "name": "Jubilee Bridge"}) == "bridge"
    recs = [{"id": "w1", "name": "Tiong Bahru Market", "category": "hawker"},
            {"id": "w2", "name": "Ang Mo Kio Park", "category": "park"},
            {"id": "w3", "name": "Ang Mo Kio Park", "category": "park"}]
    out, warn = resolve([{"match": {"name": "tiong bahru market", "category": "hawker"}, "dishes": ["chwee kueh"]},
                         {"match": {"name": "Ang Mo Kio Park", "category": "park"}, "note": "x"},
                         {"match": {"name": "Nowhere", "category": "park"}},
                         {"name": "Keppel Marina East green roof", "category": "attraction", "lat": 1.29, "lon": 103.87},
                         {"name": "Sourced spot", "category": "attraction", "lat": 1.29, "lon": 103.87, "coord_source": "https://x"}], recs)
    assert out["w1"]["dishes"] == ["chwee kueh"] and "match" not in out["w1"]
    assert "w2" not in out and "w3" not in out                 # ambiguous: skipped
    assert any("AMBIGUOUS" in w for w in warn) and any("UNRESOLVED" in w for w in warn)
    out2, _ = resolve([{"match": {"name": "Ang Mo Kio Park", "category": "park"}, "all": True, "note": "y"}], recs)
    assert out2.get("w2", {}).get("note") == "y" and out2.get("w3", {}).get("note") == "y" and "all" not in out2["w2"]   # one place in parts
    assert "x-sourced-spot" in out and not any(k.startswith("x-keppel") for k in out)   # no coord_source, no entry
    # Review fixes. Hawker names need whole words; "market" only for real marketplaces.
    assert category({"amenity": "restaurant", "name": "Manhattan Fish Market"}) is None
    assert category({"amenity": "restaurant", "name": "Happy Seafood Village"}) is None
    assert category({"amenity": "marketplace", "name": "Tekka Market"}) == "hawker"
    # natural=water is a reservoir or lake, not a stretch of river or canal.
    assert category({"natural": "water", "water": "river", "name": "Pandan River"}) is None
    assert category({"natural": "water", "name": "Alexandra Canal"}) is None
    assert category({"natural": "water", "name": "Swan Lake"}) == "reservoir"
    assert category({"landuse": "reservoir", "name": "Bedok Reservoir"}) == "reservoir"
    # Places the old rules never reached.
    assert category({"attraction": "big_wheel", "name": "Singapore Flyer"}) == "attraction"
    assert category({"man_made": "pier", "name": "Bedok Jetty"}) == "viewpoint"
    assert category({"landuse": "cemetery", "name": "Kranji War Memorial"}) == "heritage"
    assert category({"landuse": "cemetery", "name": "Choa Chu Kang Cemetery"}) is None
    assert category({"building": "train_station", "name": "Bukit Timah Railway Station"}) == "heritage"
    # Outlines thinned by distance, not by count: every original point stays near a kept one.
    line = [(103.8 + i * 0.0001, 1.3) for i in range(300)]          # ~3.3 km, 11 m apart
    kept = grid_thin(line, AREA_CELL)
    assert len(kept) < len(line) / 4
    assert max(min(metres(la, lo, b, a) for a, b in kept) for lo, la in line) <= 130
    # Rivers: only ways that touch are one river.
    assert sorted(len(c) for c in chains([[(0, 0), (1, 0)], [(1, 0), (2, 0)], [(50, 50), (51, 50)]])) == [1, 2]
    # Singapore only.
    sg = [([(103.6, 1.2), (104.1, 1.2), (104.1, 1.47), (103.6, 1.47)], [])]
    assert inside(103.8, 1.3, sg) and not inside(103.76, 1.49, sg)
    print("places checks passed")
    sys.exit(0)

CELL = 0.005   # ~550 m
pcn_cells = defaultdict(list)
for f in json.load(open(PCN))["features"]:
    g = f.get("geometry") or {}
    lines = [g["coordinates"]] if g.get("type") == "LineString" else g.get("coordinates", []) if g.get("type") == "MultiLineString" else []
    for line in lines:
        for lon, lat, *_ in line:
            pcn_cells[(int(lat // CELL), int(lon // CELL))].append((lat, lon))

def near_pcn(lat, lon):
    ci, cj = int(lat // CELL), int(lon // CELL)
    return any(metres(lat, lon, a, b) <= NEAR_PCN_M
               for di in range(-2, 3) for dj in range(-2, 3) for a, b in pcn_cells.get((ci + di, cj + dj), ()))

L = pickle.load(open(sys.argv[1], "rb"))
SG = L.get("sg") or sys.exit("no Singapore boundary in the pickle: re-run scripts/map/extract.py")
records, seen, rivers = [], set(), defaultdict(list)
for oid, t, lon, lat, shape, area in L["pois"]:
    if not inside(lon, lat, SG): continue      # the extract also covers Johor
    cat = category(t)
    if not cat: continue
    name = t.get("name:en") or t.get("name")
    if cat in NAMELESS:
        name = name or NAMELESS[cat]
        if not near_pcn(lat, lon): continue
    elif not name:
        continue
    if cat == "waterway":   # one river is many OSM ways: joined below, but only where they touch
        rivers[name].append((oid, lon, lat, shape))
        continue
    key = (name.lower(), cat, round(lat, 3), round(lon, 3))
    if key in seen: continue
    seen.add(key)
    rec = {"id": oid, "name": name, "category": cat, "lat": round(lat, 6), "lon": round(lon, 6),
           "address": " ".join(x for x in (t.get("addr:housenumber"), t.get("addr:street")) if x)}
    hours = parse_hours(t["opening_hours"]) if "opening_hours" in t else None
    if hours: rec["hours"] = hours
    if "wikipedia" in t or "wikidata" in t: rec["wiki"] = True
    if area: rec["area"] = round(area)
    if area >= LARGE_M2 and shape: rec["shape"] = [[round(a, 6), round(o, 6)] for o, a in grid_thin(shape, AREA_CELL)]
    records.append(rec)
for name, ways in rivers.items():
    for chain in chains([w[3] for w in ways]):
        part = [ways[i] for i in chain]
        oid, lon, lat, _ = max(part, key=lambda w: len(w[3]))              # pin: middle of the longest way
        first = min(part, key=lambda w: int(w[0][1:]))[0]                  # stable id: the lowest way id
        pts = [p for w in part for p in w[3]]
        records.append({"id": first, "name": name, "category": "waterway", "lat": round(lat, 6), "lon": round(lon, 6),
                        "address": "", "shape": [[round(a, 6), round(o, 6)] for o, a in grid_thin(pts, RIVER_CELL)]})
records.sort(key=lambda r: r["id"])
with open(OUT, "w") as f:   # one place per line: small, readable git diffs
    f.write("[\n" + ",\n".join(json.dumps(r, ensure_ascii=False, separators=(",", ":")) for r in records) + "\n]\n")
print(dict(sorted(Counter(r["category"] for r in records).items())))
print(len(records), "places,", os.path.getsize(OUT), "bytes ->", OUT)

overlay, warnings = resolve(json.load(open(OVERLAY_SRC)), records)
for w in warnings: print(w)
with open(OVERLAY_OUT, "w") as f:   # one place per line, sorted
    f.write("{\n" + ",\n".join(json.dumps(k) + ":" + json.dumps(overlay[k], ensure_ascii=False, separators=(",", ":"))
                                for k in sorted(overlay)) + "\n}\n")
print(len(overlay), "overlay entries,", len(warnings), "skipped ->", OVERLAY_OUT)
