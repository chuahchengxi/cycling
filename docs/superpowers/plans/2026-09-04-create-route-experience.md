# Create-Route Experience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign route creation — a mode-aware guided wizard (mode → source → save), leisure landmark discovery, a layout pass on the squeezed metric rows, Strava-via-GPX import, and a file reorganization.

**Architecture:** A `RideMode` field is added to `Route` and a `mode:` parameter to `Routing.plan` as the seam for a later strict-PCN engine (not built here — all modes use the current MapKit `.walking` engine in Phase 1). The main page's `+` opens a `CreateRouteFlow` sheet. Import (GPX / Strava-GPX / Garmin-COROS) builds a *plannable `Route`* from the imported track, not a logged ride. Files regroup under `App/ Models/ Routing/ Features/` (Xcode 16 synchronized folders — no `.xcodeproj` edits).

**Tech Stack:** Swift, SwiftUI, SwiftData (+CloudKit), MapKit, HealthKit, Swift Charts. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-04-create-route-experience-design.md`

## Global Constraints

- **CloudKit-safe models:** every stored property has a default; no unique attributes; every relationship optional. New attributes are additive with defaults (no manual migration).
- **Tests are `assert`-based `selfCheck()`** run from `cyclingskibidiApp.init()` under `#if DEBUG` — there is **no XCTest target**. New non-trivial pure logic gets a `static func selfCheck()` wired into app init next to `Geo.selfCheck()`. UI wiring is verified by build + launch.
- **No new third-party dependencies.** Native frameworks only.
- **Xcode 16 synchronized folders** (`objectVersion 77`, `PBXFileSystemSynchronizedRootGroup`): files under `cyclingskibidi/` are compiled by folder; moving into subfolders needs no project-file edit. **Do not move** `Assets.xcassets` or `cyclingskibidi.entitlements` (their paths are in build settings).
- **Build check (compile):** `xcodebuild -scheme cyclingskibidi -destination 'generic/platform=iOS Simulator' build`
- **Run checks (assertions):** launch the app in DEBUG on a simulator (Xcode ⌘R). A failed `assert`/`selfCheck()` traps with its message; a clean launch means the checks passed.
- **`Routing.plan` ignores `mode` in Phase 1** — the parameter exists only so the Phase 2 PCN engine drops in behind it. Do not add mode-specific routing behavior now.

---

### Task 1: File organization

Move the 15 flat Swift files into feature folders. Synchronized groups pick them up automatically. Nothing else changes — pure move, so it lands first and every later task writes to the final paths.

**Files:**
- Move (via `git mv`) within `cyclingskibidi/`:
  - `App/`: `cyclingskibidiApp.swift`, `ContentView.swift`, `DemoSeed.swift`
  - `Models/`: `Models.swift`, `Geo.swift`
  - `Routing/`: `Routing.swift`, `Providers.swift`
  - `Features/Routes/`: `RouteListView.swift`, `RouteDetailView.swift`, `SheetView.swift`, `RouteBuilderView.swift`
  - `Features/Navigate/`: `NavigateView.swift`, `RideRecorder.swift`, `FinishedView.swift`
  - `Features/Stats/`: `StatsView.swift`
- Leave at root: `Assets.xcassets`, `cyclingskibidi.entitlements`, any `Info.plist`/`Preview Content`.

- [ ] **Step 1: Create folders and move files**

```bash
cd "cyclingskibidi"
mkdir -p App Models Routing Features/Routes Features/Navigate Features/Stats
git mv cyclingskibidiApp.swift ContentView.swift DemoSeed.swift App/
git mv Models.swift Geo.swift Models/
git mv Routing.swift Providers.swift Routing/
git mv RouteListView.swift RouteDetailView.swift SheetView.swift RouteBuilderView.swift Features/Routes/
git mv NavigateView.swift RideRecorder.swift FinishedView.swift Features/Navigate/
git mv StatsView.swift Features/Stats/
```

- [ ] **Step 2: Verify the target still builds**

Run: `xcodebuild -scheme cyclingskibidi -destination 'generic/platform=iOS Simulator' build`
Expected: BUILD SUCCEEDED (synchronized groups compile the nested folders).

- [ ] **Step 3: Verify checks still pass**

Launch in Xcode (⌘R) in DEBUG. Expected: app launches, no assertion trap (`Geo.selfCheck()` still runs).

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor: organize source into feature folders"
```

---

### Task 2: Mode seam — RideMode, Route.mode, Routing.plan(mode:)

Add rider-intent mode as a stored field and thread a `mode:` parameter through `Routing.plan`. This is the Phase 2 seam. The routing body does **not** change.

**Files:**
- Modify: `cyclingskibidi/Models/Models.swift` (add `RideMode` after the `Difficulty` enum ~line 76; add `modeRaw`/`mode` to `Route` ~line 135/154)
- Modify: `cyclingskibidi/Routing/Routing.swift` (add `mode:` param to `plan` ~line 43)
- Modify: `cyclingskibidi/App/cyclingskibidiApp.swift` (wire `RideMode.selfCheck()` ~line 24)

**Interfaces:**
- Produces:
  - `enum RideMode: String, Codable, CaseIterable, Identifiable, Sendable { case fast, moderate, leisure }` with `subtitle: String`, `symbol: String`, `static func selfCheck()`
  - `Route.mode: RideMode { get set }` backed by `Route.modeRaw: String`
  - `Routing.plan(through:mode:fetchElevation:) async throws -> RoutePlan`

- [ ] **Step 1: Add the `RideMode` enum with its self-check**

In `Models.swift`, after the `Difficulty` enum:

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

    static func selfCheck() {
        // Raw values round-trip (they are persisted in Route.modeRaw).
        for m in RideMode.allCases { assert(RideMode(rawValue: m.rawValue) == m) }
        // Unknown raw value falls back at the call site, never crashes.
        assert(RideMode(rawValue: "Nonsense") == nil)
        assert(RideMode.allCases.count == 3)
    }
}
```

- [ ] **Step 2: Add `mode` to `Route`**

In `Models.swift`, add the stored property alongside `difficultyRaw` (~line 135):

```swift
var modeRaw: String = RideMode.moderate.rawValue
```

And the computed accessor alongside `difficulty` (~line 154):

```swift
var mode: RideMode {
    get { RideMode(rawValue: modeRaw) ?? .moderate }
    set { modeRaw = newValue.rawValue }
}
```

- [ ] **Step 3: Add the `mode:` parameter to `Routing.plan`**

In `Routing.swift`, change the signature (~line 43) to:

```swift
static func plan(through waypoints: [Coord],
                 mode: RideMode = .moderate,
                 fetchElevation: Bool = true) async throws -> RoutePlan {
```

Leave the body unchanged (Phase 1 ignores `mode`). Add a one-line comment above it:

```swift
// ponytail: mode is captured but unused here — the Phase 2 PCN engine swaps in
// behind this signature. See specs/2026-09-04-create-route-experience-design.md §G.
```

- [ ] **Step 4: Wire the self-check into app init**

In `cyclingskibidiApp.swift`, inside `init()` under `#if DEBUG`:

```swift
Geo.selfCheck()
RideMode.selfCheck()
```

- [ ] **Step 5: Build and run**

Run: `xcodebuild -scheme cyclingskibidi -destination 'generic/platform=iOS Simulator' build` → BUILD SUCCEEDED (the defaulted `mode:` keeps the existing `Routing.plan` caller compiling).
Launch in DEBUG → no trap.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: add RideMode seam to Route and Routing.plan"
```

---

### Task 3: FlowLayout — a wrapping row container

A tiny `Layout` that lays children left→right and wraps, so metric pills stop crushing. Pure geometry — fully self-checkable.

**Files:**
- Create: `cyclingskibidi/Features/Routes/FlowLayout.swift`
- Modify: `cyclingskibidi/App/cyclingskibidiApp.swift` (wire `FlowLayout.selfCheck()`)

**Interfaces:**
- Produces:
  - `struct FlowLayout: Layout` with `init(spacing: CGFloat = FlowLayout.spacing)`
  - `static let spacing: CGFloat = 10`
  - `static func selfCheck()`

- [ ] **Step 1: Write the layout with its self-check**

Create `FlowLayout.swift`:

```swift
import SwiftUI

/// Lays children in rows, wrapping to the next line when the current row is
/// full. Replaces fixed-spacing HStacks that squeeze metric pills on narrow
/// screens.
struct FlowLayout: Layout {
    static let spacing: CGFloat = 10
    var spacing: CGFloat = FlowLayout.spacing

    /// Row-break positions for a set of child widths in a container of `width`.
    /// Returns the total (width, height) and each child's origin. Pure, so the
    /// self-check can exercise it without a render pass.
    static func arrange(sizes: [CGSize], in width: CGFloat, spacing: CGFloat)
        -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for s in sizes {
            if x > 0, x + s.width > width {           // wrap
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return Self.arrange(sizes: sizes, in: width, spacing: spacing).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let origins = Self.arrange(sizes: sizes, in: bounds.width, spacing: spacing).origins
        for (subview, origin) in zip(subviews, origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                          proposal: .unspecified)
        }
    }

    static func selfCheck() {
        let pill = CGSize(width: 80, height: 24)
        // Three 80-wide pills (+10 spacing) need 260 > 200 → they wrap to ≥2 rows.
        let wrapped = arrange(sizes: Array(repeating: pill, count: 3), in: 200, spacing: 10)
        assert(wrapped.size.height > 24, "three wide pills should wrap past one row")
        assert(wrapped.origins.contains { $0.y > 0 }, "at least one pill on a second row")
        // The same three fit on one row when the container is wide.
        let flat = arrange(sizes: Array(repeating: pill, count: 3), in: 1000, spacing: 10)
        assert(abs(flat.size.height - 24) < 0.001, "wide container keeps one row")
        assert(flat.origins.allSatisfy { $0.y == 0 }, "no wrap when it all fits")
    }
}
```

- [ ] **Step 2: Wire the self-check**

In `cyclingskibidiApp.swift` `init()` under `#if DEBUG`, add:

```swift
FlowLayout.selfCheck()
```

- [ ] **Step 3: Build and run**

Run the build command → BUILD SUCCEEDED. Launch in DEBUG → no trap (the wrap/no-wrap assertions hold).

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: add FlowLayout wrapping container"
```

---

### Task 4: Layout pass on the display surfaces

Un-squeeze the metric rows on the route card, the route brief, and the navigate HUD. Consumes `FlowLayout` (Task 3) and `RideMode` (Task 2).

**Files:**
- Modify: `cyclingskibidi/Features/Routes/RouteListView.swift` (`RouteCard`, ~lines 263-268)
- Modify: `cyclingskibidi/Features/Routes/SheetView.swift` (`summary`, ~lines 50-60)
- Modify: `cyclingskibidi/Features/Navigate/NavigateView.swift` (the ETA/arrival HUD, ~lines 115-155)

**Interfaces:**
- Consumes: `FlowLayout`, `Pill` (existing in `RouteListView.swift`), `RideMode.symbol`, `Route.mode`

- [ ] **Step 1: RouteCard — wrap the pills and add a mode pill**

In `RouteCard.body`, replace the metric `HStack` (~lines 263-268):

```swift
FlowLayout {
    Pill(text: Fmt.km(route.distanceMeters))
    Pill(text: Fmt.duration(route.expectedSeconds))
    Pill(text: route.difficulty.rawValue, tint: route.difficulty.color)
    Pill(text: route.mode.rawValue, tint: .accentColor)
}
.padding(.top, 10)
```

- [ ] **Step 2: SheetView.summary — dividers + spacing + mode**

Replace `summary` (~lines 50-60):

```swift
private var summary: some View {
    HStack(spacing: 16) {
        Text(Fmt.km(route.distanceMeters))
        Divider().frame(height: 22)
        Text(Fmt.duration(route.expectedSeconds))
        Divider().frame(height: 22)
        Text(route.difficulty.rawValue).foregroundStyle(route.difficulty.color)
        Spacer(minLength: 0)
        Label(route.mode.rawValue, systemImage: route.mode.symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }
    .font(.title2.bold())
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, collapsed ? 20 : 0)
}
```

- [ ] **Step 3: NavigateView HUD — label and separate the two big numbers**

In `navSheet`, the header `HStack(spacing: 20)` (~lines 119-127) jams `remainingDistance` and `remainingSeconds` — two unlabeled `.title.bold()` numbers — side by side. Replace that `HStack` (through its `.padding(.top, 22)`) with a labeled, divided version that matches the arrival block's caption style:

```swift
HStack(alignment: .firstTextBaseline, spacing: 16) {
    VStack(alignment: .leading, spacing: 0) {
        Text(Fmt.km(recorder.remainingDistance)).font(.title.bold())
        Text("to go").font(.caption2).foregroundStyle(.secondary)
    }
    Divider().frame(height: 34)
    VStack(alignment: .leading, spacing: 0) {
        Text(Fmt.clock(recorder.remainingSeconds)).font(.title.bold())
        Text("left").font(.caption2).foregroundStyle(.secondary)
    }
    Spacer()
    VStack(alignment: .trailing, spacing: 0) {
        Text(Fmt.eta(recorder.remainingSeconds)).font(.headline)
        Text("arrival").font(.caption2).foregroundStyle(.secondary)
    }
}
.padding(.horizontal, 20)
.padding(.top, 22)
```

Leave the `controls` stat row (`Distance / Moving / Speed`, `spacing: 24`) as-is — it is already labeled and spaced.

- [ ] **Step 4: Build and visually verify**

Run the build command → BUILD SUCCEEDED. Launch in DEBUG and open a route: the card pills wrap instead of crush on a narrow device, the brief shows dividers between distance/time/difficulty plus a mode label, and the navigate HUD has breathing room.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "fix: un-squeeze metric rows on card, brief, and navigate HUD"
```

---

### Task 5: Route.make factory + mode-aware RouteBuilderView

Extract the Route-from-plan save logic into one reusable factory, then make the builder mode-aware, wrap its pills, and let it hand save-completion back to a caller (the wizard). Consumes `RideMode`, `Routing.plan(mode:)`, `FlowLayout`.

**Files:**
- Modify: `cyclingskibidi/Routing/Routing.swift` (add `extension Route` factory at the end)
- Modify: `cyclingskibidi/Features/Routes/RouteBuilderView.swift`

**Interfaces:**
- Produces:
  - `static func Route.make(name:mode:waypoints:plan:) -> Route`
  - `RouteBuilderView(mode: RideMode = .moderate, onSaved: (() -> Void)? = nil)`
- Consumes: `Routing.plan(through:mode:)`

- [ ] **Step 1: Add the `Route.make` factory**

At the end of `Routing.swift`:

```swift
extension Route {
    /// Build a saved-ready Route from a plan. Shared by the map builder and the
    /// import paths so the two never drift on which fields get written.
    static func make(name: String, mode: RideMode, waypoints: [Coord], plan: RoutePlan) -> Route {
        let route = Route(name: name)
        route.mode = mode
        route.waypointData = Blob.encode(waypoints)
        route.polylineData = Blob.encode(plan.polyline)
        route.stepData = Blob.encode(plan.steps)
        route.elevationData = Blob.encode(plan.elevations)
        route.distanceMeters = plan.distance
        route.expectedSeconds = plan.expected
        route.ascentMeters = plan.ascent
        route.descentMeters = plan.descent
        route.difficulty = .rated(distanceMeters: plan.distance, ascentMeters: plan.ascent)
        return route
    }
}
```

- [ ] **Step 2: Add `mode` and `onSaved` to the builder**

In `RouteBuilderView.swift`, add stored properties at the top of the struct (after `@Environment(\.dismiss)`):

```swift
var mode: RideMode = .moderate
var onSaved: (() -> Void)? = nil
```

- [ ] **Step 3: Thread mode into replanning**

In `replan()`, change the plan call:

```swift
let fresh = try await Routing.plan(through: waypoints, mode: mode)
```

- [ ] **Step 4: Save through the factory, then hand back completion**

Replace `save()` with:

```swift
private func save() {
    let route = Route.make(
        name: name.isEmpty ? "Route \(Date.now.formatted(date: .abbreviated, time: .shortened))" : name,
        mode: mode, waypoints: waypoints, plan: plan)
    context.insert(route)
    try? context.save()
    (onSaved ?? { dismiss() })()
}
```

- [ ] **Step 5: Wrap the builder pills**

In `controls`, replace the metric `HStack(spacing: 10)` (~lines 130-135) with:

```swift
FlowLayout {
    Pill(text: Fmt.km(plan.distance))
    Pill(text: Fmt.duration(plan.expected))
    Pill(text: difficulty.rawValue, tint: difficulty.color)
    Pill(text: mode.rawValue, tint: .accentColor)
    if plan.ascent > 0 { Pill(text: "↗ \(Int(plan.ascent)) m") }
}
```

- [ ] **Step 6: Build and verify**

Run the build command → BUILD SUCCEEDED (existing `#Preview` uses the defaulted `mode`/`onSaved`, so it still compiles). Launch, open the builder (still reachable via the empty-state button until Task 9 rewires the entry), drop pins: pills wrap and a "Moderate" mode pill shows.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: Route.make factory and mode-aware RouteBuilderView"
```

---

### Task 6: Leisure landmark discovery

A discover panel over `MKLocalSearch`, shown in the builder only for leisure mode. Tapping a result drops a waypoint. The query builder is a pure function with a self-check; tastes persist via `@AppStorage`.

**Files:**
- Create: `cyclingskibidi/Features/Routes/Discovery.swift`
- Modify: `cyclingskibidi/Features/Routes/RouteBuilderView.swift` (show the panel when `mode == .leisure`)
- Modify: `cyclingskibidi/App/cyclingskibidiApp.swift` (wire `Discovery.selfCheck()`)

**Interfaces:**
- Produces:
  - `enum Discovery` with `static func request(tastes: String, in region: MKCoordinateRegion) -> MKLocalSearch.Request`, `static let leisureCategories: [MKPointOfInterestCategory]`, `static func selfCheck()`
  - `struct DiscoveryPanel: View` with `init(region: MKCoordinateRegion, onPick: (CLLocationCoordinate2D) -> Void)`
- Consumes: builder's `camera.region`, `waypoints`, `replan()`

- [ ] **Step 1: Write the query builder + self-check + panel**

Create `Discovery.swift`:

```swift
import SwiftUI
import MapKit

/// Leisure landmark discovery: Apple Maps POI around the map, filtered to
/// interesting categories, plus a free-text taste query. Pure query building is
/// separated from the view so it can be self-checked without the network.
enum Discovery {
    static let leisureCategories: [MKPointOfInterestCategory] = [
        .park, .nationalPark, .beach, .museum, .aquarium, .zoo, .amusementPark,
        .cafe, .restaurant, .marina, .stadium, .library,
    ]

    /// A local-search request bounded to the visible region. With tastes typed,
    /// it becomes a natural-language search; empty tastes fall back to a broad
    /// "points of interest" sweep filtered to the leisure categories.
    static func request(tastes: String, in region: MKCoordinateRegion) -> MKLocalSearch.Request {
        let trimmed = tastes.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = MKLocalSearch.Request()
        request.region = region
        request.resultTypes = .pointOfInterest
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: leisureCategories)
        request.naturalLanguageQuery = trimmed.isEmpty ? "points of interest" : trimmed
        return request
    }

    static func selfCheck() {
        let region = MKCoordinateRegion(center: .init(latitude: 1.30, longitude: 103.80),
                                        latitudinalMeters: 2000, longitudinalMeters: 2000)
        let typed = request(tastes: "  hawker, temples ", in: region)
        assert(typed.naturalLanguageQuery == "hawker, temples", "tastes should be trimmed, not blanked")
        let empty = request(tastes: "   ", in: region)
        assert(empty.naturalLanguageQuery == "points of interest", "empty tastes need a fallback query")
        assert(empty.resultTypes == .pointOfInterest)
    }
}

struct DiscoveryPanel: View {
    let region: MKCoordinateRegion
    let onPick: (CLLocationCoordinate2D) -> Void

    @AppStorage("leisureTastes") private var tastes = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "leaf.fill").foregroundStyle(.green)
                TextField("What do you feel like? (hawker, temples…)", text: $tastes)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search() } }
                Button { Task { await search() } } label: { Image(systemName: "magnifyingglass") }
            }
            if searching {
                ProgressView().frame(maxWidth: .infinity)
            } else if !results.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(results, id: \.self) { item in
                            Button {
                                onPick(item.location.coordinate)
                            } label: {
                                Text(item.name ?? "Place")
                                    .font(.footnote.weight(.medium))
                                    .lineLimit(1)
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(.quaternary, in: .capsule)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .task { await search() }   // auto-search on first show
    }

    private func search() async {
        searching = true
        defer { searching = false }
        let response = try? await MKLocalSearch(request: Discovery.request(tastes: tastes, in: region)).start()
        results = response?.mapItems ?? []
    }
}
```

- [ ] **Step 2: Show the panel in the builder for leisure mode**

In `RouteBuilderView.controls`, at the top of the `VStack(spacing: 12)` (before the `if planning` block), add:

```swift
if mode == .leisure, let region = camera.region {
    DiscoveryPanel(region: region) { coord in
        waypoints.append(Coord(coord))
        camera = .region(.init(center: coord, latitudinalMeters: 1500, longitudinalMeters: 1500))
        replan()
    }
}
```

- [ ] **Step 3: Wire the self-check**

In `cyclingskibidiApp.swift` `init()` under `#if DEBUG`, add:

```swift
Discovery.selfCheck()
```

- [ ] **Step 4: Build and run**

Run the build command → BUILD SUCCEEDED. Launch in DEBUG → no trap (query-builder assertions hold). (Full POI results need a real map region and network; the panel shows for leisure mode once Task 8 can launch the builder in that mode.)

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: leisure landmark discovery panel"
```

---

### Task 7: Providers — list recent cycling workouts as a route source

Expose the HealthKit workouts as a pickable list (for building a Route from one) without touching the existing bulk "import as ride history" path.

**Files:**
- Modify: `cyclingskibidi/Routing/Providers.swift`

**Interfaces:**
- Produces:
  - `static func Providers.recentCyclingWorkouts(limit: Int = 30) async throws -> [HKWorkout]`
  - `static func Providers.waypoints(for workout: HKWorkout, max: Int = 12) async throws -> [Coord]`
- Consumes: existing `Providers.requestAuthorization()`, `Providers.locations(for:)` (make it `static` accessible), `Geo.sample`

- [ ] **Step 1: Expose a workout lister**

In `Providers.swift`, add (the query mirrors the one inside `importRides`, so factor the shared descriptor if convenient, but a second small query is acceptable):

```swift
/// Recent cycling workouts, newest first — the source list for building a Route
/// from a past ride. Does not import anything; read-only.
static func recentCyclingWorkouts(limit: Int = 30) async throws -> [HKWorkout] {
    guard healthAvailable else { return [] }
    try await requestAuthorization()
    let descriptor = HKSampleQueryDescriptor(
        predicates: [HKSamplePredicate.workout(HKQuery.predicateForWorkouts(with: .cycling))],
        sortDescriptors: [SortDescriptor(\HKWorkout.startDate, order: .reverse)],
        limit: limit)
    return try await descriptor.result(for: store)
}
```

- [ ] **Step 2: Expose a workout → waypoints helper**

Add, reusing the existing private `locations(for:)` (change its access from `private static` to `static`):

```swift
/// A workout's GPS trace, thinned to the handful of waypoints the router needs.
static func waypoints(for workout: HKWorkout, max count: Int = 12) async throws -> [Coord] {
    let locs = try await locations(for: workout)
    let coords = locs.map(\.coordinate)
    return Geo.sample(coords, count: Swift.min(count, coords.count)).map { Coord($0) }
}
```

- [ ] **Step 3: Confirm the history import is untouched**

Verify `importRides(into:)` still exists and is unchanged (grep): `grep -n "func importRides" cyclingskibidi/Routing/Providers.swift` → still present.

- [ ] **Step 4: Build**

Run the build command → BUILD SUCCEEDED. (HealthKit results need a device/simulator with data; no self-check — the testable thinning is `Geo.sample`, already covered by `Geo.selfCheck`.)

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: expose recent cycling workouts as a route source"
```

---

### Task 8: CreateRouteFlow wizard

The guided sheet: mode → source → (map builder | import) → save. Import builds a plannable Route from the track. Consumes Tasks 2, 5, 6, 7.

**Files:**
- Create: `cyclingskibidi/Features/Routes/CreateRouteFlow.swift`
- Modify: `cyclingskibidi/App/cyclingskibidiApp.swift` (wire `CreateRouteFlow.selfCheck()`)

**Interfaces:**
- Produces: `struct CreateRouteFlow: View` (presented via `.sheet`; dismisses itself on completion)
- Consumes: `RideMode`, `RouteBuilderView(mode:onSaved:)`, `Route.make`, `Routing.plan(through:mode:)`, `GPXParser.parse`/`makeWaypoints`, `Providers.recentCyclingWorkouts`/`waypoints(for:)`

- [ ] **Step 1: Write the flow shell + mode step + source step**

Create `CreateRouteFlow.swift`:

```swift
import SwiftUI
import SwiftData
import MapKit
import HealthKit
import UniformTypeIdentifiers

/// Guided route creation: pick a mode, pick a source, then build or import.
/// Import means "build a plannable Route from the track", never a logged ride.
///
/// The chosen RideMode is carried as the navigation path value (mode → source),
/// so there is no optional-mode state to guard. The map builder owns its own
/// NavigationStack, so SourceStep presents it as a fullScreenCover rather than
/// pushing it here — nesting NavigationStacks is what we are avoiding.
struct CreateRouteFlow: View {
    @Environment(\.dismiss) private var dismiss

    @State private var path: [RideMode] = []

    var body: some View {
        NavigationStack(path: $path) {
            modeStep
                .navigationTitle("New route")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                .navigationDestination(for: RideMode.self) { m in
                    SourceStep(mode: m, onFinish: { dismiss() })
                        .navigationTitle(m.rawValue)
                        .navigationBarTitleDisplayMode(.inline)
                }
        }
    }

    private var modeStep: some View {
        VStack(spacing: 14) {
            Text("How do you want to ride?").font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading)
            ForEach(RideMode.allCases) { m in
                Button {
                    path.append(m)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: m.symbol).font(.title2).frame(width: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.rawValue).font(.headline)
                            Text(m.subtitle).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(16)
                    .background(.background.secondary, in: .rect(cornerRadius: 16))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(20)
    }

    static func selfCheck() {
        // RideMode is the navigation path element (mode → source); it must be
        // Hashable and round-trip, or the wizard cannot advance.
        assert(RideMode.allCases.allSatisfy { RideMode(rawValue: $0.rawValue) != nil })
        assert(Set(RideMode.allCases).count == RideMode.allCases.count)
    }
}
```

- [ ] **Step 2: Write the source step (map + three import paths)**

Append to `CreateRouteFlow.swift`:

```swift
/// The four ways to seed a route. Map presents the builder (which owns its own
/// NavigationStack) as a fullScreenCover; the three import paths parse a track,
/// plan it, and open a save preview.
private struct SourceStep: View {
    let mode: RideMode
    let onFinish: () -> Void

    /// One sheet, enum-driven — never two `.sheet` modifiers on one view. The
    /// workout picker swaps this to `.preview` in place, so there is no
    /// sheet-over-sheet race.
    private enum ActiveSheet: Identifiable {
        case workouts
        case preview(PreviewBox)
        var id: String {
            switch self {
            case .workouts:        return "workouts"
            case .preview(let b):  return b.id.uuidString
            }
        }
    }

    @State private var showingMap = false
    @State private var importingFile = false
    @State private var busy = false
    @State private var message: String?
    @State private var activeSheet: ActiveSheet?

    var body: some View {
        List {
            Button { showingMap = true } label: { Label("Create from map", systemImage: "map") }
            Button { importingFile = true } label: { Label("Import a GPX file", systemImage: "doc.badge.plus") }
            Button { activeSheet = .workouts } label: { Label("Import from Garmin / COROS", systemImage: "applewatch.side.right") }
            Button { importingFile = true } label: { Label("Import from Strava (GPX export)", systemImage: "arrow.down.doc") }
        }
        .fullScreenCover(isPresented: $showingMap) {
            // Builder owns its NavigationStack; Save closes the cover and the flow.
            RouteBuilderView(mode: mode) { showingMap = false; onFinish() }
        }
        .fileImporter(isPresented: $importingFile,
                      allowedContentTypes: [.xml, .init(filenameExtension: "gpx") ?? .xml],
                      allowsMultipleSelection: false) { result in
            Task { await handleFile(result) }
        }
        .overlay { if busy { ProgressView("Building route…").controlSize(.large) } }
        .alert("Import", isPresented: .constant(message != nil)) { Button("OK") { message = nil } } message: { Text(message ?? "") }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .workouts:
                WorkoutPicker(mode: mode) { box in activeSheet = .preview(box) }
            case .preview(let box):
                RoutePreview(name: box.name, waypoints: box.waypoints, plan: box.plan, mode: mode) { onFinish() }
            }
        }
    }

    private func handleFile(_ result: Result<[URL], Error>) async {
        busy = true; defer { busy = false }
        do {
            guard let url = try result.get().first else { return }
            let parsed = try GPXParser.parse(url)
            let waypoints = parsed.makeWaypoints()
            guard waypoints.count >= 2 else { message = "No usable track in that file."; return }
            let plan = try await Routing.plan(through: waypoints, mode: mode)
            activeSheet = .preview(PreviewBox(name: parsed.name, waypoints: waypoints, plan: plan))
        } catch {
            message = error.localizedDescription
        }
    }
}

/// A built-but-unsaved route, carried into the save preview. Stable `id` so the
/// sheet presents once rather than thrashing on identity.
private struct PreviewBox: Identifiable {
    let id = UUID()
    let name: String
    let waypoints: [Coord]
    let plan: RoutePlan
}
```

- [ ] **Step 3: Write the workout picker**

Append:

```swift
/// Lists recent cycling workouts; the chosen one is thinned to waypoints and
/// planned into a Route preview.
private struct WorkoutPicker: View {
    @Environment(\.dismiss) private var dismiss
    let mode: RideMode
    let onBuilt: (PreviewBox) -> Void

    @State private var workouts: [HKWorkout] = []
    @State private var loading = true
    @State private var building = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if loading { ProgressView() }
                else if workouts.isEmpty {
                    ContentUnavailableView("No cycling workouts",
                        systemImage: "applewatch.slash",
                        description: Text("Garmin and COROS rides show up once their app has synced to Apple Health."))
                } else {
                    List(workouts, id: \.uuid) { w in
                        Button { Task { await build(w) } } label: {
                            VStack(alignment: .leading) {
                                Text(w.startDate.formatted(date: .abbreviated, time: .shortened))
                                Text(Fmt.km(w.statistics(for: HKQuantityType(.distanceCycling))?.sumQuantity()?.doubleValue(for: .meter()) ?? 0))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Pick a ride")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .overlay { if building { ProgressView("Building route…").controlSize(.large) } }
            .alert("Import", isPresented: .constant(error != nil)) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        }
        .task {
            loading = true
            workouts = (try? await Providers.recentCyclingWorkouts()) ?? []
            loading = false
        }
    }

    private func build(_ workout: HKWorkout) async {
        building = true; defer { building = false }
        do {
            let waypoints = try await Providers.waypoints(for: workout)
            guard waypoints.count >= 2 else { error = "That ride has no GPS track."; return }
            let plan = try await Routing.plan(through: waypoints, mode: mode)
            // Parent swaps the sheet to the preview in place; do not dismiss here.
            onBuilt(PreviewBox(name: "\(workout.startDate.formatted(date: .abbreviated, time: .omitted)) ride",
                               waypoints: waypoints, plan: plan))
        } catch {
            self.error = error.localizedDescription
        }
    }
}
```

- [ ] **Step 4: Write the preview + save view**

Append:

```swift
/// Confirm the built route, name it, and save. Reuses RouteSketch for the shape.
private struct RoutePreview: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let name: String
    let waypoints: [Coord]
    let plan: RoutePlan
    let mode: RideMode
    let onSaved: () -> Void

    @State private var editedName: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                RouteSketch(coords: plan.polyline).frame(height: 160)
                FlowLayout {
                    Pill(text: Fmt.km(plan.distance))
                    Pill(text: Fmt.duration(plan.expected))
                    Pill(text: Difficulty.rated(distanceMeters: plan.distance, ascentMeters: plan.ascent).rawValue,
                         tint: Difficulty.rated(distanceMeters: plan.distance, ascentMeters: plan.ascent).color)
                    Pill(text: mode.rawValue, tint: .accentColor)
                }
                TextField("Route name", text: $editedName).textFieldStyle(.roundedBorder)
                Spacer()
            }
            .padding(20)
            .navigationTitle("Save route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
            .onAppear { if editedName.isEmpty { editedName = name } }
        }
    }

    private func save() {
        let route = Route.make(name: editedName.isEmpty ? name : editedName,
                               mode: mode, waypoints: waypoints, plan: plan)
        context.insert(route)
        try? context.save()
        dismiss()
        onSaved()
    }
}
```

- [ ] **Step 5: Wire the self-check**

In `cyclingskibidiApp.swift` `init()` under `#if DEBUG`, add:

```swift
CreateRouteFlow.selfCheck()
```

- [ ] **Step 6: Build and run**

Run the build command → BUILD SUCCEEDED. Launch in DEBUG → no trap. (End-to-end exercise happens in Task 9 once the main page can present the flow.)

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: CreateRouteFlow wizard (mode → source → save)"
```

---

### Task 9: Rewire the main page

Move search to the top, make `+` launch the wizard, and remove the old inline menu + importers now living in the wizard.

**Files:**
- Modify: `cyclingskibidi/Features/Routes/RouteListView.swift`

**Interfaces:**
- Consumes: `CreateRouteFlow`

- [ ] **Step 1: Replace builder/import state with one `creating` flag**

In `RouteListView`, remove the state that moved into the wizard — `building`, `importingFile`, `importMessage`, `importing` — and add:

```swift
@State private var creating = false
```

Remove the `importHealth()` and `handleFiles(_:)` methods and the `.fileImporter`, the import `.alert`, and the `.overlay { if importing … }` modifiers (all now in `CreateRouteFlow` / `SourceStep`).

- [ ] **Step 2: Search on top**

On the `ScrollView`, remove `.searchToolbarBehavior(.minimize)` so the `.searchable` field stays visible at the top. Keep `.searchable(text: $search, placement: .toolbar, prompt: "Search...")` — dropping `.minimize` is the whole change.

- [ ] **Step 3: `+` launches the wizard; keep Stats**

Replace the top-trailing `Menu { … }` in `toolbarItems` with:

```swift
ToolbarItem(placement: .topBarTrailing) {
    Button { creating = true } label: { Image(systemName: "plus") }
}
```

Leave the top-leading Stats button as-is.

- [ ] **Step 4: Present the wizard; point the empty state at it**

Replace `.sheet(isPresented: $building) { RouteBuilderView() }` with:

```swift
.sheet(isPresented: $creating) { CreateRouteFlow() }
```

In `emptyState`, change the button action from `building = true` to `creating = true`. In the `#if DEBUG onAppear` (`if Demo.screen == "build" { building = true }`), change `building` to `creating`.

- [ ] **Step 5: Build and end-to-end verify**

Run the build command → BUILD SUCCEEDED. Launch in DEBUG:
- Search field shows at the top of the Routes screen.
- Tapping `+` opens the wizard → pick Leisure → Create from map → the discovery panel appears; drop a couple of pins → Save closes the whole flow and the new route (with a "Leisure" pill) is on the board.
- `+` → Moderate → Import a GPX file → pick a `.gpx` → preview → Save adds the route.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: main page — search on top, + launches create wizard"
```

---

## Self-Review

**Spec coverage:**
- §A mode seam → Task 2 ✓
- §B layout (FlowLayout, RouteCard, SheetView, NavigateView HUD) → Tasks 3, 4; builder pills → Task 5 ✓
- §C main page (search top, `+` → wizard) → Task 9 ✓
- §D wizard (mode → source → save; GPX/Strava/Garmin import builds a Route; `Routing.plan(mode:)`) → Tasks 5, 7, 8 ✓
- §E leisure discovery (MKLocalSearch, tastes @AppStorage) → Task 6 ✓
- §F file organization → Task 1 ✓
- §G Phase 2 → out of scope; seam delivered by Tasks 2 & 5 ✓
- Testing convention (selfCheck) → RideMode, FlowLayout, Discovery, CreateRouteFlow self-checks wired into app init ✓

**Placeholder scan:** No TBD/TODO in task steps; every code step carries real code. The one deferred item (`Routing.plan` ignoring `mode`) is a deliberate, documented Phase 2 seam, not a placeholder.

**Type consistency:**
- `Route.make(name:mode:waypoints:plan:)` — defined Task 5, used Tasks 5, 8 ✓
- `RouteBuilderView(mode:onSaved:)` — defined Task 5, used Task 8 ✓
- `Routing.plan(through:mode:fetchElevation:)` — defined Task 2, used Tasks 5, 8 ✓
- `Providers.recentCyclingWorkouts(limit:)` / `Providers.waypoints(for:max:)` — defined Task 7, used Task 8 ✓
- `Discovery.request(tastes:in:)` / `DiscoveryPanel(region:onPick:)` — defined Task 6, used Task 6 ✓
- `CreateRouteFlow()` — defined Task 8, used Task 9 ✓
- `RideMode` (`.rawValue`, `.subtitle`, `.symbol`, `.allCases`) — defined Task 2, used Tasks 4, 5, 6, 8 ✓

Note for the implementer: `Providers.locations(for:)` is currently `private static` — Task 7 requires widening it to `static`. `MKMapItem.location` / `.coordinate` usage follows the existing calls in `RouteBuilderView` and `Providers`.
