//
//  Closures.swift
//  cyclingskibidi
//
//  Bundled park-connector closures and no-cycling zones. Active closures become
//  no-go circles for routing; saved routes are checked against them when opened.
//

import Foundation

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
        return (try? d.decode([Closure].self, from: data)) ?? []
    }

    private static let cached: [Closure] = {
        guard let url = Bundle.main.url(forResource: "closures", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return decode(data)
    }()
    static func bundled() -> [Closure] { cached }

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

    /// Closures with a circle within its radius of the line, split into active and expired.
    static func hits(_ polyline: [Coord], in closures: [Closure], on date: Date) -> (active: [Closure], expired: [Closure]) {
        let line = polyline.coordinates
        let cum = Geo.cumulative(line)
        let hit = closures.filter { c in
            c.circles.contains { ci in
                (Geo.snap(Coord(lat: ci.lat, lon: ci.lon).cl, to: line, cumulative: cum)?.lateral ?? .infinity) <= ci.radiusM
            }
        }
        return (hit.filter { $0.isActive(on: date) }, hit.filter { !$0.isActive(on: date) })
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
    }
}
