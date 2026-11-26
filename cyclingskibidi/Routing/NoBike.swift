//
//  NoBike.swift
//  cyclingskibidi
//
//  Ways with no bikes at all (spec 6a): expressways and their slip roads, bicycle=no
//  ways and steps, from the bundled nobike.json (scripts/map/nobike.py). The road
//  network never routes on them; this catches the one thing that can: a straight
//  fallback leg drawn across one. Their entrances feed the off-route alarm.
//

import Foundation
import CoreLocation

nonisolated struct NoBikeLine: Sendable {
    let kind: String          // "expressway" | "nobike" | "steps"
    let name: String
    let pts: [Coord]
    /// minLat, maxLat, minLon, maxLon: the bbox prefilter for crossings.
    let box: (Double, Double, Double, Double)

    init(kind: String, name: String, pts: [Coord]) {
        self.kind = kind; self.name = name; self.pts = pts
        box = (pts.map(\.lat).min() ?? 0, pts.map(\.lat).max() ?? 0, pts.map(\.lon).min() ?? 0, pts.map(\.lon).max() ?? 0)
    }
}

nonisolated struct NoBikeEntrance: Sendable {
    let kind: String
    let name: String
    let lat, lon: Double
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    /// Stable key for "It's not there" silencing.
    var key: String { "\(lat)|\(lon)" }
}

nonisolated enum NoBike {
    private static let bundle: (lines: [NoBikeLine], entrances: [NoBikeEntrance]) = {
        struct File: Decodable {
            struct L: Decodable { let kind, name: String; let pts: [[Double]] }
            struct E: Decodable { let kind, name: String; let lat, lon: Double }
            let lines: [L]; let entrances: [E]
        }
        guard let url = Bundle.main.url(forResource: "nobike", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return ([], []) }
        return (file.lines.map { NoBikeLine(kind: $0.kind, name: $0.name, pts: $0.pts.map { Coord(lat: $0[0], lon: $0[1]) }) },
                file.entrances.map { NoBikeEntrance(kind: $0.kind, name: $0.name, lat: $0.lat, lon: $0.lon) })
    }()

    static var lines: [NoBikeLine] { bundle.lines }
    static var entrances: [NoBikeEntrance] { bundle.entrances }

    /// Where a straight leg crosses any no-bike line (one point per crossed segment).
    static func crossings(of leg: [Coord], lines: [NoBikeLine] = NoBike.lines) -> [Coord] {
        var out: [Coord] = []
        for (a, b) in zip(leg, leg.dropFirst()) {
            let lo = (min(a.lat, b.lat), max(a.lat, b.lat), min(a.lon, b.lon), max(a.lon, b.lon))
            for line in lines where line.box.0 <= lo.1 && line.box.1 >= lo.0 && line.box.2 <= lo.3 && line.box.3 >= lo.2 {
                for (c, d) in zip(line.pts, line.pts.dropFirst()) {
                    if let x = intersection(a, b, c, d) { out.append(x) }
                }
            }
        }
        return out
    }

    /// Crossings of the straight fallback legs only: the 2-point off-connector segments.
    /// Real network legs cross expressways on bridges and in underpasses, which is fine.
    static func crossings(inOffSegments segments: [[Coord]], lines: [NoBikeLine] = NoBike.lines) -> [Coord] {
        segments.filter { $0.count == 2 }.flatMap { crossings(of: $0, lines: lines) }
    }

    /// What a crossing on `polyline` is, for the route sheet: the no-bike line it crosses,
    /// how far along the route it is, and the length of the straight leg it's on.
    static func describe(_ crossing: Coord, on polyline: [Coord], lines: [NoBikeLine] = NoBike.lines) -> (line: NoBikeLine?, along: Double, legLength: Double) {
        let pad = 0.0005
        let line = lines.filter { $0.box.0 - pad <= crossing.lat && $0.box.1 + pad >= crossing.lat && $0.box.2 - pad <= crossing.lon && $0.box.3 + pad >= crossing.lon }
            .min { a, b in
                func d(_ l: NoBikeLine) -> Double { l.pts.map { Geo.distance($0.cl, crossing.cl) }.min() ?? .infinity }
                return d(a) < d(b)
            }
        let cl = polyline.map(\.cl), cum = Geo.cumulative(cl)
        guard let s = Geo.snap(crossing.cl, to: cl, cumulative: cum), cl.indices.contains(s.index + 1) else { return (line, 0, 0) }
        return (line, s.along, Geo.distance(cl[s.index], cl[s.index + 1]))
    }

    /// Segment intersection in a flat local frame (metres); nil if they don't touch.
    static func intersection(_ a: Coord, _ b: Coord, _ c: Coord, _ d: Coord) -> Coord? {
        let k = cos(a.lat * .pi / 180) * 111_195, m = 111_195.0
        func xy(_ p: Coord) -> (Double, Double) { ((p.lon - a.lon) * k, (p.lat - a.lat) * m) }
        let (bx, by) = xy(b), (cx, cy) = xy(c), (dx, dy) = xy(d)
        let den = bx * (dy - cy) - by * (dx - cx)
        guard abs(den) > 1e-9 else { return nil }   // parallel
        let t = (cx * (dy - cy) - cy * (dx - cx)) / den
        let u = (cx * by - cy * bx) / den
        guard (0...1).contains(t), (0...1).contains(u) else { return nil }
        return Coord(lat: a.lat + (b.lat - a.lat) * t, lon: a.lon + (b.lon - a.lon) * t)
    }

    /// The walk-your-bike stretches a line passes through, for the gold rows: the chord
    /// of each circle the line crosses, measured along the line.
    static func walkStretches(on polyline: [Coord], walk: [NoGoCircle], names: [String]) -> [(name: String, along: Double, length: Double)] {
        let line = polyline.map(\.cl), cum = Geo.cumulative(line)
        guard line.count >= 2, let total = cum.last else { return [] }
        return zip(walk, names).compactMap { circle, name in
            guard let s = Geo.snap(circle.coord.cl, to: line, cumulative: cum), s.lateral <= circle.radiusMeters else { return nil }
            let half = (circle.radiusMeters * circle.radiusMeters - s.lateral * s.lateral).squareRoot()
            let start = max(0, s.along - half), end = min(total, s.along + half)
            return (name, start, end - start)
        }
        .sorted { $0.along < $1.along }
    }

    static func selfCheck() {
        // A toy expressway running north-south at lon 103.800.
        let toy = [NoBikeLine(kind: "expressway", name: "Toy Expressway",
                              pts: [Coord(lat: 1.300, lon: 103.800), Coord(lat: 1.310, lon: 103.800)])]
        let across = [Coord(lat: 1.305, lon: 103.798), Coord(lat: 1.305, lon: 103.802)]
        let hit = crossings(of: across, lines: toy)
        assert(hit.count == 1 && Geo.distance(hit[0].cl, .init(latitude: 1.305, longitude: 103.800)) < 1,
               "a straight leg across an expressway must cross it once, at the true point: \(hit)")
        let m20 = 20 / (111_195 * cos(1.305 * .pi / 180))
        assert(crossings(of: [Coord(lat: 1.301, lon: 103.800 + m20), Coord(lat: 1.309, lon: 103.800 + m20)], lines: toy).isEmpty,
               "a leg parallel 20 m away must not cross")
        let m5 = 5 / (111_195 * cos(1.305 * .pi / 180))
        assert(crossings(of: [Coord(lat: 1.305, lon: 103.798), Coord(lat: 1.305, lon: 103.800 - m5)], lines: toy).isEmpty,
               "a leg ending 5 m short must not cross")

        // Only straight legs are tested: a 40-point network leg across the same line is a bridge.
        let road = (0..<40).map { Coord(lat: 1.306, lon: 103.798 + Double($0) * 0.0001) }
        assert(crossings(inOffSegments: [across, road], lines: toy).count == 1, "only the 2-point straight leg may be flagged")
        assert(crossings(inOffSegments: [], lines: toy).isEmpty)

        // Real data: the bundled lines know the Pan-Island Expressway, and a straight leg
        // across it near Toa Payoh (about 400 m, either side) crosses it.
        assert(lines.contains { $0.name == "Pan-Island Expressway" }, "nobike.json must hold the Pan-Island Expressway")
        let toaPayoh = [Coord(lat: 1.3283, lon: 103.8466), Coord(lat: 1.3318, lon: 103.8466)]
        assert(!crossings(of: toaPayoh).isEmpty, "a straight leg across the PIE at Toa Payoh must be flagged")

        // Walk stretches: a 50 m circle on the line is about 100 m of walking at its offset.
        let east = [Coord(lat: 1.300, lon: 103.800), Coord(lat: 1.300, lon: 103.810)]
        let c = NoGoCircle(coord: Coord(lat: 1.300, lon: 103.805), radiusMeters: 50)
        let w = walkStretches(on: east, walk: [c], names: ["Toy Bridge"])
        let mid = Geo.distance(east[0].cl, c.coord.cl)
        assert(w.count == 1 && abs(w[0].length - 100) < 2 && abs(w[0].along - (mid - 50)) < 2 && w[0].name == "Toy Bridge",
               "a walk circle on the line should be ~100 m at its offset: \(w)")
        let far = NoGoCircle(coord: Coord(lat: 1.300 + 200 / 111_195, lon: 103.805), radiusMeters: 50)
        assert(walkStretches(on: east, walk: [far], names: ["Far"]).isEmpty, "a circle 200 m off the line is no walk stretch")
    }
}
