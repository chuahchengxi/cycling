"""Pull the layers the road graph, the map tiles and the places file need out of
a Singapore OpenStreetMap extract, into one pickle. Build time only.

    curl -o sg.osm.pbf https://download.bbbike.org/osm/bbbike/Singapore/Singapore.osm.pbf
    python -I scripts/map/extract.py sg.osm.pbf layers.pickle      (needs: osmium)
"""
import math, pickle, sys
import osmium

ROADS = {"motorway", "motorway_link", "trunk", "trunk_link", "primary", "primary_link",
         "secondary", "secondary_link", "tertiary", "tertiary_link", "unclassified",
         "residential", "living_street", "service", "cycleway", "footway", "path",
         "pedestrian", "track", "steps", "bridleway"}

def area_kind(t):
    n, lu, le, ww = t.get("natural"), t.get("landuse"), t.get("leisure"), t.get("waterway")
    if n == "water" or lu in ("reservoir", "basin") or ww in ("riverbank", "dock"): return "water"
    if n in ("wood", "scrub", "wetland") or lu == "forest" or le == "nature_reserve": return "wood"
    if le in ("park", "garden", "playground") or lu in ("grass", "recreation_ground", "meadow", "village_green") or n == "grassland": return "park"
    if le in ("golf_course", "pitch"): return "pitch"
    if lu == "cemetery": return "cemetery"
    if n in ("beach", "sand"): return "sand"
    if t.get("aeroway") == "aerodrome": return "airport"
    if "building" in t: return "building"
    return None

# Points of interest for scripts/places/build.py: tags kept, and what makes an object worth keeping.
POI_TAGS = ("name", "name:en", "amenity", "leisure", "tourism", "historic", "man_made", "waterway", "landuse",
            "natural", "shop", "railway", "station", "shelter_type", "highway", "opening_hours", "wikipedia",
            "wikidata", "addr:housenumber", "addr:street", "water", "attraction", "building")
POI_KEYS = ("amenity", "leisure", "tourism", "historic", "man_made", "landuse", "natural", "shop", "railway", "attraction")

def poi_tags(t):
    """The kept tags if this object may be a place (named with a POI key, or any amenity/leisure), else None."""
    named_poi = "name" in t and (any(k in t for k in POI_KEYS) or t.get("building") == "train_station")
    if not (named_poi or "amenity" in t or "leisure" in t): return None
    return {k: t[k] for k in POI_TAGS if k in t}

def ring_area_m2(ring):
    """Shoelace area of a (lon, lat) ring in square metres, flat local frame."""
    k = math.cos(math.radians(ring[0][1])) * 111195
    xy = [(lo * k, la * 111195) for lo, la in ring]
    return abs(sum(x1 * y2 - x2 * y1 for (x1, y1), (x2, y2) in zip(xy, xy[1:] + xy[:1]))) / 2

class H(osmium.SimpleHandler):
    def __init__(self):
        super().__init__()
        self.roads, self.areas, self.lines, self.coast, self.labels, self.pois = [], [], [], [], [], []
        self.border = {}   # way id -> points of Singapore's national boundary (see sg_polygon)

    def node(self, n):
        t = n.tags
        if (pt := poi_tags(t)) is not None:
            self.pois.append(("n%d" % n.id, pt, n.location.lon, n.location.lat, [], 0))
        if "place" in t and t["place"] in ("suburb", "town", "quarter", "neighbourhood", "island") and "name" in t:
            self.labels.append((t["place"], t.get("name:en") or t["name"], n.location.lon, n.location.lat))
        elif t.get("railway") == "station" and t.get("station") in ("subway", "light_rail") and "name" in t:
            self.labels.append(("station", t.get("name:en") or t["name"], n.location.lon, n.location.lat))

    def way(self, w):
        t = w.tags
        try:
            pts = [(n.lon, n.lat) for n in w.nodes]
        except osmium.InvalidLocationError:
            return
        if len(pts) < 2: return
        hw = t.get("highway")
        if hw in ROADS:
            keep = {k: t[k] for k in ("highway", "oneway", "oneway:bicycle", "bicycle", "access", "name", "area", "bridge", "tunnel") if k in t}
            self.roads.append((keep, pts, [n.ref for n in w.nodes]))
        if w.id in BORDER_WAYS:
            self.border[w.id] = pts
        if t.get("natural") == "coastline":
            self.coast.append(pts)
        rw, ww, aw = t.get("railway"), t.get("waterway"), t.get("aeroway")
        if rw in ("subway", "light_rail", "rail") and t.get("tunnel") not in ("yes",) and t.get("layer", "0")[:1] != "-":
            self.lines.append(("rail", pts))
        elif ww in ("river", "canal", "drain", "stream"):
            self.lines.append((ww, pts))
            if ww in ("river", "canal") and "name" in t:
                mid = pts[len(pts) // 2]
                self.pois.append(("w%d" % w.id, {k: t[k] for k in POI_TAGS if k in t}, mid[0], mid[1], pts, 0))
        elif aw in ("runway", "taxiway"):
            self.lines.append((aw, pts))

    def area(self, a):
        t = a.tags
        kind, pt = area_kind(t), poi_tags(t)
        if not kind and pt is None: return
        polys = []
        try:
            for outer in a.outer_rings():
                ring = [(n.lon, n.lat) for n in outer]
                holes = [[(n.lon, n.lat) for n in inner] for inner in a.inner_rings(outer)]
                polys.append((ring, holes))
        except Exception:
            return
        if polys and kind:
            self.areas.append((kind, t.get("name:en") or t.get("name", ""), polys))
        if polys and pt is not None:
            outer = max((r for r, _ in polys), key=len)
            area = sum(ring_area_m2(r) - sum(ring_area_m2(h) for h in hs) for r, hs in polys if len(r) >= 3)
            lon = sum(p[0] for p in outer) / len(outer); lat = sum(p[1] for p in outer) / len(outer)
            oid = ("w%d" if a.from_way() else "r%d") % a.orig_id()
            self.pois.append((oid, pt, lon, lat, outer, area))

class Border(osmium.SimpleHandler):
    """Member ways of Singapore's national boundary relation (ISO3166-1=SG)."""
    def __init__(self): super().__init__(); self.ways = set()
    def relation(self, r):
        t = r.tags
        if t.get("boundary") == "administrative" and t.get("admin_level") == "2" and t.get("ISO3166-1") == "SG":
            self.ways |= {m.ref for m in r.members if m.type == "w"}

def sg_polygon(border):
    """Singapore as one polygon: everything south of the OSM Singapore-Malaysia line.
    The extract is clipped, so only the boundary's strait ways are present (its sea ways
    are outside the box); they join into one west-east chain, closed off south of the
    box (there's no other land in it south of the line)."""
    ways = list(border.values())
    if not ways: return []
    chain = ways.pop(0)
    while ways:   # join by shared end points
        for i, w in enumerate(ways):
            if w[0] == chain[-1]: chain += w[1:]
            elif w[-1] == chain[0]: chain = w + chain[1:]
            elif w[-1] == chain[-1]: chain += w[::-1][1:]
            elif w[0] == chain[0]: chain = w[::-1] + chain[1:]
            else: continue
            ways.pop(i); break
        else:
            sys.exit("Singapore boundary ways don't join into one line")
    if chain[0][0] > chain[-1][0]: chain = chain[::-1]
    south = min(p[1] for p in chain) - 1
    return [(chain + [(chain[-1][0], south), (chain[0][0], south)], [])]

b = Border(); b.apply_file(sys.argv[1])
BORDER_WAYS = b.ways
h = H()
h.apply_file(sys.argv[1], locations=True)
h.sg = sg_polygon(h.border)
pickle.dump({"roads": h.roads, "areas": h.areas, "lines": h.lines, "coast": h.coast, "labels": h.labels, "pois": h.pois, "sg": h.sg},
            open(sys.argv[2], "wb"))
print({k: len(v) for k, v in vars(h).items() if isinstance(v, list)})
