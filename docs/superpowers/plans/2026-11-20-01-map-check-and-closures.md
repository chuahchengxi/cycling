# Map Check and Closures Implementation Plan (plan 1 of 8)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Confirm whether Apple Maps works offline, then make every route avoid known closures and rider-reported hazards offline, show any closed stretch the route can't avoid as a dashed off-connector stretch, and recheck saved routes against closures.

**Architecture:** A bundled `closures.json` is decoded into `Closure` values. Active closures and hazards become `NoGoCircle`s. `PCNGraph.penalised(_:)` returns a copy whose edges touching those circles cost ×1000, so A* stays on open connectors when it can. When it can't, `PCNRouting.stitched` marks the vertices inside circles as off-connector segments. BRouter is no longer used for closures in Moderate/Leisure. Fast mode keeps BRouter until plan 6 (offline road network).

**Tech Stack:** Swift, SwiftUI, SwiftData, MapKit. No XCTest target: checks are `assert`-based `selfCheck()` functions wired into `cyclingskibidiApp.init()` under `#if DEBUG`.

**Spec:** `docs/superpowers/specs/2026-11-20-kit-personalised-places-design.md`, section 0 ("Closures"), the map row of section 5, and "When things are decided" (saved-route check).

**The whole series** (one plan each, written when the previous one ships): 1 map check + closures (this), 2 offline places file, 3 interests + Kit picks, 4 rest stops, 5 scenic slider, 6 fully offline (road network, heights, search, BRouter/open-meteo removal), 7 Kit UI (banner moments, full-screen alarms, dark/light), 8 fall detection.

## Global Constraints

- Target iOS 27.2.
- Build gate: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme cyclingskibidi -destination 'generic/platform=iOS Simulator' -configuration Debug build` ends `** BUILD SUCCEEDED **`. Ignore SourceKit "Cannot find type" diagnostics.
- Behaviour gate: ⌘R in a simulator. Every `selfCheck()` runs at launch. Any `assert` failure crashes with its message, so a clean launch means the checks passed.
- The project defaults to MainActor isolation. Data types used off the main actor are `nonisolated` and `Sendable`, as `PCNGraph` and `Coord` are. Do not add blocking async bridges; use fire-and-forget `Task {}`.
- Never invent coordinates. Every closure circle records where its coordinates came from.
- `valid_until` is inclusive: a closure stays active through the end of that date, Singapore time (`Asia/Singapore`).
- `no_cycling` entries never expire.

## Review Focus

1. **A closure that cuts the only connector between start and end.** The route must still come back, on the connector, with the closed part as an off-connector segment, never "no route". Test in Task 3.
2. **A closure with no end date** (`valid_until: null`, e.g. Gardens by the Bay Waterfront Promenade) stays active forever. Test in Task 2.
3. **A route through a closure that expired yesterday** is not avoided and is reported as "was closed until <date>, check status". Test in Task 2 (`Closures.hits`).
4. **A malformed or missing `closures.json`** must not crash or block routing. It decodes to `[]`. Test in Task 2.
5. **A rider-reported hazard while offline**: `rerouteAround` used to need BRouter. It must now produce a route with no network. Covered by Task 3's routing check, plus a manual airplane-mode step in Task 4.

---

### Task 1: Airplane-mode map check (manual, on the user's iPhone)

**Files:**
- Modify: `docs/superpowers/specs/2026-11-20-kit-personalised-places-design.md` (the "Apple Maps map tiles" row of section 5)

This decides whether plan 6 has to bundle a map. No code.

- [ ] **Step 1: Build and install on the iPhone**, Debug, from Xcode.
- [ ] **Step 2: Online, open a saved route in Punggol.** Pan around it for 30 s so tiles cache.
- [ ] **Step 3: Turn on airplane mode (Wi-Fi off too) and force-quit the app.**
- [ ] **Step 4: Relaunch. Open the same route, then pan to Jurong West, an area not viewed in Step 2.** Screenshot both.
- [ ] **Step 5: Record the result in the spec row**: cached area shown yes/no, uncached area shown yes/no, with the date. If the uncached area is blank, add the line "Map tiles do not work offline: user to choose between bundling a map and accepting an online map background". Tell the user before plan 6. Do not choose for them.
- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/specs/2026-11-20-kit-personalised-places-design.md
git commit -m "docs: record airplane-mode map tile result"
```

### Task 2: Closures data and lookup

**Files:**
- Create: `cyclingskibidi/Routing/Closures.swift`
- Create: `cyclingskibidi/closures.json` (add to the app target, Copy Bundle Resources, the same way as `pcn-seed.geojson`)
- Modify: `cyclingskibidi/App/cyclingskibidiApp.swift` (add `Closures.selfCheck()` to the DEBUG list)

**Interfaces:**
- Consumes: `Coord`, `Geo.distance`, `Geo.cumulative`, `Geo.snap`, and `NoGoCircle` (in `BRouter.swift`).
- Produces:
  - `nonisolated struct Closure: Codable, Sendable, Identifiable`, with:
    - fields `id: String`, `name: String`, `circles: [Closure.Circle]`, `starts: String?`, `validUntil: String?`, `note: String`, `sourceUrl: String`, `kind: Closure.Kind`
    - `struct Circle: Codable, Sendable { lat, lon, radiusM: Double; coordSource: String }`
    - `enum Kind: String, Codable { case closure; case noCycling = "no_cycling" }`
  - `func isActive(on date: Date) -> Bool`
  - `var noGoCircles: [NoGoCircle]`
  - `nonisolated enum Closures`, with:
    - `static func decode(_ data: Data) -> [Closure]`: snake_case keys, `[]` on any failure.
    - `static func bundled() -> [Closure]`: memoised, read from `closures.json`.
    - `static func activeCircles(on date: Date = .now) -> [NoGoCircle]`
    - `static func hits(_ polyline: [Coord], in closures: [Closure], on date: Date) -> (active: [Closure], expired: [Closure])`: a closure "hits" if any circle centre lies within `radiusM` of the polyline (`Geo.snap(...).lateral <= radiusM`).

- [ ] **Step 1: Write `Closures.selfCheck()` with these assertions**

```swift
static func selfCheck() {
    let json = """
    [{"id":"a","name":"Open-ended","circles":[{"lat":1.3,"lon":103.8,"radius_m":50,"coord_source":"test"}],
      "starts":"2026-05-04","valid_until":null,"note":"","source_url":"x","kind":"closure"},
     {"id":"b","name":"Ends 31 Dec","circles":[{"lat":1.31,"lon":103.8,"radius_m":50,"coord_source":"test"}],
      "starts":"2026-01-01","valid_until":"2026-12-31","note":"","source_url":"x","kind":"closure"},
     {"id":"c","name":"No cycling","circles":[{"lat":1.32,"lon":103.8,"radius_m":50,"coord_source":"test"}],
      "starts":null,"valid_until":"2020-01-01","note":"","source_url":"x","kind":"no_cycling"}]
    """.data(using: .utf8)!
    let all = decode(json)
    assert(all.count == 3, "decode failed")
    let sg = TimeZone(identifier: "Asia/Singapore")!
    func day(_ s: String, _ h: Int) -> Date { var c = Calendar(identifier: .gregorian); c.timeZone = sg
        let p = s.split(separator: "-").map { Int($0)! }
        return c.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: h))! }
    assert(all[0].isActive(on: day("2030-01-01", 12)), "no end date must stay active")
    assert(!all[0].isActive(on: day("2026-05-03", 12)), "not active before starts")
    assert(all[1].isActive(on: day("2026-12-31", 23)), "valid_until is inclusive, SG time")
    assert(!all[1].isActive(on: day("2027-01-01", 0)), "expired the day after")
    assert(all[2].isActive(on: day("2030-01-01", 12)), "no_cycling never expires")
    assert(decode(Data("not json".utf8)).isEmpty, "bad data must decode to []")
    // A line through b's centre, checked after b expired: expired hit, not active.
    let line = [Coord(lat: 1.309, lon: 103.8), Coord(lat: 1.311, lon: 103.8)]
    let h = hits(line, in: all, on: day("2027-02-01", 12))
    assert(h.active.isEmpty && h.expired.map(\.id) == ["b"], "expired hit wrong: \(h)")
    assert(!bundled().isEmpty, "closures.json missing from bundle")
}
```

- [ ] **Step 2: Add the call to `cyclingskibidiApp.init()` and run the build gate.** Expected: build fails with "cannot find 'Closures' in scope".
- [ ] **Step 3: Implement `Closures.swift`** using the Interfaces above. Parse dates as `yyyy-MM-dd` in `Asia/Singapore`. Active means `starts == nil || date >= start-of-starts`, and `kind == .noCycling || validUntil == nil || date < start of the day after validUntil`.
- [ ] **Step 4: Write `closures.json`** with the closures and no-cycling zones listed in spec section 0 (as of 20 Nov 2026), plus `note` and `source_url` from `reports/Singapore PCN stops and reviews.md`. Ship Rail Corridor South as `valid_until: "2027-07-31"`. Use the last day of the stated quarter or half for "Q3 2029" / "2H 2027" / "end 2028" entries, and say so in `note`. For coordinates:
  - Take the named connector from `pcn-seed.geojson` (match the `PARK` property, e.g. `Loyang Park Connector`, `Alexandra Queensway PC`, `Bedok Park Connector`).
  - Place circles along the closed stretch between the named end roads, radius 60–150 m, spaced so they overlap.
  - Set `coord_source` to `"pcn-seed PARK=<name>, between <road> and <road>"`.
  - If the closed stretch can't be located from the seed or from OneMap search, **leave that entry out** and list it in the commit message. Do not guess.
- [ ] **Step 5: Run the build gate, then ⌘R.** Expected: build succeeds and the app launches with no assertion failure.
- [ ] **Step 6: Commit**

```bash
git add cyclingskibidi/Routing/Closures.swift cyclingskibidi/closures.json cyclingskibidi/App/cyclingskibidiApp.swift cyclingskibidi.xcodeproj/project.pbxproj
git commit -m "feat(closures): bundled closures file with active/expired lookup"
```

### Task 3: Route around closures offline, dashed when unavoidable

**Files:**
- Modify: `cyclingskibidi/Routing/PCN/PCNGraph.swift` (add `penalised`)
- Modify: `cyclingskibidi/Routing/PCN/PCNRouting.swift` (`stitched` gains `closures`)
- Modify: `cyclingskibidi/Routing/Routing.swift:46-80` (`plan`)

**Interfaces:**
- Consumes: `Closures.activeCircles(on:)` and `NoGoCircle` (Task 2).
- Produces:
  - `PCNGraph.closedPenalty: Double = 1000`
  - `func penalised(_ circles: [NoGoCircle]) -> PCNGraph`: same nodes, and each edge with either endpoint within a circle's `radiusMeters` has its weight × `closedPenalty`. Returns `self` when `circles` is empty.
  - `PCNRouting.stitched(waypoints:graph:closures:gap:)`, where `closures: [NoGoCircle] = []`. Each run of on-PCN vertices inside any circle is added to `offSegments` and `offMeters`. The run starts one vertex before and ends one vertex after, so the dashed stretch joins the solid line.
  - `Routing.plan(through:mode:fetchElevation:closures:)`, same signature. For `.moderate` and `.leisure` it uses `let blocked = closures + Closures.activeCircles()` with `graph.penalised(blocked)` and `stitched(..., closures: blocked, ...)`. It no longer sends the whole route to BRouter when closures exist. `.fast` still calls `BRouter.route(waypoints, profile: fastProfile, nogos: blocked)` (replaced in plan 6). The gap closure becomes `{ let r = await BRouter.route([$0, $1], profile: BRouterConfig.gapProfile); return r.count >= 2 ? r : [$0, $1] }`. The straight line is the offline fallback the spec asks for.

- [ ] **Step 1: Add to `PCNRouting.selfCheck()`**

```swift
// Fixture: east leg then north leg. A closure on the junction leaves no other
// path, so the route must still arrive, with the junction stretch off-connector.
let west = Coord(lat: 1.300, lon: 103.800), north = Coord(lat: 1.302, lon: 103.802)
let shut = NoGoCircle(coord: Coord(lat: 1.300, lon: 103.802), radiusMeters: 20)
let blocked = await stitched(waypoints: [west, north], graph: g.penalised([shut]),
                             closures: [shut], gap: { [$0, $1] })
assert(abs(blocked.poly.last!.lat - 1.302) < 1e-6, "closure must not stop the route")
assert(blocked.offSegments.contains { seg in seg.contains { Geo.distance($0.cl, shut.coord.cl) <= 20 } },
       "the closed junction must be an off-connector segment")
// An open alternative wins: square with two ways round, close one side.
let sq = PCNGraph(polylines: [[west, Coord(lat: 1.300, lon: 103.802), north],
                              [west, Coord(lat: 1.302, lon: 103.800), north]])
let around = await stitched(waypoints: [west, north], graph: sq.penalised([shut]),
                            closures: [shut], gap: { [$0, $1] })
assert(around.offSegments.isEmpty, "should detour on the open side, not cross the closure")
assert(!around.poly.contains { Geo.distance($0.cl, shut.coord.cl) <= 20 }, "route crossed an avoidable closure")
```

and to `PCNGraph.selfCheck()`:

```swift
let p = g.penalised([NoGoCircle(coord: Coord(lat: 1.300, lon: 103.802), radiusMeters: 10)])
assert(abs(p.adj[junction]!.first!.1 - 222.4 * closedPenalty) < 2000, "edge not penalised")
assert(g.penalised([]).nodeCount == g.nodeCount)
```

- [ ] **Step 2: Run the build gate.** Expected: fails with "no member 'penalised'" / "extra argument 'closures'".
- [ ] **Step 3: Implement `penalised`, the `closures` parameter and the `Routing.plan` change** as specified in Interfaces. Leave a `// ponytail:` note on `penalised`: endpoint-only test; a long edge whose middle crosses a small circle is missed. Densify edges if that shows up on real data.
- [ ] **Step 4: Run the build gate, then ⌘R.** Expected: build succeeds and the app launches clean.
- [ ] **Step 5: Manual check in the simulator.** Plan a Leisure route along Bedok Park Connector, which has a closure active to 31 Dec 2026. Expected: the route bends round it, or shows a dashed off-connector stretch where it can't.
- [ ] **Step 6: Commit**

```bash
git add cyclingskibidi/Routing
git commit -m "feat(closures): route around closures on the PCN graph offline, dash unavoidable stretches"
```

### Task 4: Closure warnings on the route brief and the saved-route check

**Files:**
- Modify: `cyclingskibidi/Features/Routes/RouteDetailView.swift`
- Modify: `cyclingskibidi/Features/Navigate/RideRecorder.swift:341-357` (`rerouteAround`: comment only, now offline)

**Interfaces:**
- Consumes: `Closures.bundled()` and `Closures.hits(_:in:on:)` (Task 2), and `Routing.plan` (Task 3).
- Produces: nothing new for later tasks. Kit styling of these rows comes in plan 7.

- [ ] **Step 1: In `RouteDetailView`, compute `let closureHits = Closures.hits(route.polyline, in: Closures.bundled(), on: .now)`** when the view appears. This is the spec's "checked when you open one" (the ride-start check is the same call in `Trip.begin`; add it there too).
- [ ] **Step 2: Show the hits in the brief sheet, above the obstacles list, using native rows:**
  - Each active hit: title `"<name> is closed"` (or `"No cycling: <name>"` for `noCycling`), subtitle `note`, and a "Re-plan around it" button. The button calls `Routing.plan(through: route.waypoints, mode: route.mode)` and writes the result back onto `route` the way `Route.make` fills a new route (polyline, steps, distance, expected, ascent/descent, elevations), clears `sightData`, then saves the context.
  - Each expired hit: `"Was closed until <validUntil, d MMM yyyy>, check status"` with a `Link` to `sourceUrl`. A link is fine here: it only opens the browser when tapped.
- [ ] **Step 3: Draw active closure circles on the map** as `MapCircle(center:radius:)` with a translucent red fill. Draw `route`'s off-connector stretches dashed if the stored route has them. Otherwise skip: off-connector stretches aren't stored on `Route` today, so dashing them in the builder is enough for now. Note this in the commit message.
- [ ] **Step 4: Run the build gate, then ⌘R.** Then check manually in the simulator:
  - Open a saved route that crosses an active closure. Expected: the warning row and the circle appear, and Re-plan bends the route.
  - Set the simulator date to 2027-01-02 and reopen the Bedok route. Expected: "Was closed until 31 Dec 2026, check status".
- [ ] **Step 5: Manual on the iPhone, airplane mode on:** start a ride, long-press to mark a spot ahead closed, save. Expected: the route updates with no "Couldn't find a way around that closure." message.
- [ ] **Step 6: Commit**

```bash
git add cyclingskibidi/Features
git commit -m "feat(closures): warn about closures on saved routes and offer a re-plan"
```
