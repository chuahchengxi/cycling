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
nonisolated struct GridKey: Hashable { let la: Int; let lo: Int }

/// Sendable + nonisolated so the whole graph can be built off the main actor
/// (see PCNDataset.graph()) and handed back across the task boundary.
nonisolated struct PCNGraph: Sendable {
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
    /// Spoken connector name per node, first feature to reach it wins.
    /// ponytail: per node, not per edge; at a junction the name comes from the node after it.
    private(set) var name: [GridKey: String] = [:]

    init(polylines: [[Coord]], snapTolerance: Double = PCNGraph.defaultSnapTolerance) {
        self.init(named: polylines.map { (nil, $0) }, snapTolerance: snapTolerance)
    }

    init(named lines: [(name: String?, line: [Coord])], snapTolerance: Double = PCNGraph.defaultSnapTolerance) {
        self.cell = snapTolerance / PCNGraph.metresPerDegree
        for (label, line) in lines {
            var prev: GridKey?
            for v in line {
                let k = Self.key(v, cell: cell)
                if coord[k] == nil { coord[k] = v }
                if let label, name[k] == nil { name[k] = label }
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

    /// The node this exact vertex is, if it is one (path vertices are node coords).
    func node(at c: Coord) -> GridKey? {
        let k = Self.key(c, cell: cell)
        return coord[k] == c ? k : nil
    }

    /// Distinct neighbours: 3+ means a real junction, a choice for the rider.
    func degree(_ k: GridKey) -> Int { Set((adj[k] ?? []).map(\.0)).count }

    static func key(_ c: Coord, cell: Double) -> GridKey {
        GridKey(la: Int((c.lat / cell).rounded()), lo: Int((c.lon / cell).rounded()))
    }

    private mutating func addEdge(_ a: GridKey, _ b: GridKey, weight: Double) {
        adj[a, default: []].append((b, weight))
        adj[b, default: []].append((a, weight))
    }

    /// Nearest connector node to an arbitrary point — scans the query cell and a
    /// small ring of neighbours (covers points just off the network).
    /// ponytail: ringCells=2 search radius — too small misses a node just across a
    /// cell boundary, too large wastes the scan. Tune alongside snapTolerance on-device.
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

    /// Extra cost on edges touching a closure / a no-cycling (walk) zone.
    static let closedExtraMeters: Double = 1500
    static let walkExtraMeters: Double = 100
    /// Near crowded or dismount places the rider's context asks to avoid, an edge costs this
    /// many times its length: per metre, so the cost doesn't grow with vertex density.
    /// Crossing a 150 m circle (~300 m of path) costs about +600 m.
    static let avoidCostFactor: Double = 3
    /// A detour round a closure is taken only up to this ratio of the open route.
    static let maxDetourRatio: Double = 1.3

    /// A copy with closure and walk-zone costs added to every edge with an endpoint inside a circle,
    /// and an edge with an endpoint inside an `avoid` circle costing `avoidCostFactor` times its
    /// length (never a removal).
    /// ponytail: endpoint-only test; edges longer than ~50 m (max in seed 857 m) can miss a small
    /// circle. Split long edges at graph build if that shows up.
    func penalised(closed: [NoGoCircle], walk: [NoGoCircle], avoid: [NoGoCircle] = []) -> PCNGraph {
        guard !closed.isEmpty || !walk.isEmpty || !avoid.isEmpty else { return self }
        func inside(_ c: Coord, _ n: NoGoCircle) -> Bool {   // cheap latitude reject before the haversine
            abs(c.lat - n.coord.lat) * Self.metresPerDegree <= n.radiusMeters && Geo.distance(c.cl, n.coord.cl) <= n.radiusMeters
        }
        func extra(_ k: GridKey) -> Double {
            let c = coord[k]!
            if closed.contains(where: { inside(c, $0) }) { return Self.closedExtraMeters }
            if walk.contains(where: { inside(c, $0) }) { return Self.walkExtraMeters }
            return 0
        }
        func avoided(_ k: GridKey) -> Bool { avoid.contains { inside(coord[k]!, $0) } }
        let extras = coord.keys.reduce(into: [GridKey: Double]()) { if case let e = extra($1), e > 0 { $0[$1] = e } }
        let avoids = avoid.isEmpty ? [] : Set(coord.keys.filter(avoided))
        var g = self
        for (a, list) in adj {
            g.adj[a] = list.map { (b, w) in
                (b, w * (avoids.contains(a) || avoids.contains(b) ? Self.avoidCostFactor : 1) + max(extras[a] ?? 0, extras[b] ?? 0))
            }
        }
        return g
    }

    /// Ground length of a path (vertex coords), ignoring any penalties.
    func pathLength(_ path: [Coord]) -> Double { Geo.cumulative(path.coordinates).last ?? 0 }
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
        // A closed circle at the junction adds exactly closedExtraMeters to its edges.
        let shut = g.penalised(closed: [NoGoCircle(coord: Coord(lat: 1.300, lon: 103.802), radiusMeters: 10)], walk: [])
        let w2 = shut.adj[junction]!.first!.1
        assert(abs(w2 - w - closedExtraMeters) < 1, "closed penalty off: \(w2 - w)")
        assert(g.penalised(closed: [], walk: []).nodeCount == g.nodeCount, "empty penalty must keep the graph")
        // An avoid circle (ride context) multiplies the edge by avoidCostFactor: a cost, never a removal.
        let quiet = g.penalised(closed: [], walk: [], avoid: [NoGoCircle(coord: Coord(lat: 1.300, lon: 103.802), radiusMeters: 10)])
        let w3 = quiet.adj[junction]!.first!.1
        assert(abs(w3 - w * avoidCostFactor) < 1, "avoid penalty off: \(w3) vs \(w)")
        // …so crossing a crowd costs the same however many vertices the path has inside it.
        let a = Coord(lat: 1.300, lon: 103.800), b = Coord(lat: 1.300, lon: 103.802)
        let dense = PCNGraph(polylines: [(0...8).map { Coord(lat: 1.300, lon: 103.800 + Double($0) * 0.00025) }])
        let crowd = [NoGoCircle(coord: Coord(lat: 1.300, lon: 103.801), radiusMeters: 300)]
        let costOne = PCNGraph(polylines: [[a, b]]).penalised(closed: [], walk: [], avoid: crowd)
        let costDense = dense.penalised(closed: [], walk: [], avoid: crowd)
        func cost(_ g: PCNGraph) -> Double {
            var total = 0.0, at = key(a, cell: g.cell), prev: GridKey? = nil
            while at != key(b, cell: g.cell), let next = g.adj[at]?.first(where: { $0.0 != prev }) { total += next.1; prev = at; at = next.0 }
            return total
        }
        assert(abs(cost(costOne) - cost(costDense)) < 2, "crowd cost depends on vertex count: \(cost(costOne)) vs \(cost(costDense))")
    }
}
