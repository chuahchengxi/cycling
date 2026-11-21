"""Bundled raster map tiles for the offline map: Singapore, zoom 11-16, drawn
from the same OpenStreetMap extract as the road graph. Build time only.

    python -I scripts/map/tiles.py layers.pickle [zooms, e.g. 11-16]   (needs: shapely, pillow, numpy)

Output cyclingskibidi/tiles.pack, little-endian (must match TilePack in OfflineMap.swift):
    "TPK1", count:u32, count x (z:u8, pad:3, x:u32, y:u32, offset:u32, length:u32), PNG bytes...
Entry (0,0,0) is the plain sea tile, served for anything outside coverage.
"""
import io, json, math, os, pickle, struct, sys   # pickle: our own extract.py output, never downloaded
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from shapely import STRtree, box, get_coordinates
from shapely.geometry import LineString, Polygon, Point
from shapely.ops import linemerge, polygonize, unary_union

ROOT = os.path.join(os.path.dirname(__file__), "../..")
OUT = os.path.join(ROOT, "cyclingskibidi/tiles.pack")
LON0, LON1, LAT0, LAT1 = 103.60, 104.10, 1.20, 1.48     # TilePack.coverage
ZOOMS = range(11, 17)
if len(sys.argv) > 2:
    a, b = sys.argv[2].split("-"); ZOOMS = range(int(a), int(b) + 1)
SS, BLOCK, MARGIN = 2, 8, 64        # supersample, tiles per block side, px of overdraw for labels/lines

SEA, LAND = (170, 211, 223), (242, 239, 233)
AREA = {"park": (200, 240, 190), "wood": (173, 209, 158), "pitch": (170, 224, 203), "cemetery": (170, 203, 175),
        "sand": (245, 233, 198), "airport": (233, 231, 226), "water": SEA, "building": (217, 208, 201)}
AREA_MINZ = {"park": 11, "wood": 11, "water": 11, "airport": 11, "pitch": 14, "cemetery": 13, "sand": 13, "building": 15}
# highway -> (fill, casing, {zoom: width px})
ROAD = {
    "motorway": ((232, 146, 162), (200, 100, 120), {11: 2, 12: 2.5, 13: 3.5, 14: 5, 15: 7, 16: 10}),
    "trunk":    ((249, 178, 156), (200, 130, 110), {11: 1.5, 12: 2, 13: 3, 14: 4.5, 15: 6.5, 16: 9}),
    "primary":  ((252, 214, 164), (190, 150, 100), {11: 1, 12: 1.6, 13: 2.5, 14: 4, 15: 6, 16: 8.5}),
    "secondary": ((247, 250, 191), (170, 170, 120), {12: 1, 13: 2, 14: 3.5, 15: 5.5, 16: 8}),
    "tertiary": ((255, 255, 255), (180, 180, 180), {13: 1.5, 14: 3, 15: 4.5, 16: 7}),
    "minor":    ((255, 255, 255), (190, 190, 190), {14: 1.5, 15: 3, 16: 5}),
    "service":  ((255, 255, 255), (200, 200, 200), {15: 1.5, 16: 3}),
    "path":     ((235, 140, 120), None, {15: 1, 16: 1.5}),
    "cycleway": ((60, 110, 230), None, {14: 1, 15: 1.5, 16: 2}),
}
GROUP = {"motorway": "motorway", "motorway_link": "motorway", "trunk": "trunk", "trunk_link": "trunk",
         "primary": "primary", "primary_link": "primary", "secondary": "secondary", "secondary_link": "secondary",
         "tertiary": "tertiary", "tertiary_link": "tertiary", "residential": "minor", "unclassified": "minor",
         "living_street": "minor", "service": "service", "footway": "path", "path": "path", "pedestrian": "path",
         "track": "path", "bridleway": "path", "steps": "path", "cycleway": "cycleway"}
PCN = ((46, 158, 79), {12: 1.5, 13: 2, 14: 3, 15: 4, 16: 5})
LINE = {"river": (SEA, {12: 1.5, 13: 2, 14: 3, 15: 4, 16: 6}), "canal": (SEA, {12: 1.5, 13: 2, 14: 3, 15: 4, 16: 6}),
        "drain": (SEA, {15: 1.5, 16: 2.5}), "stream": (SEA, {15: 1, 16: 2}),
        "rail": ((120, 120, 120), {12: 1, 13: 1, 14: 1.5, 15: 2, 16: 2.5}),
        "runway": ((190, 190, 200), {12: 2, 13: 4, 14: 8, 15: 14, 16: 26}), "taxiway": ((200, 200, 210), {14: 2, 15: 4, 16: 7})}
LABEL = {"town": (11, 13, 15, True), "suburb": (13, 16, 13, True), "island": (12, 16, 12, False),
         "quarter": (14, 16, 12, False), "neighbourhood": (15, 16, 11, False), "station": (14, 16, 11, False),
         "park": (15, 16, 11, False)}   # kind -> (minz, maxz, size pt, bold)
FONT = {False: "/System/Library/Fonts/Supplemental/Arial.ttf", True: "/System/Library/Fonts/Supplemental/Arial Bold.ttf"}

def px(z, lon, lat):
    n = 256 * 2 ** z
    return (lon + 180) / 360 * n, (1 - np.arcsinh(np.tan(np.radians(lat))) / math.pi) / 2 * n

def tile_range(z):
    (x0, y0), (x1, y1) = px(z, LON0, LAT1), px(z, LON1, LAT0)
    return int(x0 // 256), int(x1 // 256), int(y0 // 256), int(y1 // 256)

def lonlat(z, x, y):
    n = 256 * 2 ** z
    return x / n * 360 - 180, math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * y / n))))

print("loading", flush=True)
L = pickle.load(open(sys.argv[1], "rb"))

# Land from the coastline. The extract's coastline has small breaks and is cut at
# the extract's edge, so chains whose ends nearly meet are closed into rings
# (islands) and the rest are run onto the box edge (Johor).
coast_pts = [p for c in L["coast"] for p in c]
cx0, cx1 = min(p[0] for p in coast_pts), max(p[0] for p in coast_pts)
cy0, cy1 = min(p[1] for p in coast_pts), max(p[1] for p in coast_pts)
B = box(cx0, cy0 - 0.05, cx1, cy1)
merged = linemerge([LineString(c) for c in L["coast"] if len(c) > 1])
chains = list(getattr(merged, "geoms", [merged]))
islands, open_chains = [], []
def to_edge(pt):   # an end within ~1 km of the box edge is cut there: run it onto the edge
    q = Point(pt)
    return [B.exterior.interpolate(B.exterior.project(q)).coords[0]] if B.exterior.distance(q) < 0.01 else []
for c in chains:
    a0, a1 = c.coords[0], c.coords[-1]
    if c.is_ring or math.dist(a0, a1) < 0.03:
        if len(c.coords) > 3:
            p = Polygon(c.coords)
            islands.append(p if p.is_valid else p.buffer(0))
    else:
        open_chains.append(LineString(to_edge(a0) + list(c.coords) + to_edge(a1)))
# The open sea is the face along the box's south edge (well below any coast);
# every other face, islands and Johor alike, is land.
faces = list(polygonize(unary_union([B.exterior] + open_chains + [i.exterior for i in islands if i.geom_type == "Polygon"])))
land_faces = [f for f in faces if f.bounds[1] > B.bounds[1] + 1e-9]
land = unary_union(land_faces)
print("land km2 ~", round(land.area * 111.195 ** 2), "from", len(land_faces), "of", len(faces), "faces", flush=True)

def polys(rings):
    out = []
    for ring, holes in rings:
        if len(ring) >= 4:
            p = Polygon(ring, [h for h in holes if len(h) >= 4])
            out.append(p if p.is_valid else p.buffer(0))
    return out

areas = {k: [] for k in AREA}
named_parks = []
for kind, name, rings in L["areas"]:
    for p in polys(rings):
        if p.is_empty: continue
        areas[kind].append(p)
        if kind in ("park", "wood") and name and p.area > 2e-6: named_parks.append((name, p))
trees = {k: (STRtree(v), v) for k, v in areas.items() if v}
roads = {g: [] for g in ROAD}
for tags, pts, _ in L["roads"]:
    g = GROUP.get(tags.get("highway"))
    if g and tags.get("area") != "yes" and tags.get("tunnel") != "yes": roads[g].append(LineString(pts))
road_trees = {g: (STRtree(v), v) for g, v in roads.items() if v}
lines = {}
for kind, pts in L["lines"]:
    lines.setdefault(kind, []).append(LineString(pts))
line_trees = {k: (STRtree(v), v) for k, v in lines.items()}
pcn = [LineString([(c[0], c[1]) for c in f["geometry"]["coordinates"]])
       for f in json.load(open(os.path.join(ROOT, "cyclingskibidi/pcn-seed.geojson")))["features"]
       if f["geometry"]["type"] == "LineString" and len(f["geometry"]["coordinates"]) > 1]
pcn_tree = STRtree(pcn)
labels = [(k, n, lo, la) for k, n, lo, la in L["labels"]]
labels += [("park", n, p.representative_point().x, p.representative_point().y) for n, p in named_parks]
fonts = {}

def font(size, bold):
    if (size, bold) not in fonts: fonts[(size, bold)] = ImageFont.truetype(FONT[bold], size * SS)
    return fonts[(size, bold)]

def render_block(z, bx, by, nx, ny):
    """Tiles (bx..bx+nx, by..by+ny) at zoom z -> {(x, y): PIL image}."""
    W, H = (nx * 256 + 2 * MARGIN) * SS, (ny * 256 + 2 * MARGIN) * SS
    ox, oy = bx * 256 - MARGIN, by * 256 - MARGIN
    lo0, la1 = lonlat(z, ox, oy); lo1, la0 = lonlat(z, ox + W / SS, oy + H / SS)
    view = box(lo0, la0, lo1, la1)
    deg_px = (lo1 - lo0) / (W / SS)
    img = Image.new("RGB", (W, H), SEA)
    d = ImageDraw.Draw(img)

    def xy(geom):
        c = get_coordinates(geom)
        x, y = px(z, c[:, 0], c[:, 1])
        return list(zip(((x - ox) * SS).tolist(), ((y - oy) * SS).tolist()))

    def fill(geoms, color, outline=None):
        mask = Image.new("L", (W, H), 0)
        md = ImageDraw.Draw(mask)
        holes = []
        for g in geoms:
            for p in getattr(g, "geoms", [g]):
                if p.geom_type != "Polygon" or p.is_empty: continue
                b = p.bounds
                if (b[2] - b[0]) / deg_px < 1 and (b[3] - b[1]) / deg_px < 1: continue
                s = p.simplify(deg_px * 0.4) if z < 15 else p
                if s.is_empty or s.geom_type != "Polygon": continue
                ext = xy(s.exterior)
                if len(ext) >= 3: md.polygon(ext, fill=255)
                holes += [xy(r) for r in s.interiors]
        for h in holes:
            if len(h) >= 3: md.polygon(h, fill=0)
        img.paste(color, mask=mask)
        if outline:
            for g in geoms:
                for p in getattr(g, "geoms", [g]):
                    if p.geom_type == "Polygon" and not p.is_empty and p.area / deg_px ** 2 > 30:
                        d.line(xy(p.exterior), fill=outline, width=1)

    def stroke(geoms, color, width, casing=None):
        w = max(1, round(width * SS))
        segs = [xy(g) for g in geoms]
        if casing:
            for s in segs:
                if len(s) > 1: d.line(s, fill=casing, width=w + 2 * SS, joint="curve")
        for s in segs:
            if len(s) > 1: d.line(s, fill=color, width=w, joint="curve")

    def query(tree_geoms):
        tree, geoms = tree_geoms
        return [geoms[i] for i in tree.query(view)]

    fill([land.intersection(view)], LAND)
    for kind in ("airport", "sand", "cemetery", "pitch", "park", "wood", "water", "building"):
        if z >= AREA_MINZ[kind] and kind in trees:
            fill(query(trees[kind]), AREA[kind], (196, 182, 171) if kind == "building" else None)
    for kind in ("river", "canal", "drain", "stream", "runway", "taxiway", "rail"):
        color, widths = LINE[kind]
        if z in widths and kind in line_trees: stroke(query(line_trees[kind]), color, widths[z])
    if z in PCN[1]: stroke(query((pcn_tree, pcn)), PCN[0], PCN[1][z] + 2)   # under the paths: a green band
    for g in ("cycleway", "path", "service", "minor", "tertiary", "secondary", "primary", "trunk", "motorway"):
        fillc, casing, widths = ROAD[g]
        if z in widths and g in road_trees: stroke(query(road_trees[g]), fillc, widths[z], casing if z >= 13 else None)

    placed = []
    for kind, name, lo, la in sorted(labels, key=lambda l: list(LABEL).index(l[0]) if l[0] in LABEL else 99):
        if kind not in LABEL: continue
        minz, maxz, size, bold = LABEL[kind]
        if not (minz <= z <= maxz) or not (lo0 <= lo <= lo1 and la0 <= la <= la1): continue
        x, y = px(z, lo, la)
        x, y = (x - ox) * SS, (y - oy) * SS
        f = font(size, bold)
        l, t, r, b = d.textbbox((x, y), name, font=f, anchor="mm", stroke_width=2 * SS)
        if any(not (r < pl or l > pr or b < pt or t > pb) for pl, pt, pr, pb in placed): continue
        placed.append((l, t, r, b))
        color = (40, 90, 50) if kind == "park" else (80, 80, 80) if kind == "station" else (50, 50, 50)
        d.text((x, y), name, font=f, anchor="mm", fill=color, stroke_width=2 * SS, stroke_fill=(255, 255, 255))

    img = img.resize((W // SS, H // SS), Image.LANCZOS)
    out = {}
    for i in range(nx):
        for j in range(ny):
            x, y = MARGIN + i * 256, MARGIN + j * 256
            out[(bx + i, by + j)] = img.crop((x, y, x + 256, y + 256))
    return out

PALETTE = None   # one palette for every tile, so colours match across tile edges
def png(im):
    buf = io.BytesIO()
    im.quantize(palette=PALETTE, dither=Image.Dither.NONE).save(buf, "PNG", optimize=True)
    return buf.getvalue()

# The palette comes from a dense central block at z15 (roads, parks, water, buildings, labels).
_x0, _, _y0, _ = tile_range(15)   # (x0, x1, y0, y1)
_sample = render_block(15, _x0 + 20, _y0 + 12, 4, 4)   # around Orchard and the river
_strip = Image.new("RGB", (256 * 16, 256))
for _i, _im in enumerate(_sample.values()): _strip.paste(_im, (_i * 256, 0))
PALETTE = _strip.quantize(colors=96, method=Image.Quantize.MEDIANCUT)

blobs, entries = {}, []
def add(z, x, y, data):
    if data not in blobs: blobs[data] = len(blobs)
    entries.append((z, x, y, blobs[data]))
add(0, 0, 0, png(Image.new("RGB", (256, 256), SEA)))
for z in ZOOMS:
    x0, x1, y0, y1 = tile_range(z)
    count = 0
    for bx in range(x0, x1 + 1, BLOCK):
        for by in range(y0, y1 + 1, BLOCK):
            for (x, y), im in render_block(z, bx, by, min(BLOCK, x1 + 1 - bx), min(BLOCK, y1 + 1 - by)).items():
                add(z, x, y, png(im)); count += 1
    print(f"z{z}: {count} tiles, {len(blobs)} distinct so far", flush=True)

data = list(blobs)
offsets, pos = [], 8 + 20 * len(entries)
for b in data: offsets.append(pos); pos += len(b)
with open(OUT, "wb") as f:
    f.write(b"TPK1" + struct.pack("<I", len(entries)))
    for z, x, y, k in entries: f.write(struct.pack("<B3xIIII", z, x, y, offsets[k], len(data[k])))
    for b in data: f.write(b)
print(f"{len(entries)} tiles, {len(data)} distinct, {os.path.getsize(OUT)} bytes -> {OUT}")
