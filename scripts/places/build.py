"""Bundled places for offline search and Leisure sights.

Reads an Overpass JSON dump of named Singapore places (scripts/places/places.ql)
and writes cyclingskibidi/places.json: [{name, category, lat, lon, address}].
Network is used only here, at build time; the app never goes online.

    curl -s -A pcn-places-build --data-urlencode data@scripts/places/places.ql https://overpass-api.de/api/interpreter > raw.json
    python3 scripts/places/build.py raw.json
"""
import json, os, sys

OUT = os.path.join(os.path.dirname(__file__), "../../cyclingskibidi/places.json")

def category(t):
    leisure, tourism, amenity = t.get("leisure"), t.get("tourism"), t.get("amenity")
    if leisure == "park": return "park"
    if leisure == "nature_reserve": return "nationalPark"
    if t.get("natural") == "beach": return "beach"
    if leisure in ("marina", "stadium"): return leisure
    if tourism == "theme_park": return "amusementPark"
    if tourism in ("museum", "aquarium", "zoo", "attraction", "viewpoint"): return tourism
    if amenity == "food_court": return "hawker"
    if amenity == "place_of_worship": return "worship"
    if amenity in ("library", "cafe"): return amenity
    if t.get("railway") == "station": return "station"
    if t.get("shop") == "mall": return "mall"
    return None

out, seen = [], set()
for e in json.load(open(sys.argv[1]))["elements"]:
    t = e.get("tags", {})
    lat = e.get("lat") or e.get("center", {}).get("lat")
    lon = e.get("lon") or e.get("center", {}).get("lon")
    cat, name = category(t), t.get("name:en") or t.get("name")
    if not (cat and name and lat and lon): continue
    key = (name.lower(), cat, round(lat, 3), round(lon, 3))
    if key in seen: continue
    seen.add(key)
    addr = " ".join(x for x in (t.get("addr:housenumber"), t.get("addr:street")) if x)
    out.append({"name": name, "category": cat, "lat": round(lat, 6), "lon": round(lon, 6), "address": addr})
out.sort(key=lambda p: (p["category"], p["name"]))
json.dump(out, open(OUT, "w"), ensure_ascii=False, separators=(",", ":"))
print(len(out), "places ->", OUT)
