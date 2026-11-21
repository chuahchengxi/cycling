//
//  Closures.swift
//  cyclingskibidi
//
//  Bundled park-connector closures and no-cycling zones. Active closures become
//  no-go circles for routing; saved routes are checked against them when opened.
//

import Foundation

/// An exclusion circle: no route may ride within `radiusMeters` of `coord`.
nonisolated struct NoGoCircle: Sendable {
    var coord: Coord
    var radiusMeters: Double
}

nonisolated struct Closure: Codable, Sendable, Identifiable {
    struct Circle: Codable, Sendable { var lat, lon, radiusM: Double; var coordSource: String }
    enum Kind: String, Codable, Sendable { case closure; case noCycling = "no_cycling" }

    var id: String
    var name: String
    var circles: [Circle]
    var starts: String?
    var validUntil: String?
    var note: String
    var sourceUrl: String
    var kind: Kind

    /// `starts` and `validUntil` are whole days, Singapore time; `validUntil` is inclusive.
    func isActive(on date: Date) -> Bool {
        if let s = starts.flatMap(Closures.day), date < s { return false }
        if kind == .noCycling { return true }
        guard let end = validUntil.flatMap(Closures.day) else { return true }
        return date < Closures.sg.date(byAdding: .day, value: 1, to: end)!
    }

    /// Past its `validUntil` (no_cycling never ends). Not-yet-started closures are neither active nor ended.
    func hasEnded(by date: Date) -> Bool {
        guard kind == .closure, let end = validUntil.flatMap(Closures.day) else { return false }
        return date >= Closures.sg.date(byAdding: .day, value: 1, to: end)!
    }

    /// `validUntil` as "31 Dec 2026", Singapore time; nil when there's no end date.
    var untilText: String? {
        guard let d = validUntil.flatMap(Closures.day) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"; f.timeZone = Closures.sg.timeZone; f.locale = Locale(identifier: "en_SG")
        return f.string(from: d)
    }

    var noGoCircles: [NoGoCircle] {
        circles.map { NoGoCircle(coord: Coord(lat: $0.lat, lon: $0.lon), radiusMeters: $0.radiusM) }
    }
}

nonisolated enum Closures {
    static let sg: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Singapore")!
        return c
    }()

    /// Start of a `yyyy-MM-dd` day in Singapore, nil if malformed.
    static func day(_ s: String) -> Date? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return sg.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    static func decode(_ data: Data) -> [Closure] {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        // Per entry, so one bad record (say, a kind a newer file adds) drops only itself.
        struct Lossy: Decodable { let c: Closure?; init(from d: Decoder) { c = try? Closure(from: d) } }
        return ((try? d.decode([Lossy].self, from: data)) ?? []).compactMap(\.c)
    }

    private static let cached: [Closure] = {
        guard let url = Bundle.main.url(forResource: "closures", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return decode(data)
    }()
    static func bundled() -> [Closure] { cached }

    /// The rider's own "Path closed" marks, kept in step with the store by
    /// ContentView. Every plan avoids them and every saved route is checked
    /// against them, so a mark is never forgotten on the next route.
    @MainActor static var marked: [Closure] = []
    static let markedRadius: Double = 40

    /// A rider's mark as a one-circle, open-ended closure.
    static func marked(id: String, lat: Double, lon: Double, note: String) -> Closure {
        Closure(id: "marked-\(id)", name: "Path you marked closed",
                circles: [Closure.Circle(lat: lat, lon: lon, radiusM: markedRadius, coordSource: "rider")],
                starts: nil, validUntil: nil, note: note, sourceUrl: "", kind: .closure)
    }

    /// Now, or in DEBUG the `-closuresDate yyyy-MM-dd` launch argument.
    static var now: Date {
        #if DEBUG
        if let s = UserDefaults.standard.string(forKey: "closuresDate"), let d = day(s) { return d }
        #endif
        return .now
    }

    static func activeCircles(on date: Date = Closures.now) -> (closed: [NoGoCircle], walk: [NoGoCircle]) {
        let active = bundled().filter { $0.isActive(on: date) }
        return (active.filter { $0.kind == .closure }.flatMap(\.noGoCircles),
                active.filter { $0.kind == .noCycling }.flatMap(\.noGoCircles))
    }

    /// Closures the line rides along, split into active and ended.
    static func hits(_ polyline: [Coord], in closures: [Closure], on date: Date) -> (active: [Closure], expired: [Closure]) {
        let line = polyline.coordinates
        let cum = Geo.cumulative(line)
        // Cheap box reject first: ~750 circles x ~5000 segments is too much for the main thread.
        let pad = 200 / PCNGraph.metresPerDegree
        guard let la0 = polyline.map(\.lat).min(), let la1 = polyline.map(\.lat).max(),
              let lo0 = polyline.map(\.lon).min(), let lo1 = polyline.map(\.lon).max() else { return ([], []) }
        let box = { (ci: Closure.Circle) in (la0 - pad...la1 + pad).contains(ci.lat) && (lo0 - pad...lo1 + pad).contains(ci.lon) }
        // A hit means riding along the closure: at least 3 of its circles (all, if it has fewer).
        // A road crossing a closed path touches at most 2 neighbouring circles, so it doesn't warn.
        let hit = closures.filter { c in
            let need = min(3, c.circles.count)
            var n = 0
            for ci in c.circles where box(ci) && (Geo.snap(Coord(lat: ci.lat, lon: ci.lon).cl, to: line, cumulative: cum)?.lateral ?? .infinity) <= ci.radiusM {
                n += 1
                if n >= need { return true }
            }
            return false
        }
        return (hit.filter { $0.isActive(on: date) }, hit.filter { $0.hasEnded(by: date) })
    }
}

// MARK: - Self check

extension Closures {
    static func selfCheck() {
        let json = """
        [{"id":"a","name":"Open-ended","circles":[{"lat":1.3,"lon":103.8,"radius_m":50,"coord_source":"test"}],
          "starts":"2026-05-04","valid_until":null,"note":"","source_url":"x","kind":"closure"},
         {"id":"b","name":"Ends 31 Dec","circles":[{"lat":1.31,"lon":103.8,"radius_m":50,"coord_source":"test"}],
          "starts":"2026-01-01","valid_until":"2026-12-31","note":"","source_url":"x","kind":"closure"},
         {"id":"c","name":"No cycling","circles":[{"lat":1.32,"lon":103.8,"radius_m":50,"coord_source":"test"}],
          "starts":null,"valid_until":"2020-01-01","note":"","source_url":"x","kind":"no_cycling"}]
        """.data(using: .utf8)!
        let all = decode(json)
        assert(all.count == 3, "decode failed")
        func day(_ s: String, _ h: Int) -> Date {
            let p = s.split(separator: "-").map { Int($0)! }
            return sg.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: h))!
        }
        assert(all[0].isActive(on: day("2030-01-01", 12)), "no end date must stay active")
        assert(!all[0].isActive(on: day("2026-05-03", 12)), "not active before starts")
        assert(all[1].isActive(on: day("2026-12-31", 23)), "valid_until is inclusive, SG time")
        assert(!all[1].isActive(on: day("2027-01-01", 0)), "expired the day after")
        assert(all[2].isActive(on: day("2030-01-01", 12)), "no_cycling never expires")
        assert(decode(Data("not json".utf8)).isEmpty, "bad data must decode to []")
        // One bad entry (unknown kind) must not drop the good ones.
        let mixed = "[" + String(data: json, encoding: .utf8)!.dropFirst().dropLast() + #",{"id":"z","kind":"mystery"}]"#
        assert(decode(Data(mixed.utf8)).count == 3, "one bad entry dropped the rest")
        // Crossing a closed path is not riding it: 5 circles 30 m apart east-west.
        let step = 30 / 111_195.0
        let strip = Closure(id: "s", name: "Strip", circles: (0..<5).map {
            Closure.Circle(lat: 1.35, lon: 103.8 + Double($0) * step, radiusM: 20, coordSource: "test") },
            starts: nil, validUntil: nil, note: "", sourceUrl: "x", kind: .closure)
        let across = [Coord(lat: 1.349, lon: 103.8 + 2.5 * step), Coord(lat: 1.351, lon: 103.8 + 2.5 * step)]
        let along = [Coord(lat: 1.35, lon: 103.799), Coord(lat: 1.35, lon: 103.801)]
        assert(hits(across, in: [strip], on: .now).active.isEmpty, "a crossing must not warn")
        assert(hits(along, in: [strip], on: .now).active.count == 1, "riding along must warn")
        // Not started yet is neither active nor "was closed".
        let early = hits([Coord(lat: 1.299, lon: 103.8), Coord(lat: 1.301, lon: 103.8)], in: all, on: day("2026-05-01", 12))
        assert(early.active.isEmpty && early.expired.isEmpty, "future closure read as expired: \(early)")
        // A line through b's centre, checked after b expired: expired hit, not active.
        let line = [Coord(lat: 1.309, lon: 103.8), Coord(lat: 1.311, lon: 103.8)]
        let h = hits(line, in: all, on: day("2027-02-01", 12))
        assert(h.active.isEmpty && h.expired.map(\.id) == ["b"], "expired hit wrong: \(h)")
        assert(all[1].untilText == "31 Dec 2026" && all[0].untilText == nil, "until text wrong: \(String(describing: all[1].untilText))")
        assert(!bundled().isEmpty, "closures.json missing from bundle")
        // Saved route along the real Bedok closure: warned now, "was closed" after 31 Dec 2026.
        if let bedok = bundled().first(where: { $0.id == "bedok-pc-laguna88" }) {
            let line = bedok.circles.map { Coord(lat: $0.lat, lon: $0.lon) }
            let before = hits(line, in: bundled(), on: day("2026-11-21", 12))
            let after = hits(line, in: bundled(), on: day("2027-01-02", 12))
            assert(before.active.contains { $0.id == bedok.id }, "Bedok closure not flagged on a saved route")
            assert(after.expired.contains { $0.id == bedok.id } && !after.active.contains { $0.id == bedok.id },
                   "Bedok closure should read as expired in 2027")
        } else { assertionFailure("bedok-pc-laguna88 missing") }
        // A rider's mark warns on a saved route that rides past it, and never expires.
        let mark = marked(id: "t", lat: 1.35, lon: 103.8, note: "")
        assert(hits(along, in: [mark], on: day("2040-01-01", 12)).active.count == 1, "a marked closure must warn")
        assert(hits(across.map { Coord(lat: $0.lat, lon: $0.lon + 0.01) }, in: [mark], on: .now).active.isEmpty,
               "a mark 1 km away must not warn")
    }
}
