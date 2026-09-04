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
