# Builds closures.json from pcn-seed.geojson + OSM (Overpass) + OneMap points. Args: seed geom.json ppp.json out
import json, sys
sys.path.insert(0, __file__.rsplit('/', 1)[0]); from geo import *
seed = json.load(open(sys.argv[1])); osm = json.load(open(sys.argv[2]))['elements']; ppp = json.load(open(sys.argv[3]))['elements']
def feat_lines(f):
    g = f['geometry']; parts = [g['coordinates']] if g['type'] == 'LineString' else g['coordinates']
    return [[(c[1], c[0]) for c in p] for p in parts]
def park(name): return [l for f in seed['features'] if f['properties'].get('PARK', '').strip() == name for l in feat_lines(f)]
def osm_name(name): return [[(p['lat'], p['lon']) for p in e['geometry']] for e in osm if e['tags'].get('name') == name]
def osm_ids(ids): return [[(p['lat'], p['lon']) for p in e['geometry']] for e in osm if e['id'] in ids]
def nearest_vertex(lines, ref_lines):
    return min((v for l in lines for v in l), key=lambda v: to_lines(ref_lines, v))
def runs_near(lines, ref_lines, within):
    """Maximal runs of consecutive vertices within `within` m of ref_lines."""
    out = []
    for l in lines:
        cur = []
        for v in l:
            if to_lines(ref_lines, v) <= within: cur.append(v)
            elif cur: out.append(cur); cur = []
        if cur: out.append(cur)
    return out
# Tight circles: path width plus seed/OSM error. Spacing 1.5r keeps every vertex of the
# stretch within 0.75r of a centre, so the routing penalty still catches it.
def circles(lines, src, spacing=30, r=20):
    return [{"lat": round(p[0], 6), "lon": round(p[1], 6), "radius_m": r, "coord_source": src}
            for l in lines for p in (sample(l, spacing) if len(l) > 1 else l)]
def stretch(lines, A, B):
    p = shortest(lines, A, B); assert p, "no path"; return p
# Connectors on a road's pavement: small circles, so a car-lane route alongside doesn't match.
ROADSIDE = dict(spacing=12, r=8)
PCN = "https://pcn.nparks.gov.sg/notices"; RULES = "https://pcn.nparks.gov.sg/sharingpcn/"
out = []
def add(id, name, cs, starts, until, note, url, kind="closure"):
    assert cs, id; out.append(dict(id=id, name=name, circles=cs, starts=starts, valid_until=until, note=note, source_url=url, kind=kind))
    print(f"{id}: {len(cs)} circles")

# --- closures ---
rc = osm_name('Rail Corridor')
a = nearest_vertex(rc, osm_name('Henderson Road')); b = nearest_vertex(rc, osm_name('Spooner Road'))
add("rail-corridor-south", "Rail Corridor South, Henderson Rd to Spooner Rd",
    circles([stretch(rc, a, b)], "OSM ways name=Rail Corridor, between OSM Henderson Road and Spooner Road"),
    "2026-03-02", "2027-07-31", "Trail works. Signed detour along Jalan Bukit Merah. Start given as 2 or 9 Mar 2026; earlier date used.",
    "https://railcorridor.nparks.gov.sg/latest-news/important-notices/closure-notice-feb")
add("loyang-pc", "Loyang Park Connector beside Loyang Ave",
    circles(park('Loyang Park Connector'), "pcn-seed PARK=Loyang Park Connector, whole connector (notice names no end roads)"),
    "2025-06-08", "2029-09-30", "Upgrading, on-site detour. Notice says Q3 2029; last day of Q3 used.", PCN)
ave6 = osm_name('Ang Mo Kio Avenue 6')
add("amk-ave6-pc", "Ang Mo Kio Park Connector along Ave 6 (C2C)",
    circles([r for r in runs_near(park('Ang Mo Kio Park Connector'), ave6, 40) if len(r) > 1],
            "pcn-seed PARK=Ang Mo Kio Park Connector, vertices within 40 m of OSM Ang Mo Kio Avenue 6", **ROADSIDE),
    "2024-06-09", "2028-12-31", "North-South Corridor and MRT works. Notice says end 2028; 31 Dec 2028 used.", PCN)
a5 = park('Ang Mo Kio Ave 5 Park Connector')
j = nearest_vertex(a5, ave6)
add("amk-ave5-diversion", "Ang Mo Kio Ave 5 Park Connector at Ave 6",
    circles([r for r in runs_near(a5, [[j, j]], 150) if len(r) > 1] or [[j]],
            "pcn-seed PARK=Ang Mo Kio Ave 5 Park Connector, within 150 m of its nearest point to OSM Ang Mo Kio Avenue 6", **ROADSIDE),
    "2023-04-25", "2028-04-30", "Diverted to an interim path for North-South Corridor works.", PCN)
add("kallang-pc-st-michaels", "Kallang Park Connector near St Michael's estate",
    circles([r for r in runs_near(park('Kallang Park Connector'), osm_name("Saint Michael's Road"), 200) if len(r) > 1],
            "pcn-seed PARK=Kallang Park Connector, vertices within 200 m of OSM Saint Michael's Road"),
    "2024-10-21", "2027-12-31", "Construction. Notice says 2H 2027; 31 Dec 2027 used.", PCN)
aq = park('Alexandra Queensway PC')
add("alexandra-queensway-pc", "Alexandra–Queensway Park Connector",
    circles(aq, "pcn-seed PARK=Alexandra Queensway PC, whole connector (notice names no end roads)"),
    "2025-09-15", "2027-09-30", "Upgrading; alternative-route map provided. Notice says Q3 2027; last day of Q3 used.", PCN)
bd = park('Bedok Park Connector')
add("bedok-pc-laguna88", "Bedok Park Connector, Laguna88 to Upper East Coast Rd",
    circles([stretch(bd, (1.321762, 103.958573), nearest_vertex(bd, osm_name('Upper East Coast Road')))],
            "pcn-seed PARK=Bedok Park Connector, between OneMap LAGUNA 88 (46 Eastwood Rd) and OSM Upper East Coast Road", **ROADSIDE),
    None, "2026-12-31", "Thomson-East Coast Line works; diversion signed.", PCN)
add("bedok-pc-greenopal", "Bedok Park Connector near Bedok Reservoir View / Tampines GreenOpal",
    circles([[min((v for l in bd for v in l), key=lambda v: dist(v, q)) for q in [(1.336463, 103.937895), (1.336687, 103.939117)]]],
            "straight line between the pcn-seed PARK=Bedok Park Connector vertices nearest OneMap 772 Bedok Reservoir View and 965D Tampines St 96 (the bridge)"),
    None, "2026-12-31", "Bridge works; diversion signed.", PCN)
add("gbtb-waterfront-promenade", "Gardens by the Bay Waterfront Promenade",
    circles(osm_ids({1535166327, 528526115, 1524332359, 1524336103, 1524333447}),
            "OSM ways 1535166327,528526115,1524332359,1524336103,1524333447 (construction, bicycle=no)"),
    "2026-05-04", None, "Bay South to Bay East bridge works. Detour round the Bay South perimeter. No end date.",
    "https://littlebigreddot.com/gardens-by-the-bay-cycling-diversion-4-may-2026/")
bb = ppp[0]['bounds']
add("punggol-point-park", "Punggol Point Park",
    [{"lat": round((bb['minlat'] + bb['maxlat']) / 2, 6), "lon": round((bb['minlon'] + bb['maxlon']) / 2, 6), "radius_m": 150,
      "coord_source": "OSM way 180909679 (Punggol Point Park), centre of bounds"}],
    "2026-08-11", "2027-12-31", "Park and carpark closed; toilets stay open. Use the Punggol Waterfront toilet and cooler. End date is approximate.",
    "https://pcn.nparks.gov.sg/files/6_Jul_2026_Punggol_Point_Park___park_closure_sign__003_.pdf")

# --- no cycling (walk your bike) ---
ROADS = [[(p['lat'], p['lon']) for p in e['geometry']] for e in osm
         if e['tags'].get('highway') in ('primary', 'secondary', 'tertiary', 'residential', 'trunk', 'unclassified')]
def nc(id, name, lines, src, url=RULES, note="Walk your bike."):
    # A bridge over a road (Henderson Waves) mustn't tell drivers below to walk.
    cs = [c for c in circles(lines, src) if to_lines(ROADS, (c['lat'], c['lon'])) > c['radius_m']]
    add(id, name, cs, None, None, note, url, kind="no_cycling")
for id, name, osmname in [("henderson-waves", "Henderson Waves", "Henderson Waves Bridge"),
                          ("kent-ridge-canopy-walk", "Kent Ridge Canopy Walk", "Canopy walk"),
                          ("telok-blangah-forest-walk", "Telok Blangah Forest Walk", "Forest Walk"),
                          ("berlayer-creek-boardwalk", "Berlayer Creek boardwalk", "Berlayer Creek Broadwalk"),
                          ("bukit-chermin-boardwalk", "Bukit Chermin boardwalk", "Bukit Chermin Boardwalk"),
                          ("punggol-kelong-bridge", "Kelong Bridge, Punggol", "Kelong Bridge"),
                          ("punggol-wave-bridge", "Wave Bridge, Punggol", "Wave Bridge"),
                          ("punggol-adventure-bridge", "Adventure Bridge, Punggol", "Adventure Bridge")]:
    nc(id, name, osm_name(osmname), f"OSM ways name={osmname}")
nc("changi-boardwalk", "Changi Boardwalk", osm_name('Changi Village Coastal Walk') + osm_name('Changi Village Coastal Walk (Kelong Walk)') + osm_name('Creek Wall Boardwalk'),
   "OSM ways name=Changi Village Coastal Walk / (Kelong Walk) / Creek Wall Boardwalk")
# Junction trim: a closure circle touching another connector would close that connector
# too (or the crossing). Drop it: better a few metres under-closed than a false closure.
own = {"loyang-pc": "Loyang Park Connector", "amk-ave6-pc": "Ang Mo Kio Park Connector", "amk-ave5-diversion": "Ang Mo Kio Ave 5 Park Connector",
       "kallang-pc-st-michaels": "Kallang Park Connector", "alexandra-queensway-pc": "Alexandra Queensway PC",
       "bedok-pc-laguna88": "Bedok Park Connector", "bedok-pc-greenopal": "Bedok Park Connector", "rail-corridor-south": None}
for e in out:
    if e['id'] not in own: continue
    others = [v for f in seed['features'] if f['properties'].get('PARK', '').strip() != own[e['id']] for l in feat_lines(f) for v in l]
    keep = [c for c in e['circles'] if all(dist(v, (c['lat'], c['lon'])) > c['radius_m'] + 5 for v in others
                                           if abs(v[0] - c['lat']) < 0.001)]
    print(f"  trimmed {e['id']}: {len(e['circles'])} -> {len(keep)}"); assert keep, e['id']; e['circles'] = keep

# False-alarm report: seed vertices of *other* connectors inside each entry's circles.
for e in out:
    stray = {}
    for f in seed['features']:
        pk = f['properties'].get('PARK', '').strip()
        if pk == own.get(e['id']): continue
        n = sum(1 for l in feat_lines(f) for v in l if any(dist(v, (c['lat'], c['lon'])) <= c['radius_m'] for c in e['circles']))
        if n: stray[pk] = stray.get(pk, 0) + n
    if stray: print("  other connectors inside", e['id'], stray)
json.dump(out, open(sys.argv[4], 'w'), indent=1, ensure_ascii=False)
print(len(out), "entries,", sum(len(e['circles']) for e in out), "circles")
