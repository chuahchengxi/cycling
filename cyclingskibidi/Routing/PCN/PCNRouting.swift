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
    nonisolated static let gapEpsilon: Double = 15

    /// `graph` may carry closure penalties (see `PCNGraph.penalised`); `base` is the
    /// same network without them (nil = `graph`). Per waypoint pair the penalised path
    /// is used when it avoids every `closed` circle within `maxDetourRatio` of the
    /// open path; otherwise the open path is ridden and each run of closed vertices
    /// becomes an off-connector `gap` leg round it. Runs off the main actor.
    @concurrent nonisolated static func stitched(
        waypoints: [Coord],
        graph: PCNGraph,
        base: PCNGraph? = nil,
        closed: [NoGoCircle] = [],
        gap: @Sendable (Coord, Coord) async -> [Coord]
    ) async -> (poly: [Coord], offSegments: [[Coord]], offMeters: Double) {
        guard waypoints.count >= 2 else { return ([], [], 0) }
        let base = base ?? graph
        func isClosed(_ c: Coord) -> Bool { closed.contains { Geo.distance(c.cl, $0.coord.cl) <= $0.radiusMeters } }

        var poly: [Coord] = []
        var offSegments: [[Coord]] = []

        func append(_ seg: [Coord], off: Bool) {
            var s = seg
            // Weld the seam: a real gap router won't echo the requested endpoint
            // to the bit, so match on proximity rather than exact equality.
            // ponytail: 1 m weld tolerance; a hair above GPS jitter, well under a segment.
            if let first = s.first, let last = poly.last, Geo.distance(first.cl, last.cl) < 1 { s.removeFirst() }
            guard !s.isEmpty else { return }
            if off { offSegments.append(seg) }
            poly.append(contentsOf: s)
        }

        for i in 0..<(waypoints.count - 1) {
            let a = waypoints[i], b = waypoints[i + 1]
            guard let entry = base.nearest(to: a), let exit = base.nearest(to: b),
                  let open = base.path(from: entry, to: exit), open.count >= 1,
                  let entryC = base.coord(of: entry), let exitC = base.coord(of: exit) else {
                // No usable PCN between these points — bridge the whole pair.
                append(await gap(a, b), off: true)
                continue
            }
            var onPCN = open
            if !closed.isEmpty, let avoid = graph.path(from: entry, to: exit),
               !avoid.contains(where: isClosed),
               base.pathLength(avoid) <= PCNGraph.maxDetourRatio * base.pathLength(open) {
                onPCN = avoid
            }
            // start -> entry node (gap), unless already essentially on it.
            if Geo.distance(a.cl, entryC.cl) > gapEpsilon { append(await gap(a, entryC), off: true) }
            else { append([a], off: false) }
            // entry -> exit along the PCN, each closed run swapped for a gap leg round it.
            var k = 0
            while k < onPCN.count {
                guard isClosed(onPCN[k]) else {
                    var j = k
                    while j < onPCN.count, !isClosed(onPCN[j]) { j += 1 }
                    append(Array(onPCN[k..<j]), off: false); k = j; continue
                }
                var j = k
                while j < onPCN.count, isClosed(onPCN[j]) { j += 1 }
                let from = poly.last ?? a, to = j < onPCN.count ? onPCN[j] : b
                append(await gap(from, to), off: true); k = j
            }
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
            guard let inB = Geo.exitBearing(Array(coords[...i])),
                  let outB = Geo.entryBearing(Array(coords[i...])) else { continue }
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

// MARK: - Self check

extension PCNRouting {
    static func selfCheck() async {
        // Stitch with a straight-line gap stub (no network). Start 30 m south of
        // the fixture's west end, end exactly on the north node.
        let g = PCNGraph.fixture()
        let start = Coord(lat: 1.30 - 30 / PCNGraph.metresPerDegree, lon: 103.800)
        let end   = Coord(lat: 1.302, lon: 103.802)
        let got = await stitched(waypoints: [start, end], graph: g, gap: { [$0, $1] })
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

        // Closures.
        let west = Coord(lat: 1.300, lon: 103.800), corner = Coord(lat: 1.300, lon: 103.802), north = Coord(lat: 1.302, lon: 103.802)
        let shut = NoGoCircle(coord: corner, radiusMeters: 20)
        func inside(_ c: Coord) -> Bool { Geo.distance(c.cl, shut.coord.cl) <= 20 }
        // 1. Only path is closed: still arrives, closed vertex not ridden, one off-connector gap leg.
        let g1 = PCNGraph.fixture()
        let r1 = await stitched(waypoints: [west, north], graph: g1.penalised(closed: [shut], walk: []), base: g1,
                                closed: [shut], gap: { [$0, $1] })
        assert(abs(r1.poly.last!.lat - 1.302) < 1e-6, "closure must not stop the route")
        assert(!r1.poly.contains { $0 == corner }, "closed vertex must not be ridden")
        assert(r1.offSegments.count == 1, "expected one gap leg round the closure")
        // 2. Short open detour (square, other side ~444 m vs 444 m): detour wins, no gap leg.
        let other = Coord(lat: 1.302, lon: 103.800)
        let sq = PCNGraph(polylines: [[west, corner, north], [west, other, north]])
        let r2 = await stitched(waypoints: [west, north], graph: sq.penalised(closed: [shut], walk: []), base: sq,
                                closed: [shut], gap: { [$0, $1] })
        assert(r2.offSegments.isEmpty && !r2.poly.contains(where: inside), "should take the open side")
        // 3. Detour far longer than +30%: direct route with a gap leg, not the detour.
        let far = [west, Coord(lat: 1.296, lon: 103.800), Coord(lat: 1.296, lon: 103.806), Coord(lat: 1.302, lon: 103.806), north]
        let lg = PCNGraph(polylines: [[west, corner, north], far])
        let r3 = await stitched(waypoints: [west, north], graph: lg.penalised(closed: [shut], walk: []), base: lg,
                                closed: [shut], gap: { [$0, $1] })
        assert(r3.offSegments.count == 1 && r3.poly.count <= 4, "long detour must lose to a dashed gap leg")
        // 4. No-cycling zone on the only path: ridden (walked), no gap leg.
        let r4 = await stitched(waypoints: [west, north], graph: g1.penalised(closed: [], walk: [shut]), base: g1,
                                closed: [], gap: { [$0, $1] })
        assert(r4.poly.contains { $0 == corner } && r4.offSegments.isEmpty, "walk zones are passed through")
    }
}
