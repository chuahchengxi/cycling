//
//  Kit.swift
//  cyclingskibidi
//
//  Kit's quick picks (spec section 2, approach A): score the places a rider really
//  passes against what they like, spread the best along the route, and say why in
//  one line taken word for word from our data. Same on every iPhone.
//

import Foundation
import CoreLocation

/// One place Kit may pick, with the compact line the model sees (Task 3) and the
/// facts a note may be grounded in.
nonisolated struct KitCandidate: Sendable {
    let sight: Sight
    let score: Double
    /// "<osmID> | <name> | <category label> | km <n.n> | <facts>"
    let line: String
}

nonisolated enum Kit {
    /// Persona tag in likes 3, category in a liked interest 2, research note 1.5,
    /// Wikipedia 1, plus the learned weight for the category clamped to -2…+2.
    static func score(_ s: Sight, profile: RiderProfile, facts: [String: PlaceFacts]) -> Double {
        let f = s.osmID.flatMap { facts[$0] }
        let tags = Set(f?.note?.persona ?? [])
        let interest: Double = profile.likes.contains { !$0.personaTags.isDisjoint(with: tags) } ? 3
            : profile.likes.contains { $0.categories.contains(s.category) } ? 2 : 0
        let notable: Double = f?.note != nil ? 1.5 : f?.wiki == true ? 1 : 0
        return interest + notable + weight(s.category, profile)
    }

    static func weight(_ category: String, _ profile: RiderProfile) -> Double {
        min(2, max(-2, profile.weights[category] ?? 0))
    }

    static func candidates(_ sights: [Sight], profile: RiderProfile, facts: [String: PlaceFacts], max: Int = 40) -> [KitCandidate] {
        sights.map { s in KitCandidate(sight: s, score: score(s, profile: profile, facts: facts), line: line(s, facts[s.osmID ?? ""])) }
            .sorted { $0.score > $1.score }
            .prefix(max).map { $0 }
    }

    static func targetCount(lengthMeters: Double) -> Int {
        Swift.max(3, Int((lengthMeters / 20_000 * 5).rounded()))
    }

    /// The best `count` spread along the route, each with its template note, in route order.
    static func quickPicks(_ candidates: [KitCandidate], polyline: [CLLocationCoordinate2D], cumulative: [Double],
                           count: Int, facts: [String: PlaceFacts] = Discovery.facts) -> [Sight] {
        let scores = Dictionary(candidates.map { ($0.sight.id, $0.score) }, uniquingKeysWith: Swift.max)
        let length = cumulative.last ?? 0
        return Discovery.spread(candidates.map(\.sight), polyline: polyline, cumulative: cumulative, limit: count) { scores[$0.id] ?? 0 }
            .map { s in var s = s; s.note = templateNote(s, facts: s.osmID.flatMap { facts[$0] }, lengthMeters: length); return s }
    }

    /// One line, word for word from our data: a Bib stall, two dishes, the note's first
    /// sentence, or the category. Hawker centres in the last fifth are "good after the ride".
    static func templateNote(_ s: Sight, facts: PlaceFacts?, lengthMeters: Double) -> String {
        let n = facts?.note, hawker = s.category == "hawker"
        let what: String
        if let stall = n?.stalls?.first(where: { $0.bib != nil }), let year = stall.bib {
            what = "\(stall.name), Bib Gourmand \(year)"
        } else if let dishes = n?.dishes, !dishes.isEmpty {
            what = "Try " + dishes.prefix(2).joined(separator: " or ")
        } else if let sentence = n?.note.flatMap(firstSentence) {
            what = sentence
        } else if hawker {
            what = "Hawker centre, local dishes"
        } else {
            what = Discovery.icon(for: s.category).label
        }
        let late = hawker && lengthMeters > 0 && s.offsetAlong >= lengthMeters * 0.8
        return what + (late ? " · good after the ride" : " · km " + String(format: "%.1f", s.offsetAlong / 1000))
    }

    /// Everything Kit needs for a line: the quick picks to show now, and the ranked
    /// candidates for the model. Pure and nonisolated: call it from `Task.detached`.
    static func picks(along polyline: [Coord], mode: RideMode, profile: RiderProfile, start: Date = .now,
                      facts: [String: PlaceFacts] = Discovery.facts) -> (quick: [Sight], candidates: [KitCandidate]) {
        guard mode != .fast else { return ([], []) }
        // Same thinning as Discovery.sights, so offsets and lengths agree.
        let coords = Geo.sample(polyline.map(\.cl), count: 400)
        let cumulative = Geo.cumulative(coords)
        guard let length = cumulative.last, length > 0 else { return ([], []) }
        let all = Discovery.sights(along: polyline, mode: mode, start: start, facts: facts, limit: nil)
        let ranked = candidates(all, profile: profile, facts: facts)
        let quick = quickPicks(ranked, polyline: coords, cumulative: cumulative, count: targetCount(lengthMeters: length), facts: facts)
        return (quick, ranked)
    }

    /// Circles to steer round for "How I'm riding today": Keep it quiet avoids crowds
    /// (weekend crowds on Sat/Sun, evening crowds 17:00–22:00); With kids avoids crowds
    /// and dismount stretches. Visiting Singapore doesn't bend the route (plan 5).
    static func avoidCircles(for context: Set<RideContext>, at start: Date,
                             facts: [String: PlaceFacts] = Discovery.facts, places: [Sight] = Discovery.places) -> [NoGoCircle] {
        guard context.contains(.quiet) || context.contains(.kids) else { return [] }
        let c = Closures.sg.dateComponents([.weekday, .hour], from: start)
        let weekend = c.weekday == 1 || c.weekday == 7, evening = (17..<22).contains(c.hour ?? 0)
        var avoid: Set<String> = []
        if weekend { avoid.insert("crowded_weekend") }
        if evening { avoid.insert("crowded_evening") }
        if context.contains(.kids) { avoid.insert("dismount") }
        return places.compactMap { p in
            guard let reasons = p.osmID.flatMap({ facts[$0]?.note?.reasons }), !avoid.isDisjoint(with: reasons) else { return nil }
            return NoGoCircle(coord: Coord(lat: p.lat, lon: p.lon), radiusMeters: 150)
        }
    }

    private static func firstSentence(_ text: String) -> String? {
        let first = text.components(separatedBy: ". ").first ?? text
        let trimmed = first.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let reasonWords = [
        "park_and_walk": "walk your bike inside", "crowded_weekend": "busy at weekends",
        "crowded_evening": "busy in the evening", "dismount": "dismount here",
        "limited_food": "little food", "no_water": "no drinking water",
    ]

    private static func line(_ s: Sight, _ f: PlaceFacts?) -> String {
        let n = f?.note
        var facts: [String] = []
        if let d = n?.dishes, !d.isEmpty { facts.append("dishes: " + d.joined(separator: ", ")) }
        for stall in n?.stalls ?? [] {
            if let bib = stall.bib { facts.append("\(stall.name) (Bib Gourmand \(bib))") }
            else if let since = stall.since { facts.append("\(stall.name) (since \(since))") }
            else { facts.append(stall.name) }
        }
        if let t = n?.best_time { facts.append("best time: \(t)") }
        if let t = n?.note { facts.append(t) }
        facts += (n?.reasons ?? []).compactMap { reasonWords[$0] }
        if f?.wiki == true { facts.append("Wikipedia") }
        let fields = [s.osmID ?? s.id.uuidString, s.name, Discovery.icon(for: s.category).label,
                      "km " + String(format: "%.1f", s.offsetAlong / 1000), facts.isEmpty ? "none" : facts.joined(separator: "; ")]
        return fields.map { $0.replacingOccurrences(of: "|", with: "/") }.joined(separator: " | ")
    }
}

extension Kit {
    static func selfCheck() {
        let long = [Coord(lat: 1.30, lon: 103.80), Coord(lat: 1.30, lon: 103.8899)]   // 10 km west→east
        let line = long.map(\.cl), cum = Geo.cumulative(line), length = cum.last!
        func p(_ id: String, _ lon: Double, cat: String = "park", name: String? = nil) -> Sight {
            var s = Sight(name: name ?? id, category: cat, lat: 1.30, lon: lon); s.osmID = id
            s.offsetAlong = Geo.snap(s.coordinate, to: line, cumulative: cum)!.along
            return s
        }
        func facts(note: PlaceNote? = nil, wiki: Bool = false) -> PlaceFacts {
            PlaceFacts(hours: nil, area: 0, shape: [], wiki: wiki, note: note)
        }
        var foodNote = PlaceNote(); foodNote.persona = ["food"]

        // Score.
        let food = RiderProfile(likes: [.food])
        let hawker = p("h", 103.81, cat: "hawker"), park = p("k", 103.82), cafe = p("c", 103.83, cat: "cafe")
        let plain: [String: PlaceFacts] = ["h": facts(), "k": facts(), "c": facts()]
        assert(score(hawker, profile: food, facts: plain) > score(park, profile: food, facts: plain), "liked category wins")
        assert(score(hawker, profile: food, facts: ["h": facts(note: foodNote)])
               > score(hawker, profile: RiderProfile(likes: [.food]), facts: ["h": facts(note: PlaceNote())]),
               "persona tag beats category-only")
        let none = RiderProfile()
        assert(score(park, profile: none, facts: ["k": facts(note: PlaceNote())]) > score(park, profile: none, facts: ["k": facts(wiki: true)])
               && score(park, profile: none, facts: ["k": facts(wiki: true)]) > score(park, profile: none, facts: plain), "note > wiki > nothing")
        let learned = RiderProfile(weights: ["cafe": 1])
        assert(score(cafe, profile: learned, facts: plain) > score(park, profile: learned, facts: plain), "learned weight lifts cafés")
        assert(score(cafe, profile: RiderProfile(weights: ["cafe": 9]), facts: plain) == 2, "weights read clamped to +2")
        assert(score(cafe, profile: RiderProfile(weights: ["cafe": -9]), facts: plain) == -2, "weights read clamped to -2")

        // No interests: 30 cafés in the first km and a Wikipedia museum at km 9 -> museum kept, 3 in route order.
        let cafes = (0..<30).map { p("c\($0)", 103.80 + Double($0) * 0.0003, cat: "cafe") }
        let museum = p("m", 103.881, cat: "museum")
        var f2 = Dictionary(uniqueKeysWithValues: cafes.map { ($0.osmID!, facts()) }); f2["m"] = facts(wiki: true)
        let quick = quickPicks(candidates(cafes + [museum], profile: none, facts: f2), polyline: line, cumulative: cum, count: 3, facts: f2)
        assert(quick.count == 3 && quick.contains { $0.name == "m" }, "no interests: \(quick.map(\.name))")
        assert(quick.map(\.offsetAlong) == quick.map(\.offsetAlong).sorted(), "quick picks in route order")
        assert(quick.allSatisfy { $0.note?.isEmpty == false }, "every quick pick has a note")

        // Candidates: at most 40, best first, 5 fields starting with the OSM ID.
        let many = (0..<60).map { p("s\($0)", 103.80 + Double($0) * 0.001, cat: $0 == 59 ? "hawker" : "park") }
        let cs = candidates(many, profile: food, facts: [:])
        assert(cs.count == 40 && cs.first?.sight.osmID == "s59", "40 best first: \(cs.count) \(cs.first?.sight.osmID ?? "-")")
        assert(zip(cs, cs.dropFirst()).allSatisfy { $0.score >= $1.score }, "candidates sorted by score")
        assert(cs.allSatisfy { $0.line.components(separatedBy: " | ").count == 5 && $0.line.hasPrefix($0.sight.osmID! + " | ") }, "line shape: \(cs[0].line)")

        // Template notes.
        func at(_ km: Double, _ cat: String) -> Sight { var s = p("t", 103.80, cat: cat); s.offsetAlong = km * 1000; return s }
        var bib = PlaceNote(); bib.stalls = [.init(name: "Cheok Kee Duck Rice", bib: 2026, since: nil)]; bib.dishes = ["duck rice"]
        assert(templateNote(at(1.2, "hawker"), facts: facts(note: bib), lengthMeters: length) == "Cheok Kee Duck Rice, Bib Gourmand 2026 · km 1.2", "bib note")
        var dishes = PlaceNote(); dishes.dishes = ["satay", "BBQ chicken wings", "carrot cake"]
        assert(templateNote(at(1.2, "hawker"), facts: facts(note: dishes), lengthMeters: length) == "Try satay or BBQ chicken wings · km 1.2", "dishes note")
        assert(templateNote(at(1.2, "hawker"), facts: nil, lengthMeters: length) == "Hawker centre, local dishes · km 1.2", "bare hawker note")
        var otter = PlaceNote(); otter.note = "Resident otter family. Best at dawn."
        assert(templateNote(at(3.4, "park"), facts: facts(note: otter), lengthMeters: length) == "Resident otter family · km 3.4", "note sentence")
        assert(templateNote(at(5, "museum"), facts: nil, lengthMeters: length) == "Museum · km 5.0", "category label")
        assert(templateNote(at(8.5, "hawker"), facts: facts(note: dishes), lengthMeters: length) == "Try satay or BBQ chicken wings · good after the ride", "late hawker")

        // Counts.
        assert(targetCount(lengthMeters: 5_000) == 3 && targetCount(lengthMeters: 20_000) == 5 && targetCount(lengthMeters: 40_000) == 10, "target counts")

        // "How I'm riding today" -> avoid circles from the overlay's reasons, at the planned time.
        func tagged(_ id: String, _ lon: Double, _ reasons: [String]) -> (Sight, PlaceFacts) {
            var n = PlaceNote(); n.reasons = reasons
            return (p(id, lon), facts(note: n))
        }
        let tagged3 = [tagged("wk", 103.81, ["crowded_weekend"]), tagged("ev", 103.82, ["crowded_evening"]), tagged("dm", 103.83, ["dismount"])]
        let tPlaces = tagged3.map(\.0), tFacts = Dictionary(uniqueKeysWithValues: tagged3.map { ($0.0.osmID!, $0.1) })
        func at(_ day: Int, _ hour: Int) -> Date { Closures.sg.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))! }
        func circles(_ ctx: Set<RideContext>, _ date: Date) -> [String] {
            avoidCircles(for: ctx, at: date, facts: tFacts, places: tPlaces).map { c in
                assert(c.radiusMeters == 150, "150 m circles"); return tPlaces.first { $0.coordinate.latitude == c.coord.lat && $0.coordinate.longitude == c.coord.lon }!.osmID!
            }.sorted()
        }
        assert(circles([.quiet], at(28, 10)) == ["wk"], "quiet, Saturday 10:00: \(circles([.quiet], at(28, 10)))")
        let tue10 = Closures.sg.date(from: DateComponents(year: 2026, month: 12, day: 1, hour: 10))!
        let tue18 = Closures.sg.date(from: DateComponents(year: 2026, month: 12, day: 1, hour: 18))!
        assert(circles([.quiet], tue10).isEmpty, "quiet, Tuesday 10:00: none")
        assert(circles([.quiet], tue18) == ["ev"], "quiet, evening")
        assert(circles([.kids], at(28, 10)) == ["dm", "wk"], "kids: dismount and crowds: \(circles([.kids], at(28, 10)))")
        assert(circles([.kids], tue10) == ["dm"], "kids on a quiet weekday: dismount only")
        assert(circles([.visiting], at(28, 10)).isEmpty && circles([], at(28, 10)).isEmpty, "visiting / nothing: no circles")

        // Real data: East Coast Park, food lover -> a hawker centre among the picks. Fast -> nothing.
        let ecp = [Coord(lat: 1.2995, lon: 103.9000), Coord(lat: 1.3020, lon: 103.9150),
                   Coord(lat: 1.3069, lon: 103.9349), Coord(lat: 1.3110, lon: 103.9500)]
        let sat10 = Closures.sg.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: 10))!
        let real = picks(along: ecp, mode: .leisure, profile: food, start: sat10)
        assert(real.quick.contains { $0.category == "hawker" }, "ECP food picks: \(real.quick.map(\.name))")
        let fast = picks(along: ecp, mode: .fast, profile: food)
        assert(fast.quick.isEmpty && fast.candidates.isEmpty, "Fast gets no picks")
    }
}
