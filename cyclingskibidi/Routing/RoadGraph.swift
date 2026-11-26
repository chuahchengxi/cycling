//
//  RoadGraph.swift
//  cyclingskibidi
//
//  The bundled road network (scripts/map/roads.py): every cyclable OSM way in
//  Singapore as a compact directed graph. Fast mode routes on it end to end;
//  Moderate/Leisure use it for the legs that leave the connectors. Offline.
//

import Foundation

nonisolated struct RoadGraph: Sendable {
    enum Profile: Sendable {
        /// Quickest: roads are fine, pavements a little slower.
        case fast
        /// Off-connector legs: paths and quiet streets first, big roads only when forced.
        case quiet

        /// Cost per metre by class: cycleway, path, minor, tertiary, secondary, primary, trunk.
        /// ponytail: hand-set weights; tune against real rides.
        var factors: [Float] {
            switch self {
            case .fast:  return [1.0, 1.15, 1.0, 1.0, 1.0, 1.05, 1.2]
            case .quiet: return [1.0, 1.0, 1.15, 1.4, 1.7, 2.0, 3.0]
            }
        }
    }

    let lat, lon: [Int32]          // degrees * 1e6
    let first: [UInt32]            // CSR row starts, n + 1
    let to: [UInt32]
    let len: [UInt16]              // half-metres
    let cls: [UInt8]
    private let cells: [Int64: [Int32]]
    /// Distinct neighbours per node, either direction (one-way streets count once).
    let degree: [UInt8]

    var nodeCount: Int { lat.count }
    static let cellDeg = 0.002     // ~220 m buckets for nearest-node lookups

    init?(data: Data) {
        guard data.count >= 12, data.prefix(4) == Data("RDG1".utf8) else { return nil }
        var off = 4
        func read<T>(_ count: Int) -> [T]? {
            let bytes = count * MemoryLayout<T>.stride
            guard off + bytes <= data.count else { return nil }
            defer { off += bytes }
            return [T](unsafeUninitializedCapacity: count) { buf, n in
                data.withUnsafeBytes { raw in
                    if bytes > 0 { memcpy(buf.baseAddress!, raw.baseAddress!.advanced(by: off), bytes) }
                }
                n = count
            }
        }
        guard let header: [UInt32] = read(2) else { return nil }
        let n = Int(header[0]), m = Int(header[1])
        guard let lat: [Int32] = read(n), let lon: [Int32] = read(n), let first: [UInt32] = read(n + 1),
              let to: [UInt32] = read(m), let len: [UInt16] = read(m), let cls: [UInt8] = read(m) else { return nil }
        self.lat = lat; self.lon = lon; self.first = first; self.to = to; self.len = len; self.cls = cls
        var cells: [Int64: [Int32]] = [:]
        for i in 0..<n { cells[Self.cell(Double(lat[i]) / 1e6, Double(lon[i]) / 1e6), default: []].append(Int32(i)) }
        self.cells = cells
        var degree = [UInt8](repeating: 0, count: n)
        for u in 0..<n {
            let row = Int(first[u])..<Int(first[u + 1])
            degree[u] = UInt8(min(255, Set(row.map { to[$0] }).count))
            // u -> v with no v -> u: one-way, so v gains u as a neighbour too.
            for e in row {
                let v = Int(to[e])
                if !(Int(first[v])..<Int(first[v + 1])).contains(where: { to[$0] == UInt32(u) }) { degree[v] &+= 1 }
            }
        }
        self.degree = degree
    }

    /// Class of the edge u -> v (see roads.py), if there is one either way.
    func edgeClass(_ u: Int, _ v: Int) -> UInt8? {
        func find(_ a: Int, _ b: Int) -> UInt8? {
            (Int(first[a])..<Int(first[a + 1])).first { to[$0] == UInt32(b) }.map { cls[$0] }
        }
        return find(u, v) ?? find(v, u)
    }

    private static func cell(_ la: Double, _ lo: Double) -> Int64 {
        Int64((la / cellDeg).rounded(.down)) << 32 | Int64((lo / cellDeg).rounded(.down)) & 0xffff_ffff
    }

    func coord(_ i: Int) -> Coord { Coord(lat: Double(lat[i]) / 1e6, lon: Double(lon[i]) / 1e6) }

    /// Nodes in the buckets overlapping a box of `radius` metres round `c`.
    private func candidates(near c: Coord, radius: Double) -> [Int32] {
        let r = radius / PCNGraph.metresPerDegree
        let la0 = Int64(((c.lat - r) / Self.cellDeg).rounded(.down)), la1 = Int64(((c.lat + r) / Self.cellDeg).rounded(.down))
        let lo0 = Int64(((c.lon - r) / Self.cellDeg).rounded(.down)), lo1 = Int64(((c.lon + r) / Self.cellDeg).rounded(.down))
        var out: [Int32] = []
        for a in la0...la1 { for b in lo0...lo1 { out += cells[a << 32 | b & 0xffff_ffff] ?? [] } }
        return out
    }

    /// The node at exactly this vertex (route vertices are node coords), if any.
    func node(at c: Coord) -> Int? {
        let la = Int32((c.lat * 1e6).rounded()), lo = Int32((c.lon * 1e6).rounded())
        return candidates(near: c, radius: 1).first { lat[Int($0)] == la && lon[Int($0)] == lo }.map(Int.init)
    }

    /// The nearest node within `radius` metres, if any.
    func nearest(_ c: Coord, radius: Double = 500) -> Int? {
        candidates(near: c, radius: radius)
            .map { (Int($0), Geo.distance(c.cl, coord(Int($0)).cl)) }
            .filter { $0.1 <= radius }
            .min { $0.1 < $1.1 }?.0
    }

    /// Extra cost on entering a node inside a closure / walk-only zone (metres).
    private func penalties(closed: [NoGoCircle], walk: [NoGoCircle]) -> [Int32: Float] {
        var out: [Int32: Float] = [:]
        for (circles, cost) in [(walk, Float(PCNGraph.walkExtraMeters)), (closed, Float(PCNGraph.closedExtraMeters))] {
            for n in circles {
                for i in candidates(near: n.coord, radius: n.radiusMeters)
                where Geo.distance(n.coord.cl, coord(Int(i)).cl) <= n.radiusMeters {
                    out[i] = max(out[i] ?? 0, cost)
                }
            }
        }
        return out
    }

    /// A* from the node nearest `a` to the node nearest `b`; the line runs from
    /// `a` itself to `b` itself. nil when either end is off the network or the
    /// two aren't connected.
    func route(_ a: Coord, _ b: Coord, profile: Profile, closed: [NoGoCircle] = [], walk: [NoGoCircle] = []) -> [Coord]? {
        guard let s = nearest(a), let t = nearest(b) else { return nil }
        if s == t { return [a, coord(s), b] }
        let factors = profile.factors, minFactor = factors.min() ?? 1
        let extra = penalties(closed: closed, walk: walk)
        let tl = Float(lat[t]) / 1e6, to0 = Float(lon[t]) / 1e6
        let kx = Float(cos(Double(tl) * .pi / 180) * PCNGraph.metresPerDegree), ky = Float(PCNGraph.metresPerDegree)
        func h(_ i: Int) -> Float {
            let dx = (Float(lon[i]) / 1e6 - to0) * kx, dy = (Float(lat[i]) / 1e6 - tl) * ky
            return (dx * dx + dy * dy).squareRoot() * minFactor
        }
        var g = [Float](repeating: .infinity, count: nodeCount)
        var prev = [Int32](repeating: -1, count: nodeCount)
        var heap = Heap()
        g[s] = 0
        heap.push(h(s), Int32(s))
        while let (f, u32) = heap.pop() {
            let u = Int(u32)
            if u == t { break }
            if f - h(u) > g[u] + 0.01 { continue }   // stale entry
            for e in Int(first[u])..<Int(first[u + 1]) {
                let v = Int(to[e])
                let w = Float(len[e]) / 2 * factors[Int(cls[e])] + (extra[Int32(v)] ?? 0)
                if g[u] + w < g[v] {
                    g[v] = g[u] + w
                    prev[v] = u32
                    heap.push(g[v] + h(v), Int32(v))
                }
            }
        }
        guard g[t].isFinite else { return nil }
        var path: [Coord] = []
        var k = t
        while k != -1 { path.append(coord(k)); k = Int(prev[k]) }
        path.reverse()
        return [a] + path + [b]
    }

    /// Binary min-heap on (priority, node), lazy deletion.
    private struct Heap {
        private var items: [(Float, Int32)] = []
        mutating func push(_ p: Float, _ n: Int32) {
            items.append((p, n))
            var i = items.count - 1
            while i > 0 { let up = (i - 1) / 2; if items[up].0 <= items[i].0 { break }; items.swapAt(up, i); i = up }
        }
        mutating func pop() -> (Float, Int32)? {
            guard let top = items.first else { return nil }
            let last = items.removeLast()
            if !items.isEmpty {
                items[0] = last
                var i = 0
                while true {
                    let l = 2 * i + 1, r = l + 1
                    var m = i
                    if l < items.count, items[l].0 < items[m].0 { m = l }
                    if r < items.count, items[r].0 < items[m].0 { m = r }
                    if m == i { break }
                    items.swapAt(i, m); i = m
                }
            }
            return top
        }
    }
}

/// The bundled road graph, loaded once off the main actor (an 11 MB read plus
/// a bucket index), shared by every plan.
enum RoadNetwork {
    private static var cached: RoadGraph?
    private static var building: Task<RoadGraph?, Never>?

    static func graph() async -> RoadGraph? {
        if let cached { return cached }
        if let building { return await building.value }
        let task = Task.detached(priority: .userInitiated) { () -> RoadGraph? in
            guard let url = Bundle.main.url(forResource: "roads", withExtension: "bin"),
                  let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
            return RoadGraph(data: data)
        }
        building = task
        let g = await task.value
        cached = g
        building = nil
        return g
    }

    static func selfCheck() async {
        guard let g = await graph() else { return assertionFailure("roads.bin missing or unreadable") }
        assert(g.nodeCount > 100_000, "road graph too small: \(g.nodeCount)")
        // Along Orchard Road: a real route, not much longer than the crow flies.
        let a = Coord(lat: 1.3040, lon: 103.8318), b = Coord(lat: 1.3005, lon: 103.8390)
        let crow = Geo.distance(a.cl, b.cl)
        let t0 = Date.now
        guard let r = g.route(a, b, profile: .fast) else { return assertionFailure("no road route along Orchard Road") }
        let len = Geo.cumulative(r.coordinates).last ?? 0
        assert(r.count > 3 && len >= crow && len < crow * 1.8, "Orchard route odd: \(Int(len)) m vs \(Int(crow)) m crow")
        // Close the middle of it: the new route keeps out of the circle.
        let mid = r[r.count / 2]
        let shut = NoGoCircle(coord: mid, radiusMeters: 30)
        guard let round = g.route(a, b, profile: .fast, closed: [shut]) else { return assertionFailure("no way round the closure") }
        assert(!round.contains { Geo.distance($0.cl, mid.cl) <= 30 }, "road route rode through a closure")
        // Off the island: no node to snap to, so no route.
        assert(g.route(Coord(lat: 1.0, lon: 103.0), b, profile: .fast) == nil, "a point at sea must not route")
        print("Road check: \(Int(len)) m along Orchard, \(Int(Date.now.timeIntervalSince(t0) * 1000)) ms for two routes")
    }
}
