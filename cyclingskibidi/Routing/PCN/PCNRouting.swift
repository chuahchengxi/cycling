//
//  PCNRouting.swift
//  cyclingskibidi
//
//  Assembling a ride: snap the rider's points to the connector network, run A*
//  for the on-PCN stretches, and route the unavoidable gaps (start/end/holes)
//  with the injected gap leg (a straight off-connector line in the app).
//  Off-connector stretches are tracked so the builder can flag them.
//

import Foundation
import CoreLocation

enum PCNRouting {

    /// Distance under which a gap is treated as already-on-network noise (skip
    /// the gap router). ponytail: 15 m; tune with the real snap tolerance on-device.
    nonisolated static let gapEpsilon: Double = 15

    /// `graph` may carry closure penalties (see `PCNGraph.penalised`); `base` is the
    /// same network without them (nil = `graph`); `fallbacks` are tried in order when `graph`
    /// gives nothing usable (a half-strength scenic graph, then closures only, ...). Per waypoint pair the penalised path
    /// is used when it avoids every `closed` circle within `maxDetourRatio` of the
    /// open path; otherwise the open path is ridden and each run of closed vertices
    /// becomes an off-connector `gap` leg round it. Runs off the main actor.
    @concurrent nonisolated static func stitched(
        waypoints: [Coord],
        graph: PCNGraph,
        base: PCNGraph? = nil,
        fallbacks: [PCNGraph] = [],
        closed: [NoGoCircle] = [],
        avoid: [NoGoCircle] = [],
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
            // The preferred graph first; if its path is closed or over the cap, each fallback in
            // turn (so a scenic bend or a crowd to avoid never breaks the cap or forces road gap legs).
            if !closed.isEmpty || !avoid.isEmpty || !fallbacks.isEmpty {
                for g in [graph] + fallbacks {
                    guard let p = g.path(from: entry, to: exit), !p.contains(where: isClosed),
                          base.pathLength(p) <= PCNGraph.maxDetourRatio * base.pathLength(open) else { continue }
                    onPCN = p
                    break
                }
            }
            // start -> entry node (gap), unless already essentially on it. A closed entry
            // node is never visited: the closed run below gaps straight from `a`.
            if Geo.distance(a.cl, entryC.cl) > gapEpsilon, !isClosed(entryC) { append(await gap(a, entryC), off: true) }
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
            // exit node -> destination (gap). A closed exit node already gapped to `b` above.
            if isClosed(exitC) { continue }
            if Geo.distance(exitC.cl, b.cl) > gapEpsilon { append(await gap(exitC, b), off: true) }
            else { append([b], off: false) }
        }

        let offMeters = offSegments.reduce(0.0) { $0 + (Geo.cumulative($1.coordinates).last ?? 0) }
        return (poly, offSegments, offMeters)
    }

    /// A turn list from the line's own bends. Reuses Geo's bearing maths, the
    /// same classification the MapKit path uses. With the graphs the line was
    /// routed on, a bend is only announced near a real junction (a choice for the
    /// rider) or where the line changes network, and says what it turns onto:
    /// the connector's name, else the kind of path.
    /// ponytail: emits a step only on a >minTurn bend spaced >minSpacing apart, so
    /// dense connector vertices don't spam the turn list. Both tuned on-device.
    static let minTurn: Double = 25       // degrees
    static let minSpacing: Double = 30    // metres
    /// A bend this close to a junction (along the line) is that junction's turn:
    /// windowed bearings put the bend a few metres off the junction vertex.
    static let junctionWindow: Double = 15

    private enum Spot: Equatable {
        case pcn(GridKey), road(Int), none
        func sameNetwork(_ o: Spot) -> Bool {
            switch (self, o) { case (.pcn, .pcn), (.road, .road): return true; default: return false }
        }
    }

    static func steps(from poly: [Coord], pcn: PCNGraph? = nil, roads: RoadGraph? = nil) -> [StoredStep] {
        let coords = poly.coordinates
        guard coords.count >= 2 else { return [] }
        let cum = Geo.cumulative(coords)
        let spots: [Spot] = poly.map { c in
            if let k = pcn?.node(at: c) { return .pcn(k) }
            if let i = roads?.node(at: c) { return .road(i) }
            return .none
        }
        // Junction, network seam or unknown ground: somewhere a turn can be a choice.
        let choice: [Bool] = spots.indices.map { i in
            if i > 0, spots[i - 1].sameNetwork(spots[i]) == false { return true }
            if i + 1 < spots.count, spots[i + 1].sameNetwork(spots[i]) == false { return true }
            switch spots[i] {
            case .none:          return true
            case .pcn(let k):    return (pcn?.degree(k) ?? 3) >= 3
            case .road(let r):   return Int(roads?.degree[r] ?? 3) >= 3
            }
        }
        func nearChoice(_ i: Int) -> Bool {
            var j = i; while j >= 0, cum[i] - cum[j] <= junctionWindow { if choice[j] { return true }; j -= 1 }
            j = i + 1; while j < cum.count, cum[j] - cum[i] <= junctionWindow { if choice[j] { return true }; j += 1 }
            return false
        }
        /// What the rider turns onto at vertex i: (spoken target, street name).
        func onto(_ i: Int) -> (String, String)? {
            switch (spots[i], spots[i + 1]) {
            case (_, .pcn(let k)):
                if let n = pcn?.name[k] { return (n, n) }
                return ("the park connector", "")
            case (.road(let u), .road(let v)):
                guard let c = roads?.edgeClass(u, v) else { return nil }
                return (c == 0 ? "the cycleway" : c == 1 ? "the path" : "the road", "")
            default:
                return nil
            }
        }

        var out: [StoredStep] = [step(.depart, "Start", at: coords[0], offset: 0)]
        var lastAt = 0.0
        for i in 1..<(coords.count - 1) {
            guard let inB = Geo.exitBearing(Array(coords[...i])),
                  let outB = Geo.entryBearing(Array(coords[i...])) else { continue }
            let angle = Geo.turn(from: inB, to: outB)
            guard abs(angle) >= minTurn, cum[i] - lastAt >= minSpacing, nearChoice(i) else { continue }
            let m = Maneuver.classify(turn: angle)
            var text = phrase(m), road = ""
            if m != .uTurn, let (target, name) = onto(i) {
                let into = !target.contains("Connector") && (target.contains("Park") || target.contains("Garden"))
                text += (into ? " into " : " onto ") + target
                road = name
            }
            out.append(step(m, text, road: road, at: coords[i], offset: cum[i]))
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

    private static func step(_ m: Maneuver, _ text: String, road: String = "", at c: CLLocationCoordinate2D, offset: Double) -> StoredStep {
        StoredStep(instruction: text, road: road, distance: 0, maneuverOffset: offset,
                   maneuverRaw: m.rawValue, lat: c.latitude, lon: c.longitude)
    }
}

// MARK: - Self check

extension PCNRouting {
    static func selfCheck() async {
        // Stitch with a straight-line gap stub. Start 30 m south of
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

        // With the graph: a bend with no other way to go is not announced; at a
        // real junction the turn names the connector it turns onto.
        let w = Coord(lat: 1.30, lon: 103.80), j = Coord(lat: 1.30, lon: 103.802)
        let n = Coord(lat: 1.302, lon: 103.802), s = Coord(lat: 1.298, lon: 103.802)
        let bend = PCNGraph(named: [("Ulu Pandan Park Connector", [w, j]), ("Ulu Pandan Park Connector", [j, n])])
        assert(PCNRouting.steps(from: [w, j, n], pcn: bend).count == 2, "a plain bend must not be a turn")
        let tee = PCNGraph(named: [("Ulu Pandan Park Connector", [w, j]), ("Whampoa Park Connector", [j, n]), (nil, [j, s])])
        let t = PCNRouting.steps(from: [w, j, n], pcn: tee)
        assert(t.count == 3 && t[1].instruction == "Turn left onto Whampoa Park Connector" && t[1].road == "Whampoa Park Connector",
               "junction turn unnamed: \(t.map(\.instruction))")
        let u = PCNRouting.steps(from: [w, j, s], pcn: tee)
        assert(u[1].instruction == "Turn right onto the park connector", "unnamed connector: \(u.map(\.instruction))")

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
        // 5. Destination / start just off a closed node: no spur into the closure and back.
        let nearCorner = Coord(lat: 1.300 - 30 / PCNGraph.metresPerDegree, lon: 103.802)
        let r5 = await stitched(waypoints: [west, nearCorner], graph: g1.penalised(closed: [shut], walk: []), base: g1,
                                closed: [shut], gap: { [$0, $1] })
        assert(!r5.poly.contains { $0 == corner } && r5.poly.last == nearCorner, "exit spur into closure: \(r5.poly)")
        let r6 = await stitched(waypoints: [nearCorner, west], graph: g1.penalised(closed: [shut], walk: []), base: g1,
                                closed: [shut], gap: { [$0, $1] })
        assert(!r6.poly.contains { $0 == corner } && r6.poly.first == nearCorner, "entry spur into closure: \(r6.poly)")
        // 7. Ride context: an avoid circle on one side of the square sends the route the other way (within the cap)…
        let r7 = await stitched(waypoints: [west, north], graph: sq.penalised(closed: [], walk: [], avoid: [shut]), base: sq,
                                avoid: [shut], gap: { [$0, $1] })
        assert(r7.offSegments.isEmpty && !r7.poly.contains(where: inside), "avoid circle should bend the route: \(r7.poly)")
        // …but past the +30 % cap the short side is ridden, no gap leg (avoid is a preference, not a closure).
        let r8 = await stitched(waypoints: [west, north], graph: lg.penalised(closed: [], walk: [], avoid: [shut]), base: lg,
                                avoid: [shut], gap: { [$0, $1] })
        assert(r8.offSegments.isEmpty && r8.poly.contains { $0 == corner }, "over the cap the short side stays: \(r8.poly)")
        // 9. Closure on one side, a crowd on the other, a long way round over the cap: the crowded
        //    side is still a closure-free connector within the cap, so it beats road gap legs.
        let longWay = [west, Coord(lat: 1.300, lon: 103.797), Coord(lat: 1.302, lon: 103.797), north]
        let side = Coord(lat: 1.302, lon: 103.7999)   // the crowded side, a little longer than the closed one
        let three = PCNGraph(polylines: [[west, corner, north], [west, side, north], longWay])
        let crowd = NoGoCircle(coord: side, radiusMeters: 20)
        let r9 = await stitched(waypoints: [west, north], graph: three.penalised(closed: [shut], walk: [], avoid: [crowd]), base: three,
                                fallbacks: [three.penalised(closed: [shut], walk: [])], closed: [shut], avoid: [crowd], gap: { [$0, $1] })
        assert(r9.offSegments.isEmpty && r9.poly.contains { $0 == side }, "closure-only detour must beat road gap legs: \(r9.poly)")
        print("PCNRouting avoid checks: r7 r8 r9")

        // 10. Scenic: a square A→B, the north side a little longer and all scenic.
        let a = Coord(lat: 1.300, lon: 103.800), b = Coord(lat: 1.300, lon: 103.810)
        let southMid = Coord(lat: 1.299, lon: 103.805), northMid = Coord(lat: 1.3012, lon: 103.805)
        let box = PCNGraph(polylines: [[a, southMid, b], [a, northMid, b]])
        let pretty = Set([a, northMid, b].compactMap { box.nearest(to: $0) })
        let r10 = await stitched(waypoints: [a, b], graph: box.scenic(pretty, strength: 1), base: box,
                                 fallbacks: [box.scenic(pretty, strength: 0.5), box], gap: { [$0, $1] })
        assert(r10.poly.contains(northMid), "scenic strength 1 should take the scenic side: \(r10.poly)")
        let r10d = await stitched(waypoints: [a, b], graph: box, base: box, gap: { [$0, $1] })
        assert(r10d.poly.contains(southMid), "Direct takes the short side: \(r10d.poly)")
        // 11. Scenic loop 1.6 × the direct length: both scenic graphs break the cap, so the direct path.
        let farMid = Coord(lat: 1.3 + 694 / 111_195, lon: 103.805)
        let loop = PCNGraph(polylines: [[a, southMid, b], [a, farMid, b]])
        let loopPretty = Set([a, farMid, b].compactMap { loop.nearest(to: $0) })
        let r11 = await stitched(waypoints: [a, b], graph: loop.scenic(loopPretty, strength: 1), base: loop,
                                 fallbacks: [loop.scenic(loopPretty, strength: 0.5), loop], gap: { [$0, $1] })
        assert(r11.poly.contains(southMid) && !r11.poly.contains(farMid), "a scenic loop over +30 % must fall back to direct: \(r11.poly)")
        // 12. The scenic side inside an active closure: closure cost wins, the route goes round.
        let shutNorth = NoGoCircle(coord: northMid, radiusMeters: 30)
        let r12 = await stitched(waypoints: [a, b], graph: box.penalised(closed: [shutNorth], walk: []).scenic(pretty, strength: 1), base: box,
                                 fallbacks: [box.penalised(closed: [shutNorth], walk: [])], closed: [shutNorth], gap: { [$0, $1] })
        assert(r12.poly.contains(southMid) && r12.offSegments.isEmpty, "a closed scenic side must not be ridden: \(r12.poly)")
        // Scenic discounts the ride, never a penalty: a walk zone on a scenic edge still costs its full extra.
        if let ka = box.nearest(to: a), let kn = box.nearest(to: northMid),
           let w0 = box.adj[ka]?.first(where: { $0.0 == kn })?.1,
           let w1 = box.scenic(pretty, strength: 1).penalised(closed: [], walk: [NoGoCircle(coord: northMid, radiusMeters: 30)]).adj[ka]?.first(where: { $0.0 == kn })?.1 {
            assert(abs(w1 - (w0 * 0.5 + PCNGraph.walkExtraMeters)) < 0.01, "walk penalty must apply in full on a scenic edge: \(w1) vs \(w0)")
        } else { assertionFailure("toy square edge missing") }
        print("PCNRouting scenic checks: r10 r11 r12")
    }
}
