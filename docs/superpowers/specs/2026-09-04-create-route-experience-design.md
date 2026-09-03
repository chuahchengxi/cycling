# Create-Route Experience — Design

Date: 2026-09-04
Status: approved for Phase 1 implementation

## Summary

Redesign how a rider creates a route in cyclingskibidi. Today the main screen's
`+` is a dropdown that jumps straight to Build / Import-Garmin-COROS /
Import-GPX, and routing is a single MapKit walking engine with no notion of
rider intent. This work introduces a **mode** (fast / moderate / leisure), a
**guided create flow** (mode → source → save), **leisure landmark discovery**,
a **layout pass** on the squeezed metric rows, **Strava import via GPX**, and a
**file reorganization**. It also lays the seam for a later strict-PCN routing
engine without building it yet.

## Phasing

- **Phase 1 (this spec, build now):** §A model seam, §B layout, §C main page,
  §D create-route wizard, §E leisure discovery, §F file organization. All modes
  route through the existing engine in Phase 1; `mode` is captured and stored.
- **Phase 2 (§G, designed not built):** hybrid strict-PCN routing. Phase 1's
  only obligation is to get the `mode` field and the `Routing.plan(…, mode:)`
  signature right so Phase 2 drops in behind them with **zero UI change**.

## Existing state (as read, for grounding)

- `RouteListView.swift` — main page. Filter chips top, `RouteCard` list, search
  via `.searchable(placement: .toolbar)` `.searchToolbarBehavior(.minimize)`,
  Stats button top-left, and a `+` `Menu` top-right listing Build / Import
  Garmin-COROS / Import GPX. Owns the GPX `.fileImporter` and the HealthKit
  import.
- `RouteBuilderView.swift` — drop pins on a `Map`, each replan calls
  `Routing.plan(through:)`. Has its own `.searchable` place search. Saves a
  `Route`.
- `Routing.swift` — `Routing.plan(through:fetchElevation:)` using MapKit
  `.walking`; `RoutePlan` value type; Open-Meteo elevation.
- `Models.swift` — `Route`, `Ride`, `Obstacle` SwiftData models (CloudKit
  rules: defaults on every stored property). `RideSource` enum already includes
  `.gpx`. `Fmt` formatters. `Difficulty.rated(...)`.
- `Providers.swift` — HealthKit import → `Ride`s. `GPXParser` with
  `makeRide()` **and** `makeWaypoints(max:)` — the file→route path already
  exists.
- `SheetView.swift` — route brief; `summary` crams distance/time/difficulty on
  one bold `HStack(spacing: 20)`.
- `NavigateView.swift` — live turn-by-turn; the ETA/arrival clock HUD lives
  here (`Fmt.eta`, `Fmt.clock`).
- Project is Xcode 16 `objectVersion 77` with `PBXFileSystemSynchronizedRootGroup`
  on `cyclingskibidi/` — files are picked up by folder; moving into subfolders
  needs no `.xcodeproj` edits.

## A · Data model — mode seam

Add to `Models.swift`:

```swift
enum RideMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case fast = "Fast", moderate = "Moderate", leisure = "Leisure"
    var id: String { rawValue }
    var subtitle: String {
        switch self {
        case .fast:     return "Fastest way there — roads allowed, higher risk."
        case .moderate: return "A balance of speed and safety."
        case .leisure:  return "Scenic and relaxed — connectors and sights."
        }
    }
    var symbol: String {
        switch self {
        case .fast:     return "bolt.fill"
        case .moderate: return "bicycle"
        case .leisure:  return "leaf.fill"
        }
    }
}
```

On `Route` (CloudKit-safe: stored default, computed accessor — matching the
existing `difficultyRaw`/`difficulty` pattern):

```swift
var modeRaw: String = RideMode.moderate.rawValue
var mode: RideMode {
    get { RideMode(rawValue: modeRaw) ?? .moderate }
    set { modeRaw = newValue.rawValue }
}
```

`mode` is an axis of **rider intent**, distinct from `difficulty` (derived from
terrain). Both are kept.

Adding one optional/defaulted attribute is a lightweight SwiftData +
CloudKit migration (no unique constraints, has a default) — no manual migration
code needed.

## B · Layout / padding

Root cause of the squeeze: too many items in fixed-spacing `HStack`s. Fix once,
reuse.

1. **`FlowLayout`** — a small `Layout`-protocol wrapping container (new file,
   `Features/Routes/FlowLayout.swift`, ~30 lines) that lays children left→right
   and wraps to the next line when the row is full. Used by the pill rows so
   pills wrap instead of crush.
2. **`RouteCard`** (`RouteListView.swift`) — the distance/difficulty/duration
   pills move into `FlowLayout` with a consistent spacing token; add a mode pill.
3. **`RouteBuilderView.controls`** — the distance/duration/difficulty/ascent
   pills move into `FlowLayout`.
4. **`SheetView.summary`** — keep the single bold line but add dividers and
   consistent spacing so distance / time / difficulty read as separate stats;
   add a mode pill/label.
5. **`NavigateView`** HUD — audit the ETA/arrival block and apply the same
   spacing rhythm.

Introduce one spacing constant (a single `static let spacing` on `FlowLayout`)
reused across these rows rather than scattering literals.

Runnable check: a `FlowLayout` self-check asserting that N items wider than the
container wrap to ≥2 rows and a row narrower than the container stays on 1.

## C · Main page (`RouteListView`)

- **Search on top:** remove `.searchToolbarBehavior(.minimize)` so the
  `.searchable` field is persistently visible in the navigation bar at the top
  (the native path — no custom search field). Filter chips stay directly below
  it.
- **`+` launches the wizard:** replace the top-right `+` `Menu` with a single
  `+` button that presents `CreateRouteFlow` (§D). The Build / Import options
  move *into* the wizard.
- Stats button stays top-left with its badge.
- The empty-state "Create a route" button also presents `CreateRouteFlow`.
- The GPX `.fileImporter` and HealthKit import currently owned by
  `RouteListView` move into the wizard's source step (§D). The existing
  "import as ride history" entry points elsewhere are untouched.

## D · Create-route wizard (`CreateRouteFlow`)

A `NavigationStack`-based sheet. Two pick steps, then hand-off, then save.

- **Step 1 — Mode:** three large selectable cards (Fast / Moderate / Leisure)
  using `RideMode.allCases`, each showing symbol + name + `subtitle`.
- **Step 2 — Source:** four rows —
  - **Create from map** → pushes `RouteBuilderView(mode:)` (§E when leisure).
  - **Import a GPX file** → `.fileImporter` → build a Route (below).
  - **Import from Garmin / COROS** → HealthKit workout picker → build a Route.
  - **Import from Strava** → labeled "via GPX export"; same `.fileImporter`
    path as GPX.

**Import semantics (decided): import builds a plannable `Route` from the
imported track — the route is *followed*, not logged as a past ride.**

- **File path (GPX / Strava):** `GPXParser.parse(url)` →
  `parser.makeWaypoints(max:)` → `Routing.plan(through:mode:)` → present a
  preview (map + metrics) → name → save a `Route` with `mode` set and
  `RideSource`-agnostic (a `Route` has no source field; the track's shape is
  what's kept). Empty/track-less files surface the same alert copy the current
  importer uses.
- **Garmin / COROS path:** `Providers` gains a read-only lister of recent
  cycling workouts (reusing its existing HealthKit query and `locations(for:)`
  route-fetch, refactored so the workout→`Ride` mapping and the
  workout-listing are separable). The wizard shows the list; the chosen
  workout's locations → thinned to waypoints (same `Geo.sample` thinning as
  `makeWaypoints`) → `Routing.plan(through:mode:)` → preview → name → save a
  `Route`.
- The app's existing "import as ride history" (HealthKit bulk import, GPX→Ride)
  is **not removed**; it remains available from its current entry points
  (Stats / list) for logging past rides.

`Routing.plan` gains a `mode:` parameter now:

```swift
static func plan(through waypoints: [Coord],
                 mode: RideMode = .moderate,
                 fetchElevation: Bool = true) async throws -> RoutePlan
```

In Phase 1 the body ignores `mode` — all modes use the current `.walking`
engine identically; no mode gets special routing until Phase 2. The parameter
exists only so Phase 2 swaps engines behind it. `RoutePlan` does not need a mode
field — the caller stores `mode` on the `Route`.

Runnable check: a state-machine assert that the flow advances mode→source and
that a fixture GPX string parses → makeWaypoints → non-empty plan (network calls
stubbed/guarded so the check does not depend on MapKit reachability; assert the
parse→waypoints stage deterministically).

## E · Leisure discovery (in `RouteBuilderView`, only when `mode == .leisure`)

A "Discover" panel driven by `MKLocalSearch`:

- **Auto-search** POI around the current map center for a small set of leisure
  categories (e.g. parks, tourist attractions, scenic lookouts, cafés) using
  `MKLocalSearch` / `MKLocalSearch.Request` with `resultTypes = .pointOfInterest`
  and a `MKPointOfInterestFilter` for those categories.
- **Keyword field** for the rider's own tastes ("hawker, temples, waterfront")
  → `MKLocalSearch` natural-language query bounded to the map region.
- **Tap a result** → append its coordinate as a waypoint and `replan()` —
  reusing the builder's existing waypoint machinery. No new routing code.
- **Tastes persist** via `@AppStorage("leisureTastes")` — a comma-separated
  string, no model/CloudKit change.

Non-leisure modes do not show the panel. The builder's existing place `.searchable`
stays for all modes.

Runnable check: assert the query builder turns a tastes string into the expected
`MKLocalSearch.Request` inputs (natural-language query + region), pure-function
tested without hitting the network.

## F · File organization

Synchronized root group → create subfolders under `cyclingskibidi/` and move
files; Xcode picks them up with no `.xcodeproj` edit.

```
cyclingskibidi/
  App/            cyclingskibidiApp.swift, ContentView.swift, DemoSeed.swift
  Models/         Models.swift, Geo.swift
  Routing/        Routing.swift, Providers.swift
  Features/
    Routes/       RouteListView.swift, RouteDetailView.swift, SheetView.swift,
                  RouteBuilderView.swift, CreateRouteFlow.swift (new),
                  Discovery.swift (new), FlowLayout.swift (new)
    Navigate/     NavigateView.swift, RideRecorder.swift, FinishedView.swift
    Stats/        StatsView.swift
  Assets.xcassets            (unchanged, stays at root)
  cyclingskibidi.entitlements (unchanged, stays at root — path in build settings)
  Info / Preview content       (unchanged, stays at root)
```

Leave `Assets.xcassets` and `cyclingskibidi.entitlements` at the root: their
paths live in build settings and moving them would mean editing those settings
for no benefit. Verify the target still builds after the move (synchronized
groups compile everything under the root, so nested folders are included).

## G · Phase 2 — hybrid strict-PCN routing (designed, NOT built here)

Recorded so Phase 1's seams are correct; implementation is a later spec.

- **Dataset:** bundle official NParks/LTA PCN network as GeoJSON (seed copy in
  the app), **versioned**; fetch newer versions periodically from a hosted
  endpoint and cache on device ("periodic updates to keep riders current").
- **Strict path (leisure / moderate):** build a graph from the PCN polylines,
  snap start/end/waypoints to the nearest PCN node, and route on-device
  (Dijkstra/A*) so the line **stays on the PCN**. Where the PCN does not reach
  (first/last mile, gaps), stitch with a hosted OSM cycling router.
- **Fast mode:** road-favoring routing (roads allowed, higher risk) via the
  hosted cycling router or the current engine.
- **Integration:** all of this lives behind `Routing.plan(through:mode:)`. The
  UI, the `Route.mode` field, and the wizard do not change when it lands.
- Open items for the Phase 2 spec: exact dataset source URL + license, refresh
  cadence + storage, hosted router choice + ToS, offline behavior. These do
  **not** block Phase 1.

## Testing strategy

Follow the existing `Geo.selfCheck()` convention — `assert`-based, run in DEBUG,
no framework:

- `FlowLayout`: wrap/no-wrap sizing assertions.
- `CreateRouteFlow`: mode→source advancement; GPX-string → waypoints → non-empty
  (parse stage deterministic; network-dependent routing guarded).
- Discovery: tastes-string → request-inputs pure function.
- Reuse `GPXParser` and `Geo.sample` — already covered by shape, not re-tested.

## Out of scope

- Building the Phase 2 routing engine, the PCN dataset pipeline, or the hosted
  router integration.
- Full Strava OAuth API (Strava import is GPX-export only).
- Removing or reworking the existing ride-history import.
- Any change to obstacle reporting, recording, or the navigate/finish flow
  beyond the §B HUD spacing pass.
