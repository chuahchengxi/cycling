# OSM tags for Singapore rider personas, ODbL obligations, and persona categories in comparable apps

Method note: The Singapore counts below come from live Overpass API `out count` queries I ran on 2026-11-20 (OSM base timestamp 2026-11-20T12:05-12:13Z) against `area["ISO3166-1"="SG"][admin_level=2]` on the public endpoint https://overpass-api.de/api/interpreter. Format: total (nodes / ways / relations). They are a snapshot and will drift. Taginfo was not consulted directly; Geofabrik publishes per-extract taginfo, see https://download.geofabrik.de/asia/malaysia-singapore-brunei.html.

All example queries use this header:

```
[out:json][timeout:120];
area["ISO3166-1"="SG"][admin_level=2]->.sg;
// ...category block...
out center tags;
```

For "near the PCN", replace `(area.sg)` with `(around.pcn:300)` after building the PCN set, for example:
`rel(area.sg)[route=bicycle][ref=PCN]; way(r)->.pcn;` or, more robustly, `way(area.sg)[highway=cycleway]->.pcn;`. The OSM Singapore page documents PCN relations tagged `name=Park Connector Network, network=rcn, ref=PCN, route=bicycle, type=route`, and says the tagging scheme is still a proposal and under discussion, so do not rely on the relations being complete — [OSM Wiki: Singapore](https://wiki.openstreetmap.org/wiki/Singapore).

## Q1. Exact OSM tags and Overpass queries per category in Singapore, with coverage quality

### Takeaway
Every persona can be served from standard OSM tags. Coverage in Singapore is strong for parks (932), playgrounds (2,464), shelters (2,103), canals (619 ways), food courts (813) and places of worship (654, 92% with `religion`). It is thin or useless for architecture (`building:architecture` = 0, `architect` = 16), `heritage=*` (34), bicycle repair stations (13) and drinking water (226). Hawker centres are not tagged consistently. Treat them as `amenity=food_court` or `amenity=marketplace` combined with a name regex, and ideally cross-check against the government NEA hawker centre list.

### Cited Findings

**Live Singapore counts (Overpass, 2026-11-20)** — source for all counts: own queries against [Overpass API](https://overpass-api.de/api/interpreter) (OSM data © OpenStreetMap contributors, ODbL)

| Tag | Total | n / w / r |
|---|---|---|
| amenity=food_court | 813 | 702 / 109 / 2 |
| amenity=food_court + name~"Hawker\|Food Centre\|Market" | 117 | 74 / 41 / 2 |
| amenity=marketplace | 72 | 44 / 26 / 2 |
| any feature with name~"Hawker Centre\|Food Centre" (any tag) | 171 | 99 / 67 / 5 |
| amenity=food_court + wikidata | 5 | |
| amenity=cafe | 1,874 | 1808 / 65 / 1 |
| amenity=toilets | 898 | 740 / 158 / 0 |
| amenity=drinking_water | 226 | 226 / 0 / 0 |
| man_made=water_tap | 23 | |
| amenity=shelter | 2,103 | 702 / 1397 / 4 |
| amenity=bicycle_repair_station | 13 | |
| amenity=bicycle_parking | 741 | 653 / 87 / 1 |
| amenity=bicycle_rental | 157 | 139 / 18 / 0 |
| leisure=playground | 2,464 | 578 / 1882 / 4 |
| playground=splash_pad | 12 | 0 / 12 / 0 |
| leisure=splash_pad | 0 | |
| leisure=water_park | 8 | |
| leisure=park | 932 | 9 / 880 / 43 |
| leisure=nature_reserve | 8 | 0 / 1 / 7 |
| tourism=viewpoint | 135 | 131 / 4 / 0 |
| tourism=attraction | 445 | 340 / 103 / 2 |
| tourism=attraction + wikidata | 16 | |
| tourism=* + wikidata | 136 | |
| tourism=museum | 77 | 45 / 30 / 2 |
| tourism=artwork | 473 | 456 / 16 / 1 |
| historic=* | 377 | 302 / 75 / 0 |
| historic=memorial | 111 | |
| heritage=* | 34 | |
| amenity=place_of_worship | 654 | 74 / 571 / 9 |
| ... with religion=* | 602 | |
| building:architecture=* | 0 | |
| architect=* | 16 | |
| any feature with wikipedia=* | 3,282 | |
| man_made=bridge (outlines) | 360 | 0 / 319 / 41 |
| footway/cycleway/path ways with bridge=yes | 2,818 | |
| ... of which named | 316 | |
| water=reservoir | 45 | 0 / 32 / 13 |
| natural=wetland | 120 | |
| natural=beach | 111 | |
| waterway=canal (ways) | 619 | |
| waterway=river (ways) | 287 | |

**Bridges (nature/photo)**
- `man_made=bridge` is drawn as an area outline that groups all features of a bridge. The road or path ways that cross it carry `bridge=*` and connect to the outline. The wiki says "If the bridge has a specific name it would be added to the outline" — [OSM Wiki: Tag:man_made=bridge](https://wiki.openstreetmap.org/wiki/Tag:man_made=bridge)
- Pitfall: most `bridge=yes` ways are anonymous segments. Only 316 of 2,818 path, cycleway or footway bridge ways in Singapore carry a name. Use named `man_made=bridge` outlines (360) as the point-of-interest layer, and use `bridge=yes` + `name` as a fallback. Deduplicate them, because the name can appear on both.
- Query: `( nwr(area.sg)[man_made=bridge][name]; way(area.sg)[bridge][highway~"^(footway|cycleway|path|pedestrian)$"][name]; );`
- VisitSingapore-adjacent guides list heritage bridges along the Singapore River ride (Alkaff, Anderson, Elgin, Coleman, Ord) — [Changi Airport Now Boarding](https://nowboarding.changiairport.com/explore-singapore/best-nature-parks-for-cycling-singapore.html)

**Water, wetland, beach, parks, viewpoints (nature/photo)**
- Queries: `way(area.sg)[waterway~"^(canal|river)$"][name];` · `nwr(area.sg)[natural=water][water=reservoir];` (45) · `nwr(area.sg)[natural=wetland];` (120) · `nwr(area.sg)[natural=beach];` (111) · `nwr(area.sg)[tourism=viewpoint];` (135) · `nwr(area.sg)[leisure~"^(park|nature_reserve)$"];`
- Pitfall: Singapore's drainage canals are `waterway=canal` (619 ways vs 287 river ways). Many are concrete monsoon drains rather than scenic. Filter to named ones and prefer those running alongside a PCN.
- Pitfall: `leisure=nature_reserve` exists on only 8 objects (mostly relations, e.g. the large reserves). Small nature parks are tagged `leisure=park` instead. For the photo persona, use parks + water + viewpoints rather than reserves.
- Pitfall: parks are mostly areas (880 ways, 43 relations). Use `out center` so you get a point per park.
- The Singapore wiki page documents `leisure=park` for park boundaries and `leisure=playground` for playgrounds — [OSM Wiki: Singapore](https://wiki.openstreetmap.org/wiki/Singapore)

**Food (hawker centres, food courts, markets, restaurants, cafés)**
- `amenity=food_court` is defined as a place with sit-down facilities shared by multiple self-service food vendors. Its recommended companions are `name`, `opening_hours`, `operator` and `addr:*` — [OSM Wiki: Tag:amenity=food_court](https://wiki.openstreetmap.org/wiki/Tag:amenity=food_court)
- A Singapore example: Marine Parade Food Centre is a node tagged `amenity=food_court` with an operator, diet and Chinese-name tags — [OSM node 5790566706](https://www.openstreetmap.org/node/5790566706) (as summarised by search; not opened directly)
- No Singapore-specific OSM rule for hawker centres was found. The WikiProject Singapore page lists food courts under points of interest but gives no hawker or kopitiam guidance — [OSM Wiki: Singapore](https://wiki.openstreetmap.org/wiki/Singapore)
- Observed usage: of 813 `amenity=food_court` objects, only 117 have hawker-style names. The rest are mall food courts (Kopitiam, Food Republic and similar chains) and HDB coffee shops. 171 objects across all tags carry "Hawker Centre" or "Food Centre" in the name, which means roughly 50+ use a tag other than food_court (likely `amenity=marketplace`, building outlines, or `amenity=restaurant`). Source: own Overpass counts above.
- Official names vary: "Hawker Centre", "Food Centre", and "Market & Food Centre" (e.g. ABC Brickworks Market & Food Centre). Some centres are run by NEA and some by town councils — [NEA list of hawker centres, Aug 2026](https://www.nea.gov.sg/docs/default-source/hawker-centres-documents/list-of-hcs_-17-august-2026.pdf); dataset also on [data.gov.sg](https://data.gov.sg/dataset/hawker-centres)
- Breakdown of the 171 "Hawker Centre|Food Centre"-named objects by amenity (own Overpass CSV query): food_court 89 (50 nodes, 37 ways, 2 relations), **restaurant 26** (e.g. Empress Road Food Centre, Tanjong Pagar Food Centre, People's Park Food Centre), marketplace 6, fast_food 2, cafe 1, and one even mis-tagged `amenity=taxi` (Blk 90 Food Centre). About 44 have no amenity. Many of those are **bus stops named after the centre** (e.g. "Opposite Newton Food Centre", "Before Sembawang Hills Food Centre", "Pasir Panjang Station/Food Centre"), and the rest are building outlines. Many carry `name:zh` with **熟食中心** ("cooked food centre"), which is a useful secondary signal. Some names use the "Market/Food Centre" form (e.g. "Blk 105 Market/Food Centre"). Source: [Overpass API](https://overpass-api.de/api/interpreter) query, 2026-11-20.
- Recommended query:
  ```
  ( nwr(area.sg)[amenity~"^(food_court|marketplace|restaurant)$"][name~"Hawker|Food Centre|Market",i];
    nwr(area.sg)["name:zh"~"熟食中心"][amenity]; );
  // exclude bus stops: drop anything with highway=bus_stop / public_transport=*, or name starting "Opp"/"Before"/"After"
  ```
  Pitfall: an unanchored global name regex is slow and timed out at 145 s on the public server. Run it per small bbox or `around` the PCN, not island-wide.
- Cafés: `amenity=cafe` has 1,874 objects, mostly nodes. Coffee shops (kopitiam) may be tagged `amenity=food_court`, `amenity=cafe`, or `amenity=restaurant` + `cuisine=*`. Treat the split as unreliable.
- `amenity=restaurant` count was not captured (query omitted in the batch).

**Architecture**
- `building:architecture=*` has 0 objects in Singapore and `architect=*` has 16. Neither is usable as a primary signal. Source: own Overpass counts.
- Practical proxy: `tourism=attraction`, `building~"^(church|cathedral|temple|mosque|civic|government)$"` with a name, `historic=building`, or `wikidata=*` on a `building=*`. Then curate by hand. Example: `nwr(area.sg)[building][wikidata][name];`
- Gap: Singapore's architecturally notable modern buildings (e.g. PCN-adjacent bridges like the Henderson Waves or the Helix) would need to be curated manually or matched to Wikidata (`P84 architect`) offline.

**Heritage**
- Queries: `nwr(area.sg)[historic];` (377) · `nwr(area.sg)[historic=memorial];` (111) · `nwr(area.sg)[heritage];` (34) · `nwr(area.sg)[tourism=museum];` (77) · `nwr(area.sg)[amenity=place_of_worship][religion];` (602 of 654)
- Pitfall: `heritage=*` is sparse (34). Singapore's ~70+ gazetted national monuments are not systematically tagged. Use `historic=*` and `wikidata`, and cross-reference against the URA/NHB lists if available.
- Pitfall: places of worship are mostly building outlines (571 ways). `religion` is present on 92% of them (602/654), so you can split temple, church, mosque, gurdwara and synagogue reliably. `denomination` coverage was not measured.
- Pitfall: `historic=memorial` includes small plaques. Filter with `[name]` and optionally `memorial!=plaque`.

**Tourists**
- Queries: `nwr(area.sg)[tourism~"^(attraction|museum|viewpoint|artwork|gallery|zoo|theme_park)$"];` and a notability boost for `[wikidata]` or `[wikipedia]`.
- Only 16 of 445 `tourism=attraction` objects carry `wikidata`, and 136 `tourism=*` objects do in total. However, 3,282 Singapore objects of any kind carry `wikipedia=*`. So `wikidata` or `wikipedia` on any feature (park, bridge, building, place of worship) is a broader notability signal than `tourism=attraction` itself. Source: own Overpass counts.
- `tourism=artwork` (473, mostly nodes) is a ready-made layer for an art/murals persona.

**Families**
- Queries: `nwr(area.sg)[leisure=playground];` (2,464, mostly areas) · water play: `nwr(area.sg)[playground=splash_pad];` (12) · `nwr(area.sg)[leisure=water_park];` (8) · `leisure=splash_pad` has 0.
- Pitfall: playgrounds are very common, because almost every HDB block has one, so they are low-signal. Rank by inclusion in a `leisure=park` or by `name`. Water play coverage is very incomplete. Public water playgrounds in parks (e.g. Jacob Ballas, Admiralty, Punggol Waterway) need manual curation or a name regex such as `name~"water play",i`.

**Rest stops**
- Queries: `nwr(area.sg)[amenity~"^(toilets|drinking_water|shelter|bicycle_repair_station|bicycle_parking|bicycle_rental)$"];` plus `man_made=water_tap`.
- Counts: toilets 898, drinking_water 226, water_tap 23, shelter 2,103, repair stations 13, bicycle_parking 741, bicycle_rental 157.
- Pitfall: `amenity=bicycle_rental` in Singapore likely includes dockless bike-share parking zones, which are noisy. Check `operator` or `network`, and consider excluding when a feature has no name.
- Pitfall: `amenity=shelter` includes bus-stop shelters (`shelter_type=public_transport`). Exclude them with `[shelter_type!=public_transport]` for rest stops.
- Pitfall: toilets inside malls, hawker centres and MRT stations are often not mapped separately. Treat a hawker centre or mall as an implicit toilet or water stop.
- Strava and Komoot both expose water fountains, toilets and cafés as cyclist POIs, which confirms this is the expected rest-stop set — [BikeRadar on Strava POIs](https://www.bikeradar.com/news/strava-points-of-interest); [TechRadar](https://www.techradar.com/news/strava-now-helps-you-find-a-public-toilet-or-water-fountain-during-a-run-or-ride)

### Inferences
- An offline pipeline should take a Geofabrik PBF, filter it with `osmium tags-filter` to the tag list above, clip it to Singapore and a buffer around the PCN, take `center` points for areas, and write the result to a compact SQLite or JSON file in the bundle. This avoids hitting the public Overpass server, which returned 502 "at capacity" errors repeatedly during this research and timed out on regex queries.
- Persona scoring will need a curated override list (hawker centres from NEA data, water play, architecture) because OSM is weakest exactly on the signals that make a persona distinctive.
- The NEA/data.gov.sg dataset is under the Singapore Open Data Licence, not ODbL. Merging it with OSM in one table may create a derivative database. Keeping them as separate layers that are only joined at display time is the safer "collective database" pattern (see Q2). This is an inference, not legal advice.

### Gaps
- No taginfo per-key counts for Singapore were pulled. The Geofabrik taginfo instance exists for the Malaysia-Singapore-Brunei extract but was not queried.
- The island-wide `amenity=restaurant` count was not retrieved, because Overpass was at capacity.
- No authoritative statement on what share of NEA's ~120 hawker centres are mapped. A cross-match against the NEA list is needed.
- No OSM Singapore community convention for kopitiam or coffee-shop tagging was found.

## Q2. ODbL obligations for an app bundling OSM data, and export options

### Takeaway
You must credit "OpenStreetMap" and make clear the data is under ODbL. A link to openstreetmap.org/copyright works, and an About screen is acceptable if a splash or map credit is shown. If you distribute the extract, or a modified or enhanced version of it, inside the app, that data must stay ODbL and be offered on request. Your app code and your separately kept curated data are not pulled in. Geofabrik's Malaysia-Singapore-Brunei PBF (~242 MB) is the practical export source, and Overpass is fine for small one-off pulls.

### Cited Findings
- Attribution must name "OpenStreetMap" and make clear the data is under ODbL. Linking to openstreetmap.org/copyright satisfies this, and "© OpenStreetMap contributors" is acceptable — [OSMF Attribution Guidelines](https://osmfoundation.org/wiki/Licence/Attribution_Guidelines)
- In apps, attribution can be in a map corner, next to the map, or on a splash screen or pop-up. It may collapse or fade after interaction or after 5 seconds, but must remain findable, e.g. via an "(i)" button or an "About" menu. A startup attribution need not be shown every time. If a splash screen cannot link, "the link must be provided in an easily locatable part of the web page, software, or application" — [OSMF Attribution Guidelines](https://osmfoundation.org/wiki/Licence/Attribution_Guidelines)
- For distributed databases, include attribution plus the ODbL text or a link, "such as a readme file, or within the data or metadata." Geocoding or search results need not carry per-result attribution, but the application must credit OSM — [OSMF Attribution Guidelines](https://osmfoundation.org/wiki/Licence/Attribution_Guidelines)
- Derivative Database: "created where you adapt, modify, enhance, correct or extend our data." Collective Database: OSM combined with independent databases, where share-alike does not extend to the independent data. Produced Work: e.g. a rendered map, which can carry any terms. "Where you make our data or any Derivative Database available to others, it must continue to be licensed under the ODbL." For Produced Works you must offer, on request, the data and any Derivative Database, or the means to create them. Private or internal use is not public use — [OSMF Licence and Legal FAQ](https://osmfoundation.org/wiki/Licence/Licence_and_Legal_FAQ)
- The FAQ does not say app code becomes ODbL. Obligations attach to data and databases — [OSMF Licence and Legal FAQ](https://osmfoundation.org/wiki/Licence/Licence_and_Legal_FAQ)
- Geofabrik "asia/malaysia-singapore-brunei" offers a .osm.pbf of about 242 MB, shapefile and GeoPackage zips of about 480-500 MB, a .poly boundary, experimental Shortbread vector tiles, and .osc.gz diffs. It is updated roughly daily and licensed ODbL 1.0. It strips user names and IDs. No Singapore-only extract is offered — [Geofabrik](https://download.geofabrik.de/asia/malaysia-singapore-brunei.html)
- The public Overpass server says it is intended for browser and human-operated tools and recommends a local instance for automated or high-volume use. It returned "502 ... server is currently at capacity" during this research (own observation, [overpass-api.de](https://overpass-api.de/api/interpreter))

### Inferences
- Bundling a filtered POI extract in the app is distributing a (derivative) database. You need an About or licence screen with "© OpenStreetMap contributors, ODbL" and a link, a credit on the map view, and the ability to supply the filtered extract or the filter script on request. Shipping the `osmium` filter command in a repo or on the About page is a cheap way to satisfy "means to create."
- Keep app-authored data (persona labels, curated blurbs, NEA hawker list) in a separate table keyed by OSM ID, rather than editing OSM rows. That keeps it closer to the collective-database pattern, so your own data need not be ODbL. Whether persona scores derived from OSM tags count as "enhancing" OSM is a grey area, so get legal review.
- Export recipe: `osmium extract -p singapore.poly malaysia-singapore-brunei-latest.osm.pbf -o sg.pbf`, then `osmium tags-filter sg.pbf nwr/amenity=food_court,marketplace,toilets,drinking_water,shelter,bicycle_repair_station,bicycle_parking,bicycle_rental nwr/leisure=park,nature_reserve,playground,water_park nwr/tourism nwr/historic nwr/heritage nwr/man_made=bridge,water_tap nwr/natural=water,wetland,beach w/waterway=canal,river -o sg-poi.pbf`, then convert to GeoJSON or SQLite. The Singapore .poly can come from Geofabrik's Singapore boundary or from an Overpass admin relation. This is a suggested workflow; the commands were not executed.

### Gaps
- The OSMF Collective Database and Substantial guidelines were not fetched. They define the thresholds (e.g. "insubstantial" extracts) that might exempt a small POI pull from share-alike.
- No official guidance found specific to offline mobile apps beyond the general attribution guideline.

## Q3. Persona and interest categories in comparable apps, and suggested extra personas

### Takeaway
Comparable apps organise discovery around a few recurring themes: views and scenery, water (beach, lake, river, waterfall), history, food and drink stops, family or kid-friendly, wildlife, and practical POIs (water, toilets, cafés, bike shops). Singapore's own tourism framework adds social and shopping-style "tribes." Good additions beyond the existing seven are: café hoppers, sunset and waterfront, art and murals, beach and coast, wildlife and birding, a night-ride or socialiser persona, and possibly shopping or collectors.

### Cited Findings
- AllTrails "Attractions" filters: Beach, Cave, City walk, Event, Forest, Historic site, Hot springs, Lake, Pub walk, Rails trails, River, Views, Waterfall, Wild flowers, Wildlife. "Suitability" filters: Dog, Kid, Wheelchair, Stroller friendly, Paved, Partially paved. Multiple filters combine with AND — [AllTrails Help: filters](https://support.alltrails.com/hc/en-us/articles/37227964040852-How-to-use-filters-to-find-trails)
- AllTrails collections reportedly include dog-friendly, kid-friendly, among trees, epic views, rivers, lakes, wildflowers, top picks and hidden gems (review source) — [Tom's Guide](https://tomsguide.com/wellness/fitness/i-hiked-5-miles-along-the-california-coast-to-test-alltrails-biggest-update-yet-5-features-that-stood-out-the-most)
- Komoot organises Highlights (community-recommended places and segments) by sport type, and Collections by theme or place (e.g. gravel, bikepacking, regions). Its POI categories include restaurants and cafés, parking, camping and water fountains. These descriptions come from secondary, partly sponsored sources, and no official list of Highlight types was found — [Cycling Weekly](https://www.cyclingweekly.com/news/how-to-find-your-new-adventure-with-komoot); [BikeRadar (sponsored)](https://www.bikeradar.com/advertising-feature/komoot-bikepacking-collections/)
- Strava Points of Interest (since Jan 2022): planning POIs are peaks, landmarks, photo spots, bike shops and popular start points. Usage POIs are water fountains, service stations, cafés and toilets. A Feb 2026 Route Builder redesign reportedly overlays cafés, water fountains, restrooms and aid stations, but this comes from a single unofficial blog — [the5krunner](https://the5krunner.com/2022/01/13/new-strava-pois-live-now/); [BikeRadar](https://www.bikeradar.com/news/strava-points-of-interest); [fitness-apps-review (unverified)](https://fitness-apps-review.pages.dev/blog/strava-february-2026-update)
- Google Maps: "Neighborhood Vibe" (2022) surfaces popular places in an area from community photos and reviews. Gemini "Ask Maps" (2026) groups recommendations into categories and lets users refine by vibe. Reports suggest mood-style labels such as "impressing a date" vs "grabbing a casual bite," but no official category list exists — [Tom's Guide](https://www.tomsguide.com/news/google-maps-next-big-upgrade-lets-you-vibe-check-your-destination); [Search Engine Roundtable](https://www.seroundtable.com/google-gemini-local-results-40741.html); [Tom's Guide on Ask Maps](https://www.tomsguide.com/ai/gemini-in-google-maps-is-better-than-ever-use-these-7-ask-maps-prompts-to-plan-better-trips-and-discover-new-foods)
- STB "Passion Made Possible" Passion Tribes: Foodies, Collectors (shopping/collectibles), Explorers, Progressors, plus Action Seekers, Culture Shapers and Socialisers added in Aug 2018 — [Travel Weekly](https://www.travelweekly.com/Asia-Travel/Passion-priority-Singapore-campaign); [NAS archive: Wave 2 press release](https://www.nas.gov.sg/archivesonline/data/pdfdoc/20180829001/Wave%202%20Press%20Release_29%20August.pdf)
- Singapore cycling editorial content pairs PCN rides with hawker or café stops (e.g. Springleaf Prata near Lower Seletar, Amoy Street via the Rail Corridor, Changi Village) — [LTA Connect: cycling food spots](https://www.lta.gov.sg/content/ltagov/en/who_we_are/statistics_and_publications/Connect/recommended-cycling-food-spots.html). It also pairs them with heritage routes (Rail Corridor stations, Singapore River bridges) — [Seth Lui](https://sethlui.com/cycling-routes-singapore-guide/); and with official loops (Central Urban Loop ~36 km, Changi Jurassic Mile) — [VisitSingapore](https://VisitSingapore.com/editorials/cycling-routes-in-singapore/)

### Inferences (suggested extra personas)
1. **Café hopper**: Strava and Komoot both make cafés a first-class cyclist POI, and Singapore has 1,874 `amenity=cafe`. This is distinct from hawker-focused foodies. Tag: `amenity=cafe` (+ `cuisine=coffee_shop`).
2. **Sunset and waterfront chaser**: this maps to AllTrails "Views" and Strava "photo spots." Singapore's east and west coasts, reservoirs and Marina Bay are classic rides. Tags: `tourism=viewpoint`, `natural=beach`, `water=reservoir`, coastline proximity, with a time-of-day hint.
3. **Art and murals**: 473 `tourism=artwork` objects make this cheap to support, and it is close to STB's "Culture Shapers." Tags: `tourism=artwork` (+ `artwork_type=mural|sculpture`).
4. **Beach and coast**: AllTrails has an explicit Beach filter. Singapore has 111 `natural=beach` (East Coast, Pasir Ris, Changi, Sentosa). This could merge with sunset.
5. **Wildlife and birding**: AllTrails has a Wildlife filter, and Singapore has 120 wetlands and nature reserves (Sungei Buloh, Pasir Ris mangroves). Tags: `natural=wetland`, `leisure=nature_reserve`, `leisure=bird_hide` (not counted).
6. **Night rider or socialiser**: this matches STB's "Socialisers" and Singapore's night-cycling culture. It overlaps with hawker centres, which are often open late. Could be a filter on `opening_hours` rather than a separate persona.
7. **Shopping or collectors** (optional, lower fit for leisure cycling): matches STB's "Collectors." Tags: `shop=mall`, `amenity=marketplace`.
- Kid-friendly, wheelchair and stroller in AllTrails are suitability filters, not personas. "Family" may work better as a route constraint (paved, short, shelters, toilets) than as a destination persona.

### Gaps
- No official Komoot list of Highlight categories, and no official Google list of vibe categories, was found.
- The VisitSingapore site's itinerary-by-passion pages were not reachable (404 on the guessed URL), so current STB itinerary categories as of 2026 are unverified beyond the tribe names.
