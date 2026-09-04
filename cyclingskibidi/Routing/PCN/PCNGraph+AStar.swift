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
