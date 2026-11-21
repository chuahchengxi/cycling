# Offline map data

Everything the app's map and routing need ships in the bundle; the app never goes online.
These scripts rebuild it from OpenStreetMap (run on a Mac with a connection):

```sh
python3 -m venv .venv && .venv/bin/pip install osmium shapely numpy pillow
curl -A pcn-map-build -o sg.osm.pbf https://download.bbbike.org/osm/bbbike/Singapore/Singapore.osm.pbf
.venv/bin/python -I scripts/map/extract.py sg.osm.pbf layers.pickle   # ~25 s
.venv/bin/python -I scripts/map/roads.py layers.pickle                # cyclingskibidi/roads.bin, ~10 s
.venv/bin/python -I scripts/map/tiles.py layers.pickle                # cyclingskibidi/tiles.pack, ~4 min
```

- `roads.bin` (~11 MB): cyclable ways as a directed graph, read by `RoadGraph.swift`.
- `tiles.pack` (~45 MB): z11-16 raster tiles, read by `TilePack` in `OfflineMap.swift`; deeper zooms are scaled from z16.
- The `*.ql` files are the equivalent Overpass queries, if the extract download is unavailable.
- Credit: © OpenStreetMap contributors (ODbL). It is shown on every map and in Credits.
