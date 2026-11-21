"""Pull the layers the road graph and the map tiles need out of a Singapore
OpenStreetMap extract, into one pickle. Build time only.

    curl -o sg.osm.pbf https://download.bbbike.org/osm/bbbike/Singapore/Singapore.osm.pbf
    python -I scripts/map/extract.py sg.osm.pbf layers.pickle      (needs: osmium)
"""
import pickle, sys
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

class H(osmium.SimpleHandler):
    def __init__(self):
        super().__init__()
        self.roads, self.areas, self.lines, self.coast, self.labels = [], [], [], [], []

    def node(self, n):
        t = n.tags
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
        if t.get("natural") == "coastline":
            self.coast.append(pts)
        rw, ww, aw = t.get("railway"), t.get("waterway"), t.get("aeroway")
        if rw in ("subway", "light_rail", "rail") and t.get("tunnel") not in ("yes",) and t.get("layer", "0")[:1] != "-":
            self.lines.append(("rail", pts))
        elif ww in ("river", "canal", "drain", "stream"):
            self.lines.append((ww, pts))
        elif aw in ("runway", "taxiway"):
            self.lines.append((aw, pts))

    def area(self, a):
        t = a.tags
        kind = area_kind(t)
        if not kind: return
        polys = []
        try:
            for outer in a.outer_rings():
                ring = [(n.lon, n.lat) for n in outer]
                holes = [[(n.lon, n.lat) for n in inner] for inner in a.inner_rings(outer)]
                polys.append((ring, holes))
        except Exception:
            return
        if polys:
            self.areas.append((kind, t.get("name:en") or t.get("name", ""), polys))

h = H()
h.apply_file(sys.argv[1], locations=True)
pickle.dump({"roads": h.roads, "areas": h.areas, "lines": h.lines, "coast": h.coast, "labels": h.labels},
            open(sys.argv[2], "wb"))
print({k: len(v) for k, v in vars(h).items() if isinstance(v, list)})
