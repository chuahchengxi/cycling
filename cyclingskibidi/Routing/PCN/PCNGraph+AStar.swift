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
        var came: [GridKey: GridKey] = [:]
        var open = MinHeap()
        open.push(Geo.distance(coord[start]!.cl, goalC.cl), start)

        while let (f, current) = open.pop() {
            if current == goal { return rebuild(came, from: current) }
            let gc = g[current] ?? .infinity
            // Lazy deletion: skip entries pushed before a cheaper route to this node was found.
            if f > gc + Geo.distance(coord[current]!.cl, goalC.cl) + 1e-9 { continue }
            for (nb, w) in adj[current] ?? [] {
                let tentative = gc + w
                if tentative < (g[nb] ?? .infinity) {
                    came[nb] = current
                    g[nb] = tentative
                    open.push(tentative + Geo.distance(coord[nb]!.cl, goalC.cl), nb)
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

/// Binary min-heap of (f, node) for A*'s open set.
nonisolated private struct MinHeap {
    private var a: [(Double, GridKey)] = []
    mutating func push(_ f: Double, _ k: GridKey) {
        a.append((f, k))
        var i = a.count - 1
        while i > 0, a[(i - 1) / 2].0 > a[i].0 { a.swapAt(i, (i - 1) / 2); i = (i - 1) / 2 }
    }
    mutating func pop() -> (Double, GridKey)? {
        guard !a.isEmpty else { return nil }
        a.swapAt(0, a.count - 1)
        let top = a.removeLast()
        var i = 0
        while true {
            let l = 2 * i + 1, r = l + 1
            var m = i
            if l < a.count, a[l].0 < a[m].0 { m = l }
            if r < a.count, a[r].0 < a[m].0 { m = r }
            if m == i { return top }
            a.swapAt(i, m); i = m
        }
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

        // Disconnected components return nil: two separate legs in the same graph.
        let east  = [Coord(lat: 1.300, lon: 103.800), Coord(lat: 1.300, lon: 103.802)]
        let north = [Coord(lat: 1.300, lon: 103.802), Coord(lat: 1.302, lon: 103.802)]
        let island = [Coord(lat: 2.000, lon: 104.000), Coord(lat: 2.001, lon: 104.000)]
        let g2 = PCNGraph(polylines: [east, north, island])
        let westKey   = key(Coord(lat: 1.300, lon: 103.800), cell: g2.cell)
        let islandKey = key(Coord(lat: 2.000, lon: 104.000), cell: g2.cell)
        assert(g2.path(from: westKey, to: islandKey) == nil, "disconnected components must return nil")

        // 30x30 grid: corner to corner is 29 east + 29 north edges, whatever order.
        let d = 0.0005, o = Coord(lat: 1.3, lon: 103.8)
        func at(_ i: Int, _ j: Int) -> Coord { Coord(lat: o.lat + Double(i) * d, lon: o.lon + Double(j) * d) }
        let grid = PCNGraph(polylines: (0..<30).map { i in (0..<30).map { at(i, $0) } } + (0..<30).map { j in (0..<30).map { at($0, j) } })
        let ns = Geo.distance(at(0, 0).cl, at(1, 0).cl), ew = Geo.distance(at(0, 0).cl, at(0, 1).cl)
        let gp = grid.path(from: at(0, 0), to: at(29, 29)) ?? []
        assert(abs(grid.pathLength(gp) - 29 * (ns + ew)) < 1, "grid path length off: \(grid.pathLength(gp))")
    }
}
