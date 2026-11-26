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
HAWKER_NAME = re.compile(r"hawker|food cent(re|er)|market|food village", re.I)
# Unnamed places of these kinds take this name, and are kept only near a park connector.
NAMELESS = {"playground": "Playground", "toilets": "Toilets", "drinkingWater": "Drinking water",
            "shelter": "Shelter", "repair": "Bike repair station", "bikeParking": "Bike parking",
            "bikeRental": "Bike rental"}
NEAR_PCN_M = 1000
LARGE_M2 = 10_000
SHAPE_POINTS = 16
RIVER_POINTS = 64     # a river is many km long; 16 points would leave gaps wider than the 100 m corridor

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
    if t.get("man_made") == "bridge": return "bridge"
    if t.get("waterway") in ("river", "canal"): return "waterway"
    if t.get("landuse") in ("reservoir", "basin") or t.get("natural") in ("water", "wetland"): return "reservoir"
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

def thin(points, n):
    """At most n points: every k-th, always ending on the last."""
    if len(points) <= n: return list(points)
    k = math.ceil((len(points) - 1) / (n - 1))
    return list(points[:-1][::k]) + [points[-1]]

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
    assert thin([(i, i) for i in range(100)], 16)[-1] == (99, 99) and len(thin([(i, i) for i in range(100)], 16)) <= 16
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
records, seen, rivers = [], set(), {}
for oid, t, lon, lat, shape, area in L["pois"]:
    cat = category(t)
    if not cat: continue
    name = t.get("name:en") or t.get("name")
    if cat in NAMELESS:
        name = name or NAMELESS[cat]
        if not near_pcn(lat, lon): continue
    elif not name:
        continue
    if cat == "waterway":   # one river is many OSM ways: merge them by name, keep the longest way's middle
        r = rivers.setdefault(name, {"id": oid, "pts": [], "best": 0, "lat": lat, "lon": lon})
        r["pts"] += shape
        if len(shape) > r["best"]: r.update(best=len(shape), lat=lat, lon=lon, id=min(r["id"], oid))
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
    if area >= LARGE_M2 and shape: rec["shape"] = [[round(a, 6), round(o, 6)] for o, a in thin(shape, SHAPE_POINTS)]
    records.append(rec)
for name, r in rivers.items():
    records.append({"id": r["id"], "name": name, "category": "waterway", "lat": round(r["lat"], 6), "lon": round(r["lon"], 6),
                    "address": "", "shape": [[round(a, 6), round(o, 6)] for o, a in thin(r["pts"], RIVER_POINTS)]})
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
