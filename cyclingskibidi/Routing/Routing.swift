//
//  Routing.swift
//  cyclingskibidi
//
//  Offline routing through the rider's waypoints on the bundled PCN graph, plus
//  the elevation profile (bundled grid) that feeds the climb figures and the
//  graph on the route sheet.
//

import Foundation
import MapKit

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
    /// Where a straight fallback leg crosses an expressway or another no-bike way (spec 6a).
    var noBikeCrossings: [Coord] = []

    var ascent: Double { Geo.climb(elevations).up }
    var descent: Double { Geo.climb(elevations).down }
}

enum Routing {

    /// Expected ride duration: distance plus a climb penalty (10 m of extra
    /// distance per metre of ascent), at the mode's planning speed. The
    /// walking engine's own expectedTravelTime is a walking time and would
    /// triple every estimate, hence a speed-based estimate of our own.
    /// ponytail: one speed per mode for every rider. Learn it per rider from
    /// their own finished rides once there are enough of them.
    static func duration(distance: Double, ascent: Double, mode: RideMode) -> Double {
        (distance + ascent * 10) / (mode.planningSpeedKmh * 1000 / 3600)
    }

    /// Assemble a ride through the rider's waypoints, entirely offline.
    ///
    /// Fast routes on the bundled road network end to end, roads allowed.
    /// Moderate/leisure stitch on-PCN A* stretches with road-network legs (paths
    /// and quiet streets first) at the start/end/holes and round closures — see
    /// `PCNRouting.stitched`. A leg the road network can't make is a straight
    /// off-connector line, so a route always appears.
    /// Bundled closures and every "Path closed" the rider has marked are always
    /// avoided; `closures` adds any not yet saved (a mark made a moment ago).
    static func plan(through waypoints: [Coord],
                     mode: RideMode = .moderate,
                     closures: [NoGoCircle] = [],
                     context: Set<RideContext> = [],
                     start: Date = .now,
                     noBikeLines: [NoBikeLine] = NoBike.lines) async throws -> RoutePlan {
        guard waypoints.count >= 2 else { return RoutePlan() }

        var plan = RoutePlan()
        var (closed, walk) = Closures.activeCircles()
        closed += Closures.marked.filter { $0.isActive(on: Closures.now) }.flatMap(\.noGoCircles) + closures
        let roads = await RoadNetwork.graph()
        var poly: [Coord]
        switch mode {
        case .fast:
            let (line, off) = await Task.detached { [closed, walk] in
                var line: [Coord] = [], off: [[Coord]] = []
                for (a, b) in zip(waypoints, waypoints.dropFirst()) {
                    var leg = roads?.route(a, b, profile: .fast, closed: closed, walk: walk) ?? []
                    if leg.count < 2 { leg = [a, b]; off.append(leg) }
                    if !line.isEmpty { leg.removeFirst() }
                    line += leg
                }
                return (line, off)
            }.value
            poly = line
            plan.offConnectorSegments = off
            plan.offConnectorMeters = off.reduce(0) { $0 + (Geo.cumulative($1.coordinates).last ?? 0) }
        case .moderate, .leisure:
            let base = await PCNDataset.graph()
            // Penalising touches every node; keep it off the main actor like A*.
            // "How I'm riding today" steers round crowded / dismount stretches; Fast ignores it.
            let (graph, fallback, avoid) = await Task.detached { [closed, walk] in
                let avoid = Kit.avoidCircles(for: context, at: start)
                return (base.penalised(closed: closed, walk: walk, avoid: avoid),
                        avoid.isEmpty ? nil : base.penalised(closed: closed, walk: walk), avoid)
            }.value
            let result = await PCNRouting.stitched(
                waypoints: waypoints, graph: graph, base: base, fallback: fallback, closed: closed, avoid: avoid,
                gap: { [closed, walk] a, b in roads?.route(a, b, profile: .quiet, closed: closed, walk: walk) ?? [a, b] })
            poly = result.poly
            plan.offConnectorSegments = result.offSegments
            plan.offConnectorMeters = result.offMeters
        }

        // Empty graph: straight legs between the pins, all off-connector, so a route still appears.
        if poly.count < 2 {
            poly = waypoints
            plan.offConnectorSegments = zip(poly, poly.dropFirst()).map { [$0, $1] }   // straight legs, tested below
            plan.offConnectorMeters = Geo.cumulative(poly.coordinates).last ?? 0
        }
        plan.noBikeCrossings = NoBike.crossings(inOffSegments: plan.offConnectorSegments, lines: noBikeLines)

        let cl = poly.coordinates
        plan.distance = Geo.cumulative(cl).last ?? 0
        let pcn = mode == .fast ? nil : await PCNDataset.graph()
        plan.steps = PCNRouting.steps(from: poly, pcn: pcn, roads: roads)
        plan.elevations = Elevation.profile(along: cl)
        plan.expected = duration(distance: plan.distance, ascent: plan.ascent, mode: mode)
        plan.polyline = zip(cl, plan.elevations.isEmpty ? [] : resample(plan.elevations, to: cl.count))
            .map { Coord($0.0, alt: $0.1) }
        if plan.polyline.isEmpty { plan.polyline = poly }
        return plan
    }

    /// Stretch a short profile back over every vertex, linearly.
    static func resample(_ values: [Double], to count: Int) -> [Double] {
        guard values.count > 1, count > 1 else { return Array(repeating: values.first ?? 0, count: count) }
        return (0..<count).map { i in
            let x = Double(i) * Double(values.count - 1) / Double(count - 1)
            let lo = Int(x.rounded(.down)), hi = min(lo + 1, values.count - 1)
            return values[lo] + (values[hi] - values[lo]) * (x - Double(lo))
        }
    }
}

// MARK: - Small helpers

extension CLLocationCoordinate2D {
    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
}

extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var out = [CLLocationCoordinate2D](repeating: .init(), count: pointCount)
        getCoordinates(&out, range: NSRange(location: 0, length: pointCount))
        return out
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

extension Route {
    /// Build a saved-ready Route from a plan. Shared by the map builder and the
    /// import paths so the two never drift on which fields get written.
    static func make(name: String, mode: RideMode, waypoints: [Coord], plan: RoutePlan, sights: [Sight] = []) -> Route {
        let route = Route(name: name)
        route.mode = mode
        route.waypointData = Blob.encode(waypoints)
        route.apply(plan)
        route.sightData = sights.isEmpty ? nil : Blob.encode(sights)
        return route
    }

    /// Write a plan's line, turns and figures onto this route. The climb data
    /// always follows the new line, never the old one.
    func apply(_ plan: RoutePlan) {
        polylineData = Blob.encode(plan.polyline)
        stepData = Blob.encode(plan.steps)
        distanceMeters = plan.distance
        elevationData = Blob.encode(plan.elevations)
        ascentMeters = plan.ascent
        descentMeters = plan.descent
        expectedSeconds = Routing.duration(distance: distanceMeters, ascent: ascentMeters, mode: mode)
        difficulty = .rated(distanceMeters: distanceMeters, ascentMeters: ascentMeters)
        noBikeData = plan.noBikeCrossings.isEmpty ? nil : Blob.encode(plan.noBikeCrossings)
    }

    /// The mode's current-speed estimate for this route, recomputed from its
    /// distance/ascent rather than read from the stored `expectedSeconds` —
    /// so a route saved under an old speed table never shows a stale ETA.
    /// `expectedSeconds` itself stays around for compatibility/new saves.
    var currentExpectedSeconds: Double {
        Routing.duration(distance: distanceMeters, ascent: ascentMeters, mode: mode)
    }
}

extension Routing {
    static func selfCheck() {
        let sight = Sight(name: "Cafe", category: "", lat: 1.3, lon: 103.8, offsetAlong: 120)
        let route = Route.make(name: "Test", mode: .leisure,
                               waypoints: [Coord(lat: 1.3, lon: 103.8)],
                               plan: RoutePlan(), sights: [sight])
        assert(route.sights.count == 1, "a route built for saving should retain its discovered sights")
        assert(route.sights.first?.name == "Cafe", "the retained sight should round-trip its data")

        // Re-planning a saved route replaces its climb data with the new line's.
        var hilly = RoutePlan(); hilly.distance = 1000; hilly.elevations = [0, 20, 0]
        let saved = Route.make(name: "Hill", mode: .moderate, waypoints: [], plan: hilly)
        var flat = RoutePlan(); flat.distance = 1200; flat.polyline = [Coord(lat: 1.3, lon: 103.8)]; flat.elevations = [5, 15, 5]
        saved.apply(flat)
        assert(saved.distanceMeters == 1200 && saved.polyline.count == 1, "re-plan must replace the line")
        assert(saved.ascentMeters == 10 && saved.elevations == [5, 15, 5], "re-plan kept the old climb chart: \(saved.elevations)")

        // A flat 1 km route (no ascent) at each mode's planning speed, in whole
        // seconds so the maths stays exact: 20 km/h, 18 km/h, 12.5 km/h.
        assert(duration(distance: 1000, ascent: 0, mode: .fast) == 180,
               "fast should plan 1 km flat at exactly 20 km/h")
        assert(duration(distance: 1000, ascent: 0, mode: .moderate) == 200,
               "moderate should plan 1 km flat at exactly 18 km/h")
        assert(duration(distance: 1000, ascent: 0, mode: .leisure) == 288,
               "leisure should plan 1 km flat at exactly 12.5 km/h, the midpoint of 10-15 km/h")

        // A route saved under an old speed table must not show its stale stored
        // estimate: the mode's current speed always wins for display/filtering.
        let legacy = Route(name: "Legacy Leisure")
        legacy.mode = .leisure
        legacy.distanceMeters = 1000
        legacy.ascentMeters = 0
        legacy.expectedSeconds = 999 // deliberately wrong, as if saved under an old formula
        assert(legacy.currentExpectedSeconds == 288,
               "a stored route should recompute its estimate at the mode's current speed, not read the stale stored value")
        assert(legacy.expectedSeconds == 999,
               "the persisted expectedSeconds should stay untouched for compatibility")
    }
}

extension Routing {
    /// Plan-level no-bike checks (spec 6a), async because planning is.
    static func selfCheckNoBike() async {
        // Pins out in the strait: no road within reach, so the leg is straight, across a toy expressway.
        let toy = [NoBikeLine(kind: "expressway", name: "Toy", pts: [Coord(lat: 1.19, lon: 103.905), Coord(lat: 1.21, lon: 103.905)])]
        let sea = try? await plan(through: [Coord(lat: 1.20, lon: 103.90), Coord(lat: 1.20, lon: 103.91)], mode: .fast, noBikeLines: toy)
        assert(sea?.noBikeCrossings.count == 1, "a straight fallback leg across a no-bike line must be flagged: \(sea?.noBikeCrossings ?? [])")

        // The road network crosses the PIE at Toa Payoh on a bridge or underpass: never flagged.
        let real = try? await plan(through: [Coord(lat: 1.3283, lon: 103.8466), Coord(lat: 1.3318, lon: 103.8466)], mode: .fast)
        assert(real?.noBikeCrossings.isEmpty == true && (real?.polyline.count ?? 0) > 2,
               "a real network route across the PIE must not be flagged: \(real?.noBikeCrossings ?? [])")

        // Saved routes: none saved = none shown; crossings round-trip.
        assert(Route(name: "Old").noBikeCrossings.isEmpty, "a route saved before no-bike data must show no warning")
        var p = RoutePlan(); p.noBikeCrossings = [Coord(lat: 1.3, lon: 103.8)]
        assert(Route.make(name: "X", mode: .moderate, waypoints: [], plan: p).noBikeCrossings.count == 1)
    }
}

