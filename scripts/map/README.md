# Offline map data

Everything the app's map and routing need ships in the bundle; the app never goes online.
These scripts rebuild it from OpenStreetMap (run on a Mac with a connection):

```sh
python3 -m venv .venv && .venv/bin/pip install osmium shapely numpy pillow
curl -A pcn-map-build -o sg.osm.pbf https://download.bbbike.org/osm/bbbike/Singapore/Singapore.osm.pbf
.venv/bin/python -I scripts/map/extract.py sg.osm.pbf layers.pickle   # ~25 s
.venv/bin/python -I scripts/map/roads.py layers.pickle                # cyclingskibidi/roads.bin, ~10 s
.venv/bin/python -I scripts/map/nobike.py layers.pickle               # cyclingskibidi/nobike.json, ~2 s
.venv/bin/python -I scripts/map/nobike.py --check                     # its self-checks, no data needed
.venv/bin/python -I scripts/map/tiles.py layers.pickle                # cyclingskibidi/tiles.pack, ~4 min
.venv/bin/python -I scripts/places/build.py layers.pickle             # cyclingskibidi/places.json + places_overlay.json, ~5 s
.venv/bin/python -I scripts/places/build.py --check                   # its self-checks, no data needed
```

- `roads.bin` (~11 MB): cyclable ways as a directed graph, read by `RoadGraph.swift`.
- `nobike.json` (~1.6 MB): expressways, steps and `bicycle=no` ways, plus the points where they meet rideable roads, read by `NoBike.swift` for the safety checks.
- `places.json` (~1.5 MB, ODbL): named places in Singapore (the extract also covers Johor; build.py clips at the OSM Singapore–Malaysia boundary), plus toilets, water, shelters and bike amenities within 1 km of a park connector, read by `Discovery.swift`. `places_overlay.json` is our own research (`scripts/places/overlay.src.json`), keyed by OSM ID.
- `tiles.pack` (~45 MB): z11-16 raster tiles, read by `TilePack` in `OfflineMap.swift`; deeper zooms are scaled from z16.
- The `*.ql` files are the equivalent Overpass queries, if the extract download is unavailable.
- Credit: © OpenStreetMap contributors (ODbL). It is shown on every map and in Credits.

## Committing rebuilt data

The bundled data files (`*.bin`, `*.pack`, `pcn-seed.geojson`) are stored with Git LFS
(see `.gitattributes`), so history only holds small pointers. Run `git lfs install` once
per machine before cloning or pulling, or Xcode bundles the pointer text instead of the data.

- Same input, same bytes: rebuilding from the same `layers.pickle` changes nothing, so git
  sees no diff. Only a fresh OSM download changes the files.
- Commit data on purpose, in its own commit (`data: refresh map from OSM <date>`, and
  `data: no-bike ways from OSM <date>` for `nobike.json`), not with code. `nobike.json` is
  plain JSON, so it stays diffable and is not in LFS. If a rebuild was just for testing,
  `git restore cyclingskibidi/roads.bin cyclingskibidi/tiles.pack cyclingskibidi/nobike.json`.
- `sg.osm.pbf`, `layers.pickle` and `.venv/` are git-ignored.
