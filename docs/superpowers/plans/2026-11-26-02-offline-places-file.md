# Offline Places File Implementation Plan (plan 2 of 8)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild `places.json` from the shared OSM extract with rest-stop amenities, scenic and heritage categories, OSM IDs, opening hours and shapes; add our own `places_overlay.json` of sourced notes from the research; and make the app keep only places a rider will really pass, that are open when they get there, spread along the whole route.

**Architecture:** `scripts/map/extract.py` also collects points of interest into `layers.pickle`. `scripts/places/build.py` turns them into `cyclingskibidi/places.json` (ODbL) and resolves the hand-written `scripts/places/overlay.src.json` against it by name into `cyclingskibidi/places_overlay.json` (ours, keyed by OSM ID). In the app, `Discovery` loads both: `Sight`s for lists and search, plus a `PlaceFacts` side table (hours, size, shape, overlay note) keyed by OSM ID that the corridor filter and later plans (Kit's picks, rest stops) read.

**Tech Stack:** Python 3 + `osmium` (build time, existing venv from `scripts/map/README.md`), Swift/SwiftUI. No XCTest: Python checks are `assert`s behind `--check`; Swift checks are `selfCheck()` asserts run at launch in DEBUG.

**Spec:** `docs/superpowers/specs/2026-11-20-kit-personalised-places-design.md`, section 1 ("Offline places file") and the overlay fields it lists; constraints section (iOS 18, ODbL).

**The series:** 1 closures (done), **2 places file (this)**, 3 interests + Kit picks, 4 rest stops, 5 scenic slider, 6 offline (done), 7 Kit UI, 8 fall detection.

## Global Constraints

- iOS 18.0 deployment target. No API newer than iOS 18 without `#available` and a fallback.
- Build gate: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme cyclingskibidi -destination 'generic/platform=iOS Simulator' -configuration Debug build` ends `** BUILD SUCCEEDED **`. Ignore SourceKit "Cannot find type" diagnostics.
- Behaviour gate: install and launch on an iOS 27 simulator (see memory `build-command`), or ⌘R. Every `selfCheck()` runs at launch; a clean launch (no "Assertion failed") means they passed.
- The project defaults to MainActor isolation. No blocking async bridges; use fire-and-forget `Task {}`.
- **Never invent coordinates.** Every overlay entry either matches an OSM place by name or carries its own `lat`/`lon` with a `coord_source` URL. Anything else is dropped at build time with a printed warning.
- OSM-derived data stays in `places.json` (ODbL). Our research lives only in `places_overlay.json`, keyed by OSM ID. Do not copy OSM fields into the overlay.
- Dates are whole days, Singapore time; `valid_until` is inclusive. Reuse `Closures.day` and `Closures.sg`.
- Stalls are named only when sourced: Michelin Bib Gourmand 2026 (Tier A in the personas report) or long-established with a cited age (Tier B). Tier C and anything tagged `[unverified-loc]` keep the dish, never the stall.
- Rider-facing text spells out "park connector" and "hawker centre", never "PC" or "HC".
- Data commits follow `scripts/map/README.md`: rebuilt data in its own commit, `data: refresh places from OSM <yyyy-mm-dd>`.
- The app makes no network requests.

## Review Focus

1. **An `opening_hours` value the parser doesn't understand** (`sunrise-sunset`, `PH off`, `Mo-Fr 08:00-17:00 "by appointment"`) must leave the place in, treated as open, never dropped. Test in Task 1 (`parse_hours`).
2. **Hours that cross midnight** (`18:00-02:00`, common at hawker centres and Changi Village) must count as open at 01:00 the next day. Tests in Task 1 (split into two days) and Task 3 (`isOpen`).
3. **Routes saved before this plan** hold `Sight`s with no `osmID`. They must still decode and show. Test in Task 3.
4. **An overlay name that matches two OSM places** (two "Ang Mo Kio Park" ways) must not attach the note to the wrong one. It is skipped with a warning. Test in Task 2.
5. **A long route whose sights bunch near the start** must still show places along the whole line, not 20 from the first few km. Test in Task 4.

---

### Task 1: Places from the shared OSM extract

**Files:**
- Modify: `scripts/map/extract.py` (collect POIs into the pickle)
- Rewrite: `scripts/places/build.py`
- Delete: `scripts/places/places.ql`
- Modify: `scripts/map/README.md` (add the places step after `tiles.py`)
- Data: `cyclingskibidi/places.json`

**Interfaces:**
- Produces `layers.pickle["pois"]`: list of `(osm_id: str, tags: dict, lon: float, lat: float, shape: list[(lon, lat)], area_m2: float)`. `osm_id` is `"n123"`, `"w123"` or `"r123"` (osmium areas: `w` if `a.from_way()` else `r`, plus `a.orig_id()`). Points have `shape=[]`, `area_m2=0`; areas give their outer ring and its area; named `waterway=river|canal` lines give their points and `area_m2=0`. `lon/lat`: node location, area outer-ring centroid, or a line's middle vertex.
- Produces `cyclingskibidi/places.json`: a JSON array, **one record per line**, sorted by `id` (deterministic and delta-friendly in git). Record:
  `{"id": "w123", "name": "...", "category": "...", "lat": 1.234567, "lon": 103.123456, "address": "...", "hours": [[day, from, to], ...], "wiki": true, "area": 12345, "shape": [[lat, lon], ...]}`
  `hours`, `wiki`, `area`, `shape` are omitted when empty or false. Coordinates are rounded to 6 places. `day` 0 = Monday … 6 = Sunday; `from`/`to` are minutes 0–1440. `shape` is present only for areas ≥ 10 000 m² and for waterways, thinned to at most 16 points (keep every k-th point plus the last).
- Category rules, first match wins (existing names are kept so saved routes still map):

| Category | OSM tags | Name needed |
|---|---|---|
| existing 17 (`park` … `mall`) | as in today's `category()` | yes |
| `hawker` (extended) | `amenity=food_court`; or `amenity=marketplace\|restaurant` whose name matches `hawker\|food cent(re\|er)\|market\|food village` (case-insensitive) | yes |
| `bridge` | `man_made=bridge` | yes |
| `waterway` | `waterway=river\|canal` (lines) | yes |
| `reservoir` | `landuse=reservoir\|basin`, `natural=water\|wetland` | yes |
| `heritage` | any `historic=*` | yes |
| `artwork` | `tourism=artwork` | yes |
| `playground` | `leisure=playground` | no ("Playground") |
| `toilets` | `amenity=toilets` | no ("Toilets") |
| `drinkingWater` | `amenity=drinking_water\|water_point`, `man_made=water_tap` | no ("Drinking water") |
| `shelter` | `amenity=shelter`, except `shelter_type=public_transport` or `highway=bus_stop` | no ("Shelter") |
| `repair` | `amenity=bicycle_repair_station` | no ("Bike repair station") |
| `bikeParking` | `amenity=bicycle_parking` | no ("Bike parking") |
| `bikeRental` | `amenity=bicycle_rental` | no ("Bike rental") |

  Unnamed places take the label in brackets as their name. The categories that need no name are kept only within 1 000 m of a PCN vertex (`cyclingskibidi/pcn-seed.geojson`, checked with a ~0.01° grid of PCN vertices). Named places are kept island-wide, because start and destination search uses them. *My call:* the spec's ~1 km rule is meant to keep the file small, and the unnamed amenities are what makes it big.
- Dedupe as today (name, category, lat and lon to 3 places).
- *My call:* hawker centres are recognised by tag and name; the spec's cross-check against NEA's hawker list is left out, because that list needs a download the build doesn't otherwise make. Add it if non-hawker "markets" show up.

- [ ] **Step 1: Write the failing checks** in `scripts/places/build.py` under `if "--check" in sys.argv:`, with no pickle needed:

```python
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
print("places checks passed")
```

- [ ] **Step 2: Run it to see it fail**

Run: `.venv/bin/python -I scripts/places/build.py --check`
Expected: FAIL (`NameError: parse_hours`).

- [ ] **Step 3: Implement** in `scripts/places/build.py`: `category(tags: dict) -> str | None` (the table above), `parse_hours(s: str) -> list[list[int]] | None`, `thin(points: list, n: int) -> list`, and the main run `build.py layers.pickle`.
  `parse_hours` grammar: rules split on `;`. Each rule is an optional day part (`Mo`…`Su`, comma lists and `A-B` ranges, wrapping allowed: `Fr-Mo`) then either `off` or comma-separated `HH:MM-HH:MM` spans. A rule with no day part applies to all days. A later rule replaces earlier spans for the days it names. A span ending before it starts is split at midnight onto the next day. Rules starting with `PH` or `SH` are skipped. Any other token means the whole value is unknown: return `None`. Return the list sorted by `(day, from)`, or `None` for `24/7`. Then: `extract.py` gains the POI collection described above (tags kept: `name`, `name:en`, `amenity`, `leisure`, `tourism`, `historic`, `man_made`, `waterway`, `landuse`, `natural`, `shop`, `railway`, `station`, `shelter_type`, `highway`, `opening_hours`, `wikipedia`, `wikidata`, `addr:housenumber`, `addr:street`).

- [ ] **Step 4: Run the checks**

Run: `.venv/bin/python -I scripts/places/build.py --check`
Expected: `places checks passed`.

- [ ] **Step 5: Build the data**, following `scripts/map/README.md` (download `sg.osm.pbf`, run `extract.py`, then `build.py`)

Run: `.venv/bin/python -I scripts/places/build.py layers.pickle`
Expected: a printed count per category, every category in the table above non-zero, `toilets` and `drinkingWater` in the hundreds or more, total under 4 MB. Run it twice: `git diff --stat cyclingskibidi/places.json` shows no change between the two runs.

- [ ] **Step 6: Commit** (code first, then data in its own commit)

```bash
git add scripts/map/extract.py scripts/places/build.py scripts/map/README.md && git rm scripts/places/places.ql
git commit -m "feat(places): build places from the shared OSM extract"
git add cyclingskibidi/places.json && git commit -m "data: refresh places from OSM <yyyy-mm-dd>"
```

(The app still decodes the old fields, so it keeps building between this task and Task 3.)

---

### Task 2: Our research overlay

**Files:**
- Create: `scripts/places/overlay.src.json` (hand-written from the reports)
- Modify: `scripts/places/build.py` (resolve and write the overlay)
- Data: `cyclingskibidi/places_overlay.json`

**Interfaces:**
- Consumes: Task 1's records (`id`, `name`, `category`).
- Source entry (`overlay.src.json`, an array):
  `{"match": {"name": "Tiong Bahru Market", "category": "hawker"}, "persona": ["food"], "reasons": [], "status": "open", "valid_until": null, "dishes": ["fried sotong prawn mee", "boneless chicken rice"], "stalls": [{"name": "Tiong Bahru Hainanese Boneless Chicken Rice", "bib": 2026}], "best_time": "early morning to afternoon", "note": "One sourced line.", "source": "https://..."}`
  Hand-added places (not in OSM) use `"name"`, `"category"`, `"lat"`, `"lon"`, `"coord_source"` instead of `match`. Tier B stalls use `{"name": ..., "since": 1971}` in place of `bib`.
- Vocabularies. `persona`: `nature`, `food`, `architecture`, `heritage`, `wildlife`, `art`, `cafe`, `kids`, `visiting`, `quiet`. `reasons`: `crowded_weekend`, `crowded_evening`, `dismount`, `no_water`, `limited_food`, `park_and_walk`. `status`: `open` or `closed`.
- Produces `cyclingskibidi/places_overlay.json`: an object keyed by OSM ID (or `x-<slug>` for hand-added places), each value the source entry without `match`, one key per line, sorted. Hand-added values keep `name`, `category`, `lat`, `lon`. Slug: the name lower-cased, each run of non-alphanumerics replaced by `-`, trimmed of `-`.
- Matching: name compared case- and accent-insensitively, after expanding a trailing "HC" to "Hawker Centre" and "FC" to "Food Centre" in the source name. It must equal the OSM name **and** category must match. Exactly one hit: attach. Zero or several hits: print `UNRESOLVED <name>` / `AMBIGUOUS <name> (<n> places)` and skip.

- [ ] **Step 1: Write the failing checks** (added to the `--check` block)

```python
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
assert "x-sourced-spot" in out and not any(k.startswith("x-keppel") for k in out)   # no coord_source, no entry
```

- [ ] **Step 2: Run it to see it fail**

Run: `.venv/bin/python -I scripts/places/build.py --check`
Expected: FAIL (`NameError: resolve`).

- [ ] **Step 3: Implement `resolve(src: list[dict], records: list[dict]) -> tuple[dict, list[str]]`** and write the overlay file at the end of the main run.

- [ ] **Step 4: Write `overlay.src.json`** from the reports. Every entry has a `source` URL taken from its report row.
  - `reports/Singapore cycling rider personas.md`: every hawker centre row (dishes, timing → `best_time`, Tier A stalls with `bib: 2026`, Tier B with `since`, cyclist parking → `note`), every architecture, heritage, nature/photo, wildlife, tourist and family spot row (persona from its table, "Park and walk"/"Push" → `park_and_walk`/`dismount`, best time).
  - `reports/Singapore PCN stops and reviews.md`: rows that give a place a reason code (crowded, dismount, no water, limited food) or a dated status.
  - A row whose place isn't in OSM by name and has no sourced coordinate stays out. List these in the commit message.

- [ ] **Step 5: Run the checks and the build**

Run: `.venv/bin/python -I scripts/places/build.py --check && .venv/bin/python -I scripts/places/build.py layers.pickle`
Expected: `places checks passed`, then an overlay count. Every `UNRESOLVED`/`AMBIGUOUS` line has been looked at: fix the name to the OSM spelling where the place clearly exists, otherwise leave it out.

- [ ] **Step 6: Commit**

```bash
git add scripts/places/build.py scripts/places/overlay.src.json && git commit -m "feat(places): research overlay keyed by OSM ID"
git add cyclingskibidi/places_overlay.json && git commit -m "data: places overlay from research <yyyy-mm-dd>"
```

---

### Task 3: The app reads the new files

**Files:**
- Modify: `cyclingskibidi/Models/Geo.swift` (`Sight`)
- Modify: `cyclingskibidi/Features/Routes/Discovery.swift` (loading, `PlaceFacts`, icons, keywords, leisure categories, self-check)
- Modify: `cyclingskibidi/Features/Marks/MarksView.swift` (`CreditsView`)
- Bundle: `places_overlay.json` is picked up automatically (the `cyclingskibidi/` folder is a synchronized group); confirm it is in the built `.app`.

**Interfaces:**
- `Sight` gains `var osmID: String?` (optional, so old saves decode).
- Produces, in `Discovery.swift`:

```swift
struct PlaceNote: Decodable, Sendable {
    var persona: [String]?; var reasons: [String]?; var status: String?; var valid_until: String?
    var dishes: [String]?; var stalls: [Stall]?; var best_time: String?; var note: String?; var source: String?
    struct Stall: Decodable, Sendable { var name: String; var bib: Int?; var since: Int? }
}
struct PlaceFacts: Sendable {
    var hours: [[Int]]?     // [day 0=Mon, from, to] minutes; nil = no hours known, treat as open
    var area: Double        // m², 0 for points
    var shape: [Coord]      // outline or line points; [] for points
    var wiki: Bool
    var note: PlaceNote?
    func isOpen(at date: Date) -> Bool        // Singapore time; hours nil -> true; note closed through valid_until -> false
    var isLarge: Bool { area >= 10_000 }
}
extension Discovery {
    static let facts: [String: PlaceFacts]    // keyed by osmID (and x- keys), built with `places`
}
```

  `Discovery.places` keeps its type `[Sight]` and now also holds hand-added overlay places. `isOpen`'s closed-by-note rule: `status == "closed"` and (no `valid_until`, or `date` is before the day after `valid_until`), using `Closures.day` and `Closures.sg`.
- Leisure categories add `bridge`, `waterway`, `reservoir`, `heritage`, `artwork`, `playground`. The rest-stop categories (`toilets`, `drinkingWater`, `shelter`, `repair`, `bikeParking`, `bikeRental`) are searchable but are not leisure sights.
- `icon(for:)` additions (SF Symbols for now; plan 7 swaps in pixel icons): bridge `road.lanes` "Bridge"; waterway `water.waves` "River or canal"; reservoir `water.waves` "Reservoir"; heritage `scroll.fill` "Heritage"; artwork `paintpalette.fill` "Public art"; playground `figure.play` "Playground"; toilets `toilet.fill` "Toilets"; drinkingWater `drop.fill` "Drinking water"; shelter `umbrella.fill` "Shelter"; repair `wrench.and.screwdriver.fill` "Bike repair station"; bikeParking `parkingsign` "Bike parking"; bikeRental `bicycle` "Bike rental".
- `keywords` additions: toilets "toilet restroom loo"; drinkingWater "water tap fountain"; shelter "shade rain"; repair "pump"; bikeRental "hire rent"; heritage "historic monument".
- Credits: add a "Place notes" section: "Place notes, dishes and timings are this app's own research from public sources, each cited in the app's data. Stall names follow the Michelin Bib Gourmand Singapore 2026 list."

- [ ] **Step 1: Write the failing checks** in `Discovery.selfCheck()`

```swift
// Old saves (no osmID) still decode.
let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Park","category":"park","lat":1.3,"lon":103.8,"offsetAlong":0,"address":"","phone":"","url":""}"#
assert((try? JSONDecoder().decode(Sight.self, from: Data(old.utf8)))?.osmID == nil, "old Sight must decode")
// Hours: Monday 10:00 SGT open for Mo-Fr 08:00-20:00, closed at 21:00; past-midnight span open at 01:00 Tuesday.
let mon10 = Closures.sg.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 10))!
let f = PlaceFacts(hours: [[0, 480, 1200]], area: 0, shape: [], wiki: false, note: nil)
assert(f.isOpen(at: mon10) && !f.isOpen(at: mon10.addingTimeInterval(11 * 3600)), "Mo 08-20 wrong")
let late = PlaceFacts(hours: [[0, 1080, 1440], [1, 0, 120]], area: 0, shape: [], wiki: false, note: nil)
assert(late.isOpen(at: mon10.addingTimeInterval(15 * 3600)), "18:00-02:00 must be open at 01:00 Tuesday")
assert(PlaceFacts(hours: nil, area: 0, shape: [], wiki: false, note: nil).isOpen(at: mon10), "no hours = open")
// Overlay closure, inclusive end date.
var shut = PlaceNote(); shut.status = "closed"; shut.valid_until = "2026-11-23"
assert(!PlaceFacts(hours: nil, area: 0, shape: [], wiki: false, note: shut).isOpen(at: mon10), "closed through its end day")
assert(PlaceFacts(hours: nil, area: 0, shape: [], wiki: false, note: shut).isOpen(at: mon10.addingTimeInterval(86_400)), "open after it")
// Real data.
assert(places.contains { $0.category == "toilets" } && places.contains { $0.category == "drinkingWater" }, "rest-stop amenities missing")
assert(facts.values.contains { $0.note?.dishes?.isEmpty == false }, "overlay missing or not joined")
assert(!search("toilets", near: line[0]).isEmpty, "amenities must be searchable")
```

  (Give every `PlaceNote` property a `= nil` default so `PlaceNote()` exists.)

- [ ] **Step 2: Build and launch to see it fail**

Run the build gate, then launch on the simulator.
Expected: the build fails on `PlaceFacts`/`osmID`, or the launch fails with "Assertion failed".

- [ ] **Step 3: Implement** the interfaces above. Decode `places.json` with the new optional fields; build `places` and `facts` in one pass; decode `places_overlay.json` into `[String: PlaceNote]` (plus the hand-added `name/category/lat/lon`) and join it by key. A missing or malformed file gives `[]` / `[:]`, never a crash.

- [ ] **Step 4: Build and launch**

Expected: `** BUILD SUCCEEDED **`; a clean launch.

- [ ] **Step 5: Commit**

```bash
git add cyclingskibidi/Models/Geo.swift cyclingskibidi/Features/Routes/Discovery.swift cyclingskibidi/Features/Marks/MarksView.swift
git commit -m "feat(places): read OSM IDs, hours, shapes and research notes"
```

---

### Task 4: Places a rider really passes

**Files:**
- Modify: `cyclingskibidi/Features/Routes/Discovery.swift` (`sightsAlong`, `sights(along:)`)
- Modify callers: `cyclingskibidi/Features/Routes/RouteBuilderView.swift:287`, `cyclingskibidi/Features/Routes/RouteDetailView.swift:64` and `:134` (pass the route's mode)

**Interfaces:**
- Consumes: `Discovery.facts`, `PlaceFacts.isOpen(at:)`, `PlaceFacts.isLarge`, `Closures.activeCircles(on:)`, `RideMode.planningSpeedKmh`.
- Produces:

```swift
static func sightsAlong(_ candidates: [Sight], polyline: [CLLocationCoordinate2D], cumulative: [Double],
                        facts: [String: PlaceFacts] = Discovery.facts) -> [Sight]
static func sights(along polyline: [Coord], mode: RideMode = .leisure, start: Date = .now,
                   in places: [Sight] = Discovery.places, facts: [String: PlaceFacts] = Discovery.facts,
                   closed: [NoGoCircle]? = nil, walk: [NoGoCircle]? = nil, limit: Int = 20) -> [Sight]
```

  `closed`/`walk` nil means `Closures.activeCircles(on: start)`. `RideRecorder`'s reroute call keeps working unchanged through the defaults.
- Rules, in order:
  1. **Proximity:** a place's distance to the line is the smallest snap distance over its point and its `shape` points; `offsetAlong` comes from that nearest point. Kept within **300 m** if `isLarge`, else **100 m** (spec values; this replaces today's flat 150 m). The bounding-box prefilter pads by 300 m.
  2. **Open when passed:** pass time = `start + offsetAlong / (mode.planningSpeedKmh / 3.6)` seconds. Drop if `!isOpen(at: passTime)`.
  3. **No-cycling and closures:** drop a place whose point lies inside any `closed` circle. Drop one inside any `walk` circle unless its note's `reasons` contains `park_and_walk`.
  4. **Spread:** if more than `limit` remain, split the route into `limit` equal-length stretches and take the most notable place in each stretch (notability: has a note 2, `wiki` 1, else 0; ties go to the nearer one). Fill any slots left over with the most notable of the rest. Return them ordered by `offsetAlong`.

- [ ] **Step 1: Write the failing checks** in `Discovery.selfCheck()`, using an injected `facts` table and empty circles unless stated:

```swift
// 10 km west→east line at lat 1.30.
let long = [Coord(lat: 1.30, lon: 103.80), Coord(lat: 1.30, lon: 103.8899)]
func p(_ id: String, _ lon: Double, _ dLat: Double = 0, cat: String = "park") -> Sight {
    var s = Sight(name: id, category: cat, lat: 1.30 + dLat, lon: lon); s.osmID = id; return s }
let none = PlaceFacts(hours: nil, area: 0, shape: [], wiki: false, note: nil)
// Proximity: 90 m off kept, 200 m off dropped, a large park whose centre is 500 m off but whose edge touches the line kept.
let big = PlaceFacts(hours: nil, area: 50_000, shape: [Coord(lat: 1.30, lon: 103.85)], wiki: false, note: nil)
let near = sights(along: long, in: [p("a", 103.81, 0.0008), p("b", 103.82, 0.0018), p("c", 103.85, 0.0045)],
                  facts: ["a": none, "b": none, "c": big], closed: [], walk: [])
assert(near.map(\.name) == ["a", "c"], "proximity: \(near.map(\.name))")
// Closed when passed: hours Mon 08-09 only, ridden Monday 10:00 -> dropped.
let shut = PlaceFacts(hours: [[0, 480, 540]], area: 0, shape: [], wiki: false, note: nil)
assert(sights(along: long, start: mon10, in: [p("h", 103.81)], facts: ["h": shut], closed: [], walk: []).isEmpty, "closed at pass time kept")
// No-cycling zone: dropped unless park_and_walk.
let zone = [NoGoCircle(coord: Coord(lat: 1.30, lon: 103.81), radiusMeters: 50)]
var walkNote = PlaceNote(); walkNote.reasons = ["park_and_walk"]
let walked = sights(along: long, in: [p("z", 103.81), p("w", 103.8101)],
                    facts: ["z": none, "w": PlaceFacts(hours: nil, area: 0, shape: [], wiki: false, note: walkNote)], closed: [], walk: zone)
assert(walked.map(\.name) == ["w"], "no-cycling rule: \(walked.map(\.name))")
// Spread: 30 places in the first km plus one at km 9; limit 5 -> the km-9 one survives, 5 total, in order.
let bunch = (0..<30).map { p("s\($0)", 103.80 + Double($0) * 0.0003) } + [p("end", 103.881)]
let spread = sights(along: long, in: bunch, facts: Dictionary(uniqueKeysWithValues: bunch.map { ($0.osmID!, none) }),
                    closed: [], walk: [], limit: 5)
assert(spread.count == 5 && spread.last?.name == "end", "spread: \(spread.map(\.name))")
assert(spread.map(\.offsetAlong) == spread.map(\.offsetAlong).sorted(), "spread must stay in route order")
```

  Update the existing corridor checks in the same function to the new signature (the 90 m "Park" is still kept at 100 m).

- [ ] **Step 2: Build and launch to see it fail**

Expected: the build fails on the new parameters, or "Assertion failed: proximity".

- [ ] **Step 3: Implement** the rules above, and pass `mode: route.mode` / `mode: currentMode` at the three call sites.

- [ ] **Step 4: Build and launch**

Expected: `** BUILD SUCCEEDED **`; a clean launch. The `RideRecorder` reroute check ("a reroute must keep the sights on the new line") still passes.

- [ ] **Step 5: Try it.** Plan a Leisure route along East Coast Park in the simulator. The list shows places from start to end, hawker centres with notes appear, and no toilets or taps show up as sights.

- [ ] **Step 6: Commit**

```bash
git add cyclingskibidi/Features/Routes
git commit -m "feat(places): keep places a rider passes, open on arrival, spread along the route"
```
