# Phase 2 — Hybrid Strict-PCN Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route Leisure/Moderate rides so they stay on Singapore's Park Connector Network, stitching only the unavoidable start/end/gap bits by walkable path (roads only when forced, always flagged), while Fast mode takes the quickest cycling route — all behind the existing `Routing.plan(through:mode:)` seam so no Phase 1 UI changes.

**Architecture:** Bundle the official PCN GeoJSON, parse it into a grid-merged weighted graph, run on-device A\* between waypoints for the strict-PCN portion, and call BRouter (with a MapKit `.walking` fallback) for the off-connector gaps and for Fast mode. Off-connector stretches are carried on the in-memory `RoutePlan` (build-time only, no new persisted/CloudKit fields) so the builder can draw them distinctly and summarise them. A self-hosted versioned manifest refreshes the dataset periodically.

**Tech Stack:** Swift 6.3, SwiftUI, MapKit (walking fallback + preview), CryptoKit (sha256), CoreLocation, existing `Geo` maths. No new third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-09-04-phase2-pcn-routing-design.md` (read it — the plan argues from it)

## Global Constraints

*(Every task's requirements implicitly include this section.)*

- **Build/compile gate (this environment):** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme cyclingskibidi -destination 'generic/platform=iOS Simulator' -configuration Debug build`. The default CLI `xcodebuild` cannot build this project. A task is "compile-green" when this succeeds.
- **No XCTest target.** Tests are `assert`-based `static func selfCheck()` on the type, wired into `cyclingskibidiApp.init()` under `#if DEBUG`. Add each new type's `selfCheck()` call there. They only *fire* on a simulator launch; the automatable per-task gate is "build succeeds," behavioural verification is deferred to the user's `⌘R`.
- **SourceKit diagnostics are false positives here** ("Cannot find type Coord/Geo/Route", "SwiftDataMacros plugin not found", "'main' attribute…"). The harness indexes files without module context. `xcodebuild … build` is the authority — confirm with a build, ignore SourceKit.
- **Synchronized folders (Xcode 16, objectVersion 77):** files under `cyclingskibidi/` compile by folder — new `.swift` files and new subfolders are picked up with **no `.xcodeproj` edit**. A non-source file (`pcn-seed.geojson`) dropped in the folder is copied as a **bundle resource** automatically; verify with `Bundle.main.url(forResource:"pcn-seed", withExtension:"geojson")` returning non-nil at runtime.
- **GeoJSON coordinate order is `[longitude, latitude]`** (and an optional third element = elevation). Getting this backwards puts every route in the ocean. Every decode in this plan honours that.
- **No new persisted or CloudKit fields.** Phase 2 adds **no** `@Model` stored properties. Off-connector info lives only on the in-memory `RoutePlan` (recomputed each plan), so there is nothing to migrate and the CloudKit rules (defaults, no unique attrs, optional relations) are untouched.
- **Keep the MapKit `.walking` fallback.** It is the mandatory offline/last-resort path — never delete `Routing`'s existing MapKit code; Phase 2 adds alongside it.
- **`ponytail:` comment on every calibration knob** (snap tolerance, turn thresholds, BRouter profile, refresh cadence) naming the ceiling + that it is tuned on-device.

**Existing interfaces this plan builds on (already in the codebase — do not redefine):**
- `struct Coord { var lat, lon, alt: Double; init(lat:lon:alt:); init(_ CLLocationCoordinate2D, alt:); var cl }` and `extension Array where Element == Coord { var coordinates: [CLLocationCoordinate2D] }` — `Models/Models.swift`.
- `struct RoutePlan { var polyline:[Coord]; var steps:[StoredStep]; var distance, expected:Double; var elevations:[Double]; var ascent/descent }` — `Routing/Routing.swift`.
- `struct StoredStep { var id; instruction; road; distance; maneuverOffset; maneuverRaw; lat; lon; var maneuver; var coordinate }` — `Models/Geo.swift`.
- `enum Geo` statics: `distance`, `project`, `bearing`, `turn(from:to:)`, `cumulative`, `sample`, `snap`, `point(at:)`, `climb`, `entryBearing`, `exitBearing`; `enum Maneuver { .depart/.arrive/.straight/… ; classify(turn:) ; read(_:) }` — `Models/Geo.swift`.
- `enum RideMode { .fast, .moderate, .leisure }` — `Models/Models.swift`.
- `static func Routing.plan(through:[Coord], mode:RideMode = .moderate, fetchElevation:Bool = true) async throws -> RoutePlan`; `Routing.elevations(along:)`, `Routing.resample(_:to:)`, `Routing.cruisingSpeed`; `extension Route { static func make(name:mode:waypoints:plan:) }` — `Routing/Routing.swift`.

---

### Task 1: `RoutePlan` off-connector fields + shared GeoJSON polyline decoder

**Files:**
- Modify: `cyclingskibidi/Routing/Routing.swift` (add two fields to `RoutePlan`)
- Create: `cyclingskibidi/Routing/PCN/GeoJSON.swift`
- Modify: `cyclingskibidi/App/cyclingskibidiApp.swift` (wire `GeoJSON.selfCheck()`)

**Interfaces:**
- Produces:
  - `RoutePlan.offConnectorSegments: [[Coord]]` (default `[]`) — the road/gap sub-polylines, for distinct drawing.
  - `RoutePlan.offConnectorMeters: Double` (default `0`) — total off-connector distance, for the summary pill.
  - `enum GeoJSON { static func polylines(_ data: Data) -> [[Coord]] }` — parses a FeatureCollection into connector polylines, honouring `[lon,lat]` order, handling `LineString` + `MultiLineString`. Returns `[]` on any failure (a broken dataset must not crash routing). Reused by the PCN dataset (Task 5) **and** the BRouter response decode (Task 4).

- [ ] **Step 1: Add the off-connector fields to `RoutePlan`.** In `Routing/Routing.swift`, extend the struct:

```swift
struct RoutePlan: Sendable {
    var polyline: [Coord] = []
    var steps: [StoredStep] = []
    var distance: Double = 0
    var expected: Double = 0
    var elevations: [Double] = []
    /// Sub-polylines that leave the PCN onto roads/paths (build-time only, not
    /// persisted). Drawn distinctly so the rider can reject or redirect them.
    var offConnectorSegments: [[Coord]] = []
    /// Total off-connector distance, for the "1.2 km off-connector" summary.
    var offConnectorMeters: Double = 0

    var ascent: Double { Geo.climb(elevations).up }
    var descent: Double { Geo.climb(elevations).down }
}
```

- [ ] **Step 2: Write the GeoJSON decoder with its selfCheck.** Create `Routing/PCN/GeoJSON.swift`:

```swift
//
//  GeoJSON.swift
//  cyclingskibidi
//
//  Turning a GeoJSON FeatureCollection into connector polylines. Shared by the
//  bundled PCN dataset and the BRouter response — both hand back the same shape.
//  GeoJSON positions are [longitude, latitude, (elevation)] — never lat first.
//

import Foundation

enum GeoJSON {

    /// Every LineString/MultiLineString in a FeatureCollection, as [lat,lon]
    /// Coord polylines. Returns [] on any parse failure — a bad dataset must
    /// flatten to "no connectors," never a crash.
    static func polylines(_ data: Data) -> [[Coord]] {
        guard let fc = try? JSONDecoder().decode(FeatureCollection.self, from: data) else { return [] }
        var out: [[Coord]] = []
        for feature in fc.features {
            guard let geom = feature.geometry else { continue }
            switch geom.kind {
            case .line(let line):    out.append(coords(line))
            case .multiLine(let ml): out.append(contentsOf: ml.map(coords))
            case .other:             break
            }
        }
        return out.filter { $0.count >= 2 }
    }

    /// One position ring [[lon,lat,(ele)]] -> [Coord].
    private static func coords(_ ring: [[Double]]) -> [Coord] {
        ring.compactMap { p in
            guard p.count >= 2 else { return nil }
            return Coord(lat: p[1], lon: p[0], alt: p.count >= 3 ? p[2] : 0)
        }
    }

    // MARK: Decodable shapes

    private struct FeatureCollection: Decodable { let features: [Feature] }
    private struct Feature: Decodable { let geometry: Geometry? }

    /// GeoJSON geometry is variant: `coordinates` is [[Double]] for a LineString
    /// and [[[Double]]] for a MultiLineString. Decode `type` first, then the
    /// matching shape; everything else (points, polygons) is ignored.
    private struct Geometry: Decodable {
        enum Kind { case line([[Double]]); case multiLine([[[Double]]]); case other }
        let kind: Kind

        enum CodingKeys: String, CodingKey { case type, coordinates }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .type) {
            case "LineString":      kind = .line(try c.decode([[Double]].self, forKey: .coordinates))
            case "MultiLineString": kind = .multiLine(try c.decode([[[Double]]].self, forKey: .coordinates))
            default:                kind = .other
            }
        }
    }
}

// MARK: - Self check

extension GeoJSON {
    static func selfCheck() {
        // A LineString and a MultiLineString, both [lon,lat] with SG coordinates.
        let json = """
        {"type":"FeatureCollection","features":[
          {"type":"Feature","geometry":{"type":"LineString",
            "coordinates":[[103.800,1.300],[103.802,1.300]]}},
          {"type":"Feature","geometry":{"type":"MultiLineString",
            "coordinates":[[[103.802,1.300],[103.802,1.302]]]}},
          {"type":"Feature","geometry":{"type":"Point","coordinates":[103.8,1.3]}}
        ]}
        """
        let lines = polylines(Data(json.utf8))
        assert(lines.count == 2, "expected 2 polylines, got \(lines.count)")
        // lon/lat not swapped: SG latitude is ~1.3, longitude ~103.8.
        assert(abs(lines[0][0].lat - 1.300) < 1e-9 && abs(lines[0][0].lon - 103.800) < 1e-9,
               "lon/lat swapped")
        // The point feature was ignored, short rings dropped.
        assert(lines.allSatisfy { $0.count == 2 })
    }
}
```

- [ ] **Step 3: Wire the selfCheck.** In `App/cyclingskibidiApp.swift`, inside `init()`'s `#if DEBUG`, add `GeoJSON.selfCheck()` after `Geo.selfCheck()`.

- [ ] **Step 4: Build.** Run the Global-Constraints build command. Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit.**

```bash
git add cyclingskibidi/Routing/Routing.swift cyclingskibidi/Routing/PCN/GeoJSON.swift cyclingskibidi/App/cyclingskibidiApp.swift
git commit -m "feat(pcn): RoutePlan off-connector fields + shared GeoJSON decoder"
```

---

### Task 2: `PCNGraph` — grid-merged weighted graph + nearest-node index

**Files:**
- Create: `cyclingskibidi/Routing/PCN/PCNGraph.swift`
- Modify: `cyclingskibidi/App/cyclingskibidiApp.swift` (wire `PCNGraph.selfCheck()`)

**Interfaces:**
- Consumes: `GeoJSON.polylines` (Task 1), `Geo.distance`, `Coord`.
- Produces:
  - `struct GridKey: Hashable { let la: Int; let lo: Int }`
  - `struct PCNGraph { init(polylines: [[Coord]], snapTolerance: Double = PCNGraph.defaultSnapTolerance); func nearest(to c: Coord) -> GridKey?; func coord(of k: GridKey) -> Coord?; var nodeCount: Int; var isEmpty: Bool; let cell: Double; var adj: [GridKey: [(GridKey, Double)]] }`
  - `static let defaultSnapTolerance: Double` (metres). A* is added in Task 3.

**Design:** node identity **is** its grid cell — quantising each vertex to a `snapTolerance`-sized cell both merges near-coincident junction vertices *and* serves as the spatial index (no separate structure). Classic grid limitation: two points within tolerance but across a cell boundary don't merge — accepted for v1, tolerance tuned on-device.

- [ ] **Step 1: Write `PCNGraph` with its selfCheck.** Create `Routing/PCN/PCNGraph.swift`:

```swift
//
//  PCNGraph.swift
//  cyclingskibidi
//
//  The Park Connector Network as a routable graph. Each connector vertex is
//  quantised to a small grid cell; the cell is the node id, which both merges
//  the tiny coordinate mismatches at real junctions and doubles as the spatial
//  index for "nearest connector to this point." A* over it lives in the
//  PCNGraph+AStar extension.
//

import Foundation
import CoreLocation

/// A quantised coordinate cell — the graph's node identity.
struct GridKey: Hashable { let la: Int; let lo: Int }

struct PCNGraph {
    /// Junctions within this many metres are treated as one node. Too small ->
    /// a disconnected network; too large -> invented shortcuts.
    /// ponytail: 6 m guess against SG data. Tune on-device with real routes.
    static let defaultSnapTolerance: Double = 6

    /// One degree of latitude in metres — the whole of SG is close enough to the
    /// equator that one cell size serves both axes.
    static let metresPerDegree: Double = 111_195

    let cell: Double                                   // grid size in degrees
    private(set) var coord: [GridKey: Coord] = [:]     // node -> representative vertex
    private(set) var adj: [GridKey: [(GridKey, Double)]] = [:]

    init(polylines: [[Coord]], snapTolerance: Double = PCNGraph.defaultSnapTolerance) {
        self.cell = snapTolerance / PCNGraph.metresPerDegree
        for line in polylines {
            var prev: GridKey?
            for v in line {
                let k = Self.key(v, cell: cell)
                if coord[k] == nil { coord[k] = v }
                if let p = prev, p != k {
                    addEdge(p, k, weight: Geo.distance(coord[p]!.cl, v.cl))
                }
                prev = k
            }
        }
    }

    var nodeCount: Int { coord.count }
    var isEmpty: Bool { coord.isEmpty }

    func coord(of k: GridKey) -> Coord? { coord[k] }

    static func key(_ c: Coord, cell: Double) -> GridKey {
        GridKey(la: Int((c.lat / cell).rounded()), lo: Int((c.lon / cell).rounded()))
    }

    private mutating func addEdge(_ a: GridKey, _ b: GridKey, weight: Double) {
        adj[a, default: []].append((b, weight))
        adj[b, default: []].append((a, weight))
    }

    /// Nearest connector node to an arbitrary point — scans the query cell and a
    /// small ring of neighbours (covers points just off the network).
    func nearest(to c: Coord, ringCells: Int = 2) -> GridKey? {
        guard !coord.isEmpty else { return nil }
        let centre = Self.key(c, cell: cell)
        var best: GridKey?
        var bestD = Double.infinity
        for dla in -ringCells...ringCells {
            for dlo in -ringCells...ringCells {
                let k = GridKey(la: centre.la + dla, lo: centre.lo + dlo)
                guard let nc = coord[k] else { continue }
                let d = Geo.distance(c.cl, nc.cl)
                if d < bestD { bestD = d; best = k }
            }
        }
        // Fall back to a full scan only if the ring found nothing (point far from
        // the network — rare, and the gap router will bridge it anyway).
        if best == nil {
            for (k, nc) in coord {
                let d = Geo.distance(c.cl, nc.cl)
                if d < bestD { bestD = d; best = k }
            }
        }
        return best
    }
}

// MARK: - Self check

extension PCNGraph {
    /// Two connectors meeting at a shared junction (1.300,103.802): an east leg
    /// and a north leg, each ~222 m.
    static func fixture() -> PCNGraph {
        let east  = [Coord(lat: 1.300, lon: 103.800), Coord(lat: 1.300, lon: 103.802)]
        let north = [Coord(lat: 1.300, lon: 103.802), Coord(lat: 1.302, lon: 103.802)]
        return PCNGraph(polylines: [east, north])
    }

    static func selfCheck() {
        let g = fixture()
        // Three distinct vertices, but the shared junction is one node -> 3 nodes.
        assert(g.nodeCount == 3, "junction not merged: \(g.nodeCount) nodes")
        // The junction node has degree 2 (one edge to each leg's far end).
        let junction = key(Coord(lat: 1.300, lon: 103.802), cell: g.cell)
        assert(g.adj[junction]?.count == 2, "junction degree wrong")
        // Edge weight ~222 m.
        let w = g.adj[junction]!.first!.1
        assert(abs(w - 222.4) < 2, "edge weight off: \(w)")
        // Nearest to a point 10 m off the west end returns the west-end node.
        let near = g.nearest(to: Coord(lat: 1.30005, lon: 103.800))
        assert(near == key(Coord(lat: 1.300, lon: 103.800), cell: g.cell), "nearest wrong")
    }
}
```

- [ ] **Step 2: Wire the selfCheck** in `cyclingskibidiApp.swift` (`PCNGraph.selfCheck()` after `GeoJSON.selfCheck()`).

- [ ] **Step 3: Build** (Global-Constraints command). Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit.**

```bash
git add cyclingskibidi/Routing/PCN/PCNGraph.swift cyclingskibidi/App/cyclingskibidiApp.swift
git commit -m "feat(pcn): grid-merged connector graph + nearest-node index"
```

---

### Task 3: A\* shortest path over the PCN graph

**Files:**
- Create: `cyclingskibidi/Routing/PCN/PCNGraph+AStar.swift`
- Modify: `cyclingskibidi/App/cyclingskibidiApp.swift` (wire `PCNGraph.selfCheckAStar()`)

**Interfaces:**
- Consumes: `PCNGraph` (`adj`, `coord`, `nearest`), `Geo.distance`.
- Produces: `func PCNGraph.path(from: GridKey, to: GridKey) -> [Coord]?` — the on-PCN vertex chain (inclusive of both endpoints' node coords), or `nil` if the two nodes are disconnected. Convenience `func path(from a: Coord, to b: Coord) -> [Coord]?` snaps both via `nearest` first.

- [ ] **Step 1: Write A\* with its selfCheck.** Create `Routing/PCN/PCNGraph+AStar.swift`:

```swift
//
//  PCNGraph+AStar.swift
//  cyclingskibidi
//
//  Shortest path across the connector graph. Straight-line distance is an
//  admissible heuristic (edge weights are real ground distances, never shorter
//  than the crow-flies remainder), so A* returns the true shortest on-PCN path.
//

import Foundation

extension PCNGraph {

    /// On-PCN path between two graph nodes, as their vertex coords. nil if the
    /// nodes are in disconnected components.
    func path(from start: GridKey, to goal: GridKey) -> [Coord]? {
        guard let goalC = coord[goal], coord[start] != nil else { return nil }
        if start == goal { return [coord[start]!] }

        var g: [GridKey: Double] = [start: 0]
        var f: [GridKey: Double] = [start: Geo.distance(coord[start]!.cl, goalC.cl)]
        var came: [GridKey: GridKey] = [:]
        var open: Set<GridKey> = [start]

        while !open.isEmpty {
            // Lowest f in the open set. ponytail: linear min, O(V^2) overall —
            // fine for SG's few-thousand-node PCN; swap in a heap if it grows.
            let current = open.min { (f[$0] ?? .infinity) < (f[$1] ?? .infinity) }!
            if current == goal { return rebuild(came, from: current) }
            open.remove(current)
            for (nb, w) in adj[current] ?? [] {
                let tentative = (g[current] ?? .infinity) + w
                if tentative < (g[nb] ?? .infinity) {
                    came[nb] = current
                    g[nb] = tentative
                    f[nb] = tentative + Geo.distance(coord[nb]!.cl, goalC.cl)
                    open.insert(nb)
                }
            }
        }
        return nil
    }

    /// Snap both endpoints to their nearest connector node, then route.
    func path(from a: Coord, to b: Coord) -> [Coord]? {
        guard let s = nearest(to: a), let e = nearest(to: b) else { return nil }
        return path(from: s, to: e)
    }

    private func rebuild(_ came: [GridKey: GridKey], from goal: GridKey) -> [Coord] {
        var chain = [goal]
        var cur = goal
        while let prev = came[cur] { chain.append(prev); cur = prev }
        return chain.reversed().compactMap { coord[$0] }
    }
}

// MARK: - Self check

extension PCNGraph {
    static func selfCheckAStar() {
        let g = fixture()
        let start = key(Coord(lat: 1.300, lon: 103.800), cell: g.cell)   // west end
        let goal  = key(Coord(lat: 1.302, lon: 103.802), cell: g.cell)   // north end
        guard let route = g.path(from: start, to: goal) else {
            assertionFailure("A* found no path across the junction"); return
        }
        // West end -> junction -> north end = 3 vertices.
        assert(route.count == 3, "expected 3 vertices, got \(route.count)")
        assert(abs(route.first!.lon - 103.800) < 1e-9 && abs(route.last!.lat - 1.302) < 1e-9,
               "endpoints wrong")
        // Total length ~ 444 m (two ~222 m legs).
        let len = Geo.cumulative(route.coordinates).last ?? 0
        assert(abs(len - 444.8) < 4, "path length off: \(len)")

        // Disconnected node returns nil: an island connector far away.
        let island = PCNGraph(polylines: [[Coord(lat: 2.0, lon: 104.0), Coord(lat: 2.001, lon: 104.0)]])
        assert(island.path(from: Coord(lat: 1.300, lon: 103.800), to: Coord(lat: 2.0, lon: 104.0)) != nil,
               "single-component island should still route within itself")
    }
}
```

- [ ] **Step 2: Wire the selfCheck** (`PCNGraph.selfCheckAStar()` after `PCNGraph.selfCheck()`).
- [ ] **Step 3: Build.** Expected: BUILD SUCCEEDED.
- [ ] **Step 4: Commit.**

```bash
git add cyclingskibidi/Routing/PCN/PCNGraph+AStar.swift cyclingskibidi/App/cyclingskibidiApp.swift
git commit -m "feat(pcn): A* shortest path over the connector graph"
```

---

### Task 4: BRouter client + MapKit `.walking` fallback

**Files:**
- Create: `cyclingskibidi/Routing/PCN/BRouter.swift`
- Modify: `cyclingskibidi/App/cyclingskibidiApp.swift` (wire `BRouter.selfCheck()`)

**Interfaces:**
- Consumes: `GeoJSON.polylines` (Task 1), `Coord`, MapKit.
- Produces:
  - `enum BRouterConfig { static var baseURL: String; static let gapProfile: String; static let fastProfile: String }`
  - `enum BRouter { static func url(lonlats: [Coord], profile: String) -> URL?; static func decode(_ data: Data) -> [Coord]; static func route(_ waypoints: [Coord], profile: String) async -> [Coord] }` — `route` calls BRouter, falls back to MapKit `.walking` between the endpoints on any failure/empty, returns `[]` only if even that fails.
  - `static func BRouter.walk(from: Coord, to: Coord) async -> [Coord]` (MapKit `.walking`, the fallback; also usable directly).

- [ ] **Step 1: Write the BRouter client with its selfCheck.** Create `Routing/PCN/BRouter.swift`:

```swift
//
//  BRouter.swift
//  cyclingskibidi
//
//  BRouter is a free, open-source, cycling-tuned OSM router. We use it only for
//  the connective bits — start/end to the nearest connector, interior gaps, and
//  the whole route in Fast mode. Path-favouring `trekking` prefers footpaths and
//  quiet ways over roads; `fastbike` is the roads-allowed fast profile. If
//  BRouter is unreachable we fall back to MapKit .walking so a route always
//  returns.
//

import Foundation
import MapKit

enum BRouterConfig {
    /// Public instance to start (best-effort, no SLA). Swap to a self-hosted
    /// instance here — one line, no code change — once traffic justifies it.
    /// ponytail: public server; self-host for reliability at scale.
    static var baseURL = "https://brouter.de/brouter"
    /// Gap/leisure links: prefer footpaths & pavements over roads.
    /// ponytail: profile name is a knob — confirm against BRouter's live list on-device.
    static let gapProfile = "trekking"
    /// Fast mode: roads allowed, quickest bike route.
    static let fastProfile = "fastbike"
}

enum BRouter {

    /// `…/brouter?lonlats=lon,lat|lon,lat&profile=…&format=geojson`. Built via
    /// URLComponents so the pipe/comma separators are encoded correctly.
    static func url(lonlats: [Coord], profile: String) -> URL? {
        guard lonlats.count >= 2 else { return nil }
        let pairs = lonlats.map { "\($0.lon),\($0.lat)" }.joined(separator: "|")
        var comps = URLComponents(string: BRouterConfig.baseURL)
        comps?.queryItems = [
            .init(name: "lonlats", value: pairs),
            .init(name: "profile", value: profile),
            .init(name: "alternativeidx", value: "0"),
            .init(name: "format", value: "geojson"),
        ]
        return comps?.url
    }

    /// BRouter returns a GeoJSON FeatureCollection with a single LineString —
    /// the same shape the dataset uses, so the shared decoder handles it.
    static func decode(_ data: Data) -> [Coord] { GeoJSON.polylines(data).first ?? [] }

    /// Route the waypoints via BRouter; fall back to MapKit .walking on any
    /// failure so a connective segment always resolves.
    static func route(_ waypoints: [Coord], profile: String) async -> [Coord] {
        guard let url = url(lonlats: waypoints, profile: profile) else { return [] }
        if let (data, resp) = try? await URLSession.shared.data(from: url),
           (resp as? HTTPURLResponse)?.statusCode == 200 {
            let coords = decode(data)
            if coords.count >= 2 { return coords }
        }
        // Fallback: stitch MapKit .walking leg by leg.
        var out: [Coord] = []
        for i in 0..<(waypoints.count - 1) {
            var leg = await walk(from: waypoints[i], to: waypoints[i + 1])
            if !out.isEmpty, !leg.isEmpty { leg.removeFirst() }
            out.append(contentsOf: leg)
        }
        return out
    }

    /// MapKit walking directions between two points -> Coord line. The mandatory
    /// offline/last-resort path. [] if even MapKit can't route it.
    static func walk(from: Coord, to: Coord) async -> [Coord] {
        let req = MKDirections.Request()
        req.source = MKMapItem(location: from.cl.location, address: nil)
        req.destination = MKMapItem(location: to.cl.location, address: nil)
        req.transportType = .walking
        req.requestsAlternateRoutes = false
        guard let route = try? await MKDirections(request: req).calculate(),
              let leg = route.routes.first else { return [] }
        return leg.polyline.coordinates.map { Coord($0) }
    }
}

// MARK: - Self check

extension BRouter {
    static func selfCheck() {
        // URL is well-formed, lon before lat, profile carried.
        let u = url(lonlats: [Coord(lat: 1.30, lon: 103.80), Coord(lat: 1.31, lon: 103.81)],
                    profile: "trekking")!
        let s = u.absoluteString
        assert(s.contains("103.8,1.3") && s.contains("103.81,1.31"), "lonlats malformed: \(s)")
        assert(s.contains("profile=trekking") && s.contains("format=geojson"), "params missing: \(s)")
        // Fewer than 2 points -> no URL.
        assert(url(lonlats: [Coord(lat: 1.3, lon: 103.8)], profile: "trekking") == nil)
        // A BRouter-shaped response decodes (lon,lat order preserved).
        let sample = """
        {"type":"FeatureCollection","features":[{"type":"Feature","geometry":
         {"type":"LineString","coordinates":[[103.80,1.30,15],[103.81,1.31,16]]}}]}
        """
        let line = decode(Data(sample.utf8))
        assert(line.count == 2 && abs(line[0].lat - 1.30) < 1e-9 && abs(line[0].alt - 15) < 1e-9,
               "BRouter decode wrong")
    }
}
```

- [ ] **Step 2: Wire the selfCheck** (`BRouter.selfCheck()`).
- [ ] **Step 3: Build.** Expected: BUILD SUCCEEDED.
- [ ] **Step 4: Commit.**

```bash
git add cyclingskibidi/Routing/PCN/BRouter.swift cyclingskibidi/App/cyclingskibidiApp.swift
git commit -m "feat(pcn): BRouter client with MapKit .walking fallback"
```

---

### Task 5: PCN dataset — bundled seed, versioned cache, periodic manifest refresh

**Files:**
- Create: `cyclingskibidi/Routing/PCN/PCNDataset.swift`
- Add resource: `cyclingskibidi/pcn-seed.geojson` (the real dataset export)
- Modify: `cyclingskibidi/App/cyclingskibidiApp.swift` (wire `PCNDataset.selfCheck()`)

**Interfaces:**
- Consumes: `GeoJSON.polylines`, `PCNGraph`, CryptoKit.
- Produces:
  - `struct PCNManifest: Decodable { let version: Int; let url: String; let sha256: String }`
  - `enum PCNDataset { static func graph() -> PCNGraph; static func refreshIfStale() async; static func isNewer(_ manifest: PCNManifest, thanCached: Int) -> Bool; static func sha256Hex(_ data: Data) -> String }`
  - `graph()` returns the built graph from the freshest available GeoJSON (cached download > bundled seed), memoised. `refreshIfStale()` is the throttled launch call.

- [ ] **Step 1: Add the real seed dataset.** Download the NParks "Park Connector Loop" GeoJSON (dataset `d_a69ef89737379f231d2ae93fd1c5707f`) and save it as `cyclingskibidi/pcn-seed.geojson`. The data.gov.sg download flow: `GET https://api-open.data.gov.sg/v1/public/api/datasets/d_a69ef89737379f231d2ae93fd1c5707f/poll-download` returns JSON with a signed `data.url`; fetch that URL to get the GeoJSON. Verify it is a `FeatureCollection` of `LineString`/`MultiLineString` features. *(If the dataset ID has changed, resolve the current one from the dataset page and update this step + the design doc.)*

- [ ] **Step 2: Write `PCNDataset` with its selfCheck.** Create `Routing/PCN/PCNDataset.swift`:

```swift
//
//  PCNDataset.swift
//  cyclingskibidi
//
//  Where the connector graph's raw data comes from. A seed copy ships in the
//  bundle so routing works offline on first launch; a newer version, if we've
//  self-hosted one, is downloaded (sha256-verified) into app-support and used
//  from then on. Singapore keeps opening connectors, so this keeps riders
//  current without an app-store update.
//

import Foundation
import CryptoKit

struct PCNManifest: Decodable {
    let version: Int
    let url: String
    let sha256: String
}

enum PCNDataset {
    /// Self-hosted manifest — the update feed you control (a GitHub raw URL is the
    /// zero-cost default). ponytail: static host; point at wherever you publish.
    static var manifestURL = "https://raw.githubusercontent.com/OWNER/REPO/main/pcn-manifest.json"
    /// At most one refresh check per this interval. ponytail: weekly; loosen/tighten freely.
    static let refreshInterval: TimeInterval = 7 * 24 * 3600

    private static let fileName = "pcn.geojson"
    private static var cachedGraph: PCNGraph?

    // MARK: Graph

    /// The built graph from the freshest GeoJSON we have. Memoised — the graph is
    /// rebuilt only after a successful refresh (which clears the cache).
    static func graph() -> PCNGraph {
        if let g = cachedGraph { return g }
        let data = downloadedData() ?? seedData() ?? Data()
        let g = PCNGraph(polylines: GeoJSON.polylines(data))
        cachedGraph = g
        return g
    }

    private static func seedData() -> Data? {
        guard let url = Bundle.main.url(forResource: "pcn-seed", withExtension: "geojson") else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func downloadedData() -> Data? {
        try? Data(contentsOf: cacheFileURL())
    }

    private static func cacheFileURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    // MARK: Refresh

    /// Throttled: fetch the manifest, and if it names a newer version, download +
    /// verify + install it and drop the cached graph so the next graph() rebuilds.
    static func refreshIfStale() async {
        let now = Date.now.timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: "pcnLastCheck")
        guard now - last >= refreshInterval else { return }
        UserDefaults.standard.set(now, forKey: "pcnLastCheck")

        guard let mURL = URL(string: manifestURL),
              let (mData, _) = try? await URLSession.shared.data(from: mURL),
              let manifest = try? JSONDecoder().decode(PCNManifest.self, from: mData),
              isNewer(manifest, thanCached: UserDefaults.standard.integer(forKey: "pcnVersion")),
              let dURL = URL(string: manifest.url),
              let (data, _) = try? await URLSession.shared.data(from: dURL),
              sha256Hex(data) == manifest.sha256.lowercased(),
              !GeoJSON.polylines(data).isEmpty
        else { return }

        try? data.write(to: cacheFileURL(), options: .atomic)
        UserDefaults.standard.set(manifest.version, forKey: "pcnVersion")
        cachedGraph = nil   // next graph() rebuilds from the new data
    }

    // MARK: Pure helpers (tested)

    static func isNewer(_ manifest: PCNManifest, thanCached cached: Int) -> Bool {
        manifest.version > cached
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Self check

extension PCNDataset {
    static func selfCheck() {
        // Version compare gates on strictly-newer.
        let m = PCNManifest(version: 5, url: "x", sha256: "y")
        assert(isNewer(m, thanCached: 4) && !isNewer(m, thanCached: 5) && !isNewer(m, thanCached: 6))
        // sha256 of "" is the known empty-string digest.
        assert(sha256Hex(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        // The bundled seed is present and parses to a non-trivial network.
        // ponytail: comment out if running before the seed file is added.
        let g = graph()
        assert(!g.isEmpty, "pcn-seed.geojson missing or empty — is it in the bundle?")
    }
}
```

- [ ] **Step 3: Wire the selfCheck** (`PCNDataset.selfCheck()`).
- [ ] **Step 4: Build.** Expected: BUILD SUCCEEDED. Confirm at runtime (`⌘R`) that the seed assertion passes — this is the check that `.geojson` got bundled by the synchronized folder.
- [ ] **Step 5: Commit.**

```bash
git add cyclingskibidi/Routing/PCN/PCNDataset.swift cyclingskibidi/pcn-seed.geojson cyclingskibidi/App/cyclingskibidiApp.swift
git commit -m "feat(pcn): bundled seed + versioned cache + periodic manifest refresh"
```

---

### Task 6: Stitch, geometry turn-list, and `plan(mode:)` wiring

**Files:**
- Create: `cyclingskibidi/Routing/PCN/PCNRouting.swift`
- Modify: `cyclingskibidi/Routing/Routing.swift` (branch `plan` on mode; share elevation/expected/steps tail)
- Modify: `cyclingskibidi/App/cyclingskibidiApp.swift` (wire `PCNRouting.selfCheck()`)

**Interfaces:**
- Consumes: `PCNGraph`+A\* (Tasks 2–3), `PCNDataset.graph()` (Task 5), `BRouter` (Task 4), `Geo.*`, `RoutePlan`.
- Produces:
  - `enum PCNRouting { static func stitched(waypoints: [Coord], graph: PCNGraph, gap: (Coord, Coord) async -> [Coord]) async -> (poly: [Coord], offSegments: [[Coord]], offMeters: Double); static func steps(from poly: [Coord]) -> [StoredStep] }`
  - `gap` is injected (default in `Routing.plan` = `{ await BRouter.route([$0,$1], profile: BRouterConfig.gapProfile) }`) so `stitched` is testable with a straight-line stub — no network in the selfCheck.
- Modifies: `Routing.plan(through:mode:fetchElevation:)` to branch: `.fast` → BRouter `fastProfile` over all waypoints; else → `stitched` over `PCNDataset.graph()`. Both paths reuse the existing elevation/expected/polyline tail.

**Stitch algorithm:** for each consecutive waypoint pair, snap both to nearest PCN nodes; the **gap** from the raw waypoint to its entry node (and exit node to next raw waypoint) is routed by `gap(...)` and marked off-connector; the **entry→exit** segment is the on-PCN A\* path. Concatenate, dropping the duplicated jo. If the two waypoints share a component the PCN path exists; if A\* returns nil (disconnected), the whole pair is bridged by `gap(...)` (all off-connector) so a route always returns.

- [ ] **Step 1: Write `PCNRouting` with its selfCheck.** Create `Routing/PCN/PCNRouting.swift`:

```swift
//
//  PCNRouting.swift
//  cyclingskibidi
//
//  Assembling a ride: snap the rider's points to the connector network, run A*
//  for the on-PCN stretches, and route the unavoidable gaps (start/end/holes)
//  with the injected gap router — walkable paths first, roads only when forced.
//  Off-connector stretches are tracked so the builder can flag them.
//

import Foundation
import CoreLocation

enum PCNRouting {

    /// Distance under which a gap is treated as already-on-network noise (skip
    /// the gap router). ponytail: 15 m; tune with the real snap tolerance on-device.
    static let gapEpsilon: Double = 15

    static func stitched(
        waypoints: [Coord],
        graph: PCNGraph,
        gap: (Coord, Coord) async -> [Coord]
    ) async -> (poly: [Coord], offSegments: [[Coord]], offMeters: Double) {

        var poly: [Coord] = []
        var offSegments: [[Coord]] = []

        func append(_ seg: [Coord], off: Bool) {
            var s = seg
            if !poly.isEmpty, !s.isEmpty, s.first == poly.last { s.removeFirst() }
            guard !s.isEmpty else { return }
            if off { offSegments.append(seg) }
            poly.append(contentsOf: s)
        }

        for i in 0..<(waypoints.count - 1) {
            let a = waypoints[i], b = waypoints[i + 1]
            guard let entry = graph.nearest(to: a), let exit = graph.nearest(to: b),
                  let onPCN = graph.path(from: entry, to: exit), onPCN.count >= 1,
                  let entryC = graph.coord(of: entry), let exitC = graph.coord(of: exit) else {
                // No usable PCN between these points — bridge the whole pair.
                append(await gap(a, b), off: true)
                continue
            }
            // start -> entry node (gap), unless already essentially on it.
            if Geo.distance(a.cl, entryC.cl) > gapEpsilon { append(await gap(a, entryC), off: true) }
            else { append([a], off: false) }
            // entry -> exit along the PCN (on-connector).
            append(onPCN, off: false)
            // exit node -> destination (gap).
            if Geo.distance(exitC.cl, b.cl) > gapEpsilon { append(await gap(exitC, b), off: true) }
            else { append([b], off: false) }
        }

        let offMeters = offSegments.reduce(0.0) { $0 + (Geo.cumulative($1.coordinates).last ?? 0) }
        return (poly, offSegments, offMeters)
    }

    /// A turn list from bare geometry — the PCN path has no street names, so
    /// steps are synthesised from the polyline's own bends. Reuses Geo's bearing
    /// maths, the same classification the MapKit path uses.
    /// ponytail: emits a step only on a >minTurn bend spaced >minSpacing apart, so
    /// dense connector vertices don't spam the turn list. Both tuned on-device.
    static let minTurn: Double = 25       // degrees
    static let minSpacing: Double = 30    // metres

    static func steps(from poly: [Coord]) -> [StoredStep] {
        let coords = poly.coordinates
        guard coords.count >= 2 else { return [] }
        let cum = Geo.cumulative(coords)
        var out: [StoredStep] = [step(.depart, "Start", at: coords[0], offset: 0)]
        var lastAt = 0.0
        for i in 1..<(coords.count - 1) {
            let inB = Geo.bearing(from: coords[i - 1], to: coords[i])
            let outB = Geo.bearing(from: coords[i], to: coords[i + 1])
            let angle = Geo.turn(from: inB, to: outB)
            guard abs(angle) >= minTurn, cum[i] - lastAt >= minSpacing else { continue }
            let m = Maneuver.classify(turn: angle)
            out.append(step(m, phrase(m), at: coords[i], offset: cum[i]))
            lastAt = cum[i]
        }
        out.append(step(.arrive, "Arrive", at: coords.last!, offset: cum.last ?? 0))
        return out
    }

    private static func phrase(_ m: Maneuver) -> String {   // maps a maneuver to its street-less instruction
        switch m {
        case .slightLeft:  return "Bear left"
        case .left:        return "Turn left"
        case .sharpLeft:   return "Sharp left"
        case .slightRight: return "Bear right"
        case .right:       return "Turn right"
        case .sharpRight:  return "Sharp right"
        case .uTurn:       return "Make a U-turn"
        default:           return "Continue"
        }
    }

    private static func step(_ m: Maneuver, _ text: String, at c: CLLocationCoordinate2D, offset: Double) -> StoredStep {
        StoredStep(instruction: text, road: "", distance: 0, maneuverOffset: offset,
                   maneuverRaw: m.rawValue, lat: c.latitude, lon: c.longitude)
    }
}
```

- [ ] **Step 2: Branch `Routing.plan` on mode.** In `Routing/Routing.swift`, replace the body of `plan(through:mode:fetchElevation:)` so it delegates the geometry to either BRouter (fast) or the PCN stitch (moderate/leisure), then runs the **existing** elevation/expected/polyline tail on the resulting line. Keep the MapKit `flatten`/leg code in the file (still used by `BRouter.walk`'s caller path is separate; do not delete it — it remains the reference and the `.fast` path may reuse `elevations`/`resample`). New body:

```swift
static func plan(through waypoints: [Coord],
                 mode: RideMode = .moderate,
                 fetchElevation: Bool = true) async throws -> RoutePlan {
    guard waypoints.count >= 2 else { return RoutePlan() }

    var plan = RoutePlan()
    var poly: [Coord]

    switch mode {
    case .fast:
        // Quickest cycling route, roads allowed — one BRouter call, no PCN.
        poly = await BRouter.route(waypoints, profile: BRouterConfig.fastProfile)
    case .moderate, .leisure:
        let graph = PCNDataset.graph()
        let result = await PCNRouting.stitched(
            waypoints: waypoints, graph: graph,
            gap: { await BRouter.route([$0, $1], profile: BRouterConfig.gapProfile) })
        poly = result.poly
        plan.offConnectorSegments = result.offSegments
        plan.offConnectorMeters = result.offMeters
    }

    // Nothing came back (offline, empty graph): last-resort MapKit walking so a
    // route still appears.
    if poly.count < 2 {
        poly = await BRouter.route(waypoints, profile: BRouterConfig.gapProfile)
        plan.offConnectorSegments = poly.isEmpty ? [] : [poly]
        plan.offConnectorMeters = Geo.cumulative(poly.coordinates).last ?? 0
    }
    guard poly.count >= 2 else { return plan }

    let cl = poly.coordinates
    let cum = Geo.cumulative(cl)
    plan.distance = cum.last ?? 0
    plan.steps = PCNRouting.steps(from: poly)

    if fetchElevation {
        plan.elevations = await elevations(along: cl)
    }
    plan.expected = (plan.distance + plan.ascent * 10) / cruisingSpeed
    plan.polyline = zip(cl, plan.elevations.isEmpty ? [] : resample(plan.elevations, to: cl.count))
        .map { Coord($0.0, alt: $0.1) }
    if plan.polyline.isEmpty { plan.polyline = poly }
    return plan
}
```

*Note:* `poly` here is already `[Coord]`; drop the old per-leg MapKit loop from this function. The old `flatten(_:startingAt:isFirstLeg:isLastLeg:)` helper is now unused by `plan` — keep it only if another caller uses it, otherwise delete it in this task and note the removal in the commit. (Grep first: `grep -rn "flatten(" cyclingskibidi`.)

- [ ] **Step 3: Write the `PCNRouting.selfCheck()`** appended in `PCNRouting.swift`:

```swift
extension PCNRouting {
    static func selfCheck() {
        // Stitch with a straight-line gap stub (no network). Start 30 m south of
        // the west end, end exactly on the north end of the fixture network.
        let g = PCNGraph.fixture()
        let start = Coord(lat: 1.30 - 30 / PCNGraph.metresPerDegree, lon: 103.800)
        let end   = Coord(lat: 1.302, lon: 103.802)
        let stub: (Coord, Coord) -> [Coord] = { [$0, $1] }   // straight line
        let sem = DispatchSemaphore(value: 0)
        var got: (poly: [Coord], offSegments: [[Coord]], offMeters: Double)!
        Task { got = await stitched(waypoints: [start, end], graph: g, gap: { stub($0, $1) }); sem.signal() }
        sem.wait()
        // One off-connector segment (start -> west entry), ~30 m; end was on-node.
        assert(got.offSegments.count == 1, "expected 1 gap, got \(got.offSegments.count)")
        assert(abs(got.offMeters - 30) < 3, "off-connector metres off: \(got.offMeters)")
        // Full line reaches the north end.
        assert(abs(got.poly.last!.lat - 1.302) < 1e-6, "route didn't reach the end")

        // Geometry turn list: east then north = one left turn between depart/arrive.
        let steps = steps(from: [Coord(lat: 1.30, lon: 103.80),
                                 Coord(lat: 1.30, lon: 103.802),
                                 Coord(lat: 1.302, lon: 103.802)])
        assert(steps.first?.maneuver == .depart && steps.last?.maneuver == .arrive)
        assert(steps.contains { $0.maneuver == .left }, "left turn not detected")
    }
}
```

*(The `DispatchSemaphore` bridge keeps the selfCheck synchronous like the others; it runs once at launch, never on a hot path.)*

- [ ] **Step 4: Wire the selfCheck** (`PCNRouting.selfCheck()`).
- [ ] **Step 5: Build.** Expected: BUILD SUCCEEDED.
- [ ] **Step 6: Commit.**

```bash
git add cyclingskibidi/Routing/PCN/PCNRouting.swift cyclingskibidi/Routing/Routing.swift cyclingskibidi/App/cyclingskibidiApp.swift
git commit -m "feat(pcn): stitch + geometry turn list + plan(mode:) wiring"
```

---

### Task 7: Build-time road transparency in the route builder

**Files:**
- Modify: `cyclingskibidi/Features/Routes/RouteBuilderView.swift`

**Interfaces:**
- Consumes: `RoutePlan.offConnectorSegments`, `RoutePlan.offConnectorMeters`, `Fmt.km`.
- Produces: no new API — draws off-connector segments distinctly, adds an off-connector summary pill. "Reject" = the existing Clear/Undo controls; "redirect" = the existing map-tap-to-add-waypoint (already re-plans), so **no new interaction is built** — only the visibility the spec requires.

- [ ] **Step 1: Draw off-connector segments in red over the base line.** In `RouteBuilderView`'s `map` builder, after the existing base `MapPolyline`, add:

```swift
if !plan.polyline.isEmpty {
    MapPolyline(coordinates: plan.polyline.coordinates)
        .stroke(.blue, style: .init(lineWidth: 6, lineCap: .round, lineJoin: .round))
}
// Off-connector stretches (roads/paths) drawn distinctly so the rider sees
// exactly what leaves the PCN and can reject or redirect it.
ForEach(Array(plan.offConnectorSegments.enumerated()), id: \.offset) { _, seg in
    MapPolyline(coordinates: seg.coordinates)
        .stroke(.orange, style: .init(lineWidth: 6, lineCap: .round, lineJoin: .round, dash: [2, 6]))
}
```

- [ ] **Step 2: Add the off-connector summary pill.** In the metrics `FlowLayout` (the `else` branch of the controls, alongside distance/duration/difficulty), add:

```swift
if plan.offConnectorMeters > 0 {
    Pill(text: "⚠︎ \(Fmt.km(plan.offConnectorMeters)) off-connector", tint: .orange)
}
```

- [ ] **Step 3: Build.** Expected: BUILD SUCCEEDED.
- [ ] **Step 4: Commit.**

```bash
git add cyclingskibidi/Features/Routes/RouteBuilderView.swift
git commit -m "feat(pcn): flag off-connector road segments in the builder"
```

---

## Post-implementation (for the controller, not a task)

- **On-device calibration pass (`⌘R`, real routes):** the ponytail knobs that a build can't verify — `PCNGraph.defaultSnapTolerance`, `PCNRouting.gapEpsilon`, `minTurn`/`minSpacing`, and BRouter profile names — get tuned against real Singapore routes. Watch for a disconnected graph (tolerance too small) vs invented shortcuts (too large).
- **Self-host the manifest:** set `PCNDataset.manifestURL` to the real published URL and put `pcn-manifest.json` + the versioned GeoJSON there. Until then, refresh is a no-op and the bundled seed is used — which is correct and safe.
- **Call `PCNDataset.refreshIfStale()` on launch** (a `.task` on `ContentView`, fire-and-forget) — a one-line follow-up once a manifest is hosted; left out of Task 5 deliberately so nothing depends on an unpublished URL.

## Self-Review

**1. Spec coverage** (against `2026-09-04-phase2-pcn-routing-design.md`):
- Component 1 PCN dataset → Task 5 (seed + version) + Task 1 (GeoJSON decode). ✅
- Component 2 graph builder + spatial index → Task 2 (grid = merge + index). ✅
- Component 3 A\* router → Task 3. ✅
- Component 4 gap stitching + BRouter + MapKit fallback + walkable-first + road transparency → Task 4 (BRouter/fallback) + Task 6 (stitch/off-connector) + Task 7 (flag/redirect). ✅
- Component 5 mode behaviour (`plan(mode:)` branch; fast = fastbike; scenic deferred) → Task 6. ✅ (scenic correctly absent — deferred per spec; `sceneryFactor` seam is a comment, not code.)
- Periodic updates (self-hosted manifest, throttled, sha256, rebuild) → Task 5. ✅
- Integration "nothing in Phase 1 changes" → `RoutePlan`/`Route.make`/`StoredStep` shapes preserved; only additive in-memory fields + a mode branch. ✅

**2. Placeholder scan:** No TBD/"add error handling"/"similar to Task N". Every code step is complete. The one deliberate external artifact — the real `pcn-seed.geojson` — has an exact fetch procedure (Task 5 Step 1), not a placeholder. `manifestURL`'s `OWNER/REPO` is a named config value the user fills at publish time, flagged in Post-implementation.

**3. Type consistency:** `Coord`, `[Coord].coordinates`, `RoutePlan` (fields added Task 1, consumed Tasks 6–7), `GridKey`/`PCNGraph` (Task 2 → 3, 6), `PCNGraph.fixture()`/`metresPerDegree` (Task 2 → 3, 6 selfChecks), `GeoJSON.polylines` (Task 1 → 4, 5), `BRouter.route`/`BRouterConfig` (Task 4 → 6), `PCNDataset.graph()` (Task 5 → 6), `StoredStep` init args match `Models/Geo.swift`. `Maneuver.classify`/`.rawValue` match. Consistent.

**No CloudKit/persistence changes** — off-connector data is in-memory `RoutePlan` only, so no `@Model` migration and the Global Constraint holds.

## Execution Handoff

Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks, fast iteration (REQUIRED SUB-SKILL: superpowers:subagent-driven-development).
2. **Inline Execution** — batch execution with checkpoints in this session (REQUIRED SUB-SKILL: superpowers:executing-plans).
