# closures.json generator

Rebuild when NParks notices change (LTA/NParks update monthly):

```sh
cd scripts/closures
curl -s -A pcn-closures-build --data-urlencode data@g.ql https://overpass-api.de/api/interpreter > /tmp/geom.json
curl -s -A pcn-closures-build --data-urlencode 'data=[out:json];way(180909679);out geom tags;' https://overpass-api.de/api/interpreter > /tmp/ppp.json
python3 -I build.py ../../cyclingskibidi/pcn-seed.geojson /tmp/geom.json /tmp/ppp.json ../../cyclingskibidi/closures.json
```

Dates, notes and the few OneMap points (Laguna 88, 772 Bedok Reservoir View, 965D Tampines St 96) are in `build.py`.
Every circle's `coord_source` says where it came from. OSM data © OpenStreetMap contributors, ODbL.
