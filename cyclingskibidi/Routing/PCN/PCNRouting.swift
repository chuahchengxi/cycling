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
        guard waypoints.count >= 2 else { return ([], [], 0) }

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
    }
}
