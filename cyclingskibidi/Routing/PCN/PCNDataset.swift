//
//  PCNDataset.swift
//  cyclingskibidi
//
//  The connector graph's raw data: a copy ships in the bundle and is the only
//  source, so routing never needs a connection. New connectors arrive with an
//  app update.
//

import Foundation

enum PCNDataset {
    private static var cachedGraph: PCNGraph?
    /// In-flight build, so concurrent first-callers share one off-main build.
    private static var building: Task<PCNGraph, Never>?

    // MARK: Graph

    /// The graph, built OFF the main actor (a 1.9 MB decode + ~33k-vertex
    /// adjacency build) and memoised. Concurrent first-callers share one build, so
    /// the work never blocks the UI — not at launch, not on the first plan.
    static func graph() async -> PCNGraph {
        if let g = cachedGraph { return g }
        if let building { return await building.value }
        let task = Task.detached(priority: .userInitiated) { () -> PCNGraph in
            let data = seedData() ?? Data()
            return PCNGraph(named: GeoJSON.named(data))
        }
        building = task
        let g = await task.value
        cachedGraph = g
        building = nil
        return g
    }

    nonisolated private static func seedData() -> Data? {
        guard let url = Bundle.main.url(forResource: "pcn-seed", withExtension: "geojson") else { return nil }
        return try? Data(contentsOf: url)
    }
}

// MARK: - Self check

extension PCNDataset {
    static func selfCheck() async {
        // The bundled seed is present and parses to a non-trivial network.
        // ponytail: comment out if running before the seed file is added.
        let g = await graph()
        assert(!g.isEmpty, "pcn-seed.geojson missing or empty — is it in the bundle?")

        // Real data: a ride along Bedok Park Connector past its Laguna88 closure, 250 m
        // beyond each end, never rides a closed vertex, and plans quickly.
        guard let bedok = Closures.bundled().first(where: { $0.id == "bedok-pc-laguna88" }),
              let c0 = bedok.circles.first, let c1 = bedok.circles.last else {
            assertionFailure("bedok-pc-laguna88 missing from closures.json"); return
        }
        let shut = bedok.noGoCircles
        let len = Geo.distance(Coord(lat: c0.lat, lon: c0.lon).cl, Coord(lat: c1.lat, lon: c1.lon).cl)
        func beyond(_ p: Closure.Circle, _ q: Closure.Circle) -> Coord {   // 250 m past p, away from q
            let k = 250 / len
            return Coord(lat: p.lat + (p.lat - q.lat) * k, lon: p.lon + (p.lon - q.lon) * k)
        }
        let t0 = Date.now
        let r = await PCNRouting.stitched(waypoints: [beyond(c0, c1), beyond(c1, c0)],
                                          graph: g.penalised(closed: shut, walk: []), base: g,
                                          closed: shut, gap: { [$0, $1] })
        let inside = r.poly.filter { c in shut.contains { Geo.distance(c.cl, $0.coord.cl) <= $0.radiusMeters } }
        assert(inside.isEmpty, "Bedok route rides \(inside.count) closed vertices")
        // Timing is printed, not asserted: a cold simulator or the debugger would make it flaky.
        let turns = PCNRouting.steps(from: r.poly, pcn: g, roads: await RoadNetwork.graph())
        print("Bedok turns: \(turns.count - 2) vs \(PCNRouting.steps(from: r.poly).count - 2) bends; " + turns.map(\.instruction).joined(separator: " | "))
        print("Bedok closure check: \(Int(Geo.cumulative(r.poly.coordinates).last ?? 0)) m, \(r.offSegments.count) gap legs, \(Int(Date.now.timeIntervalSince(t0) * 1000)) ms")
    }
}
