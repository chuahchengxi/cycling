//
//  Discovery.swift
//  cyclingskibidi
//
//  Leisure sights and place search, both from the bundled places.json (named
//  OpenStreetMap places in Singapore, see scripts/places/build.py) — offline.
//

import SwiftUI
import MapKit

/// Our research note on a place (scripts/places/overlay.src.json), keyed by OSM ID.
/// Field names match the JSON.
nonisolated struct PlaceNote: Decodable, Sendable {
    var persona: [String]? = nil
    var reasons: [String]? = nil
    var status: String? = nil
    var valid_until: String? = nil
    var dishes: [String]? = nil
    var stalls: [Stall]? = nil
    var best_time: String? = nil
    var note: String? = nil
    var hours: [[Int]]? = nil            // our sourced hours, used when osm_hours_wrong
    var osm_hours_wrong: Bool? = nil     // true: ignore OSM's hours (ours, or unknown = open)
    var sources: [String]? = nil   // every URL is in reports/*.md; each fact is in one of them
    struct Stall: Decodable, Sendable { var name: String; var bib: Int?; var since: Int? }
}

/// What places.json and the overlay know about one place beyond its pin.
nonisolated struct PlaceFacts: Sendable {
    var hours: [[Int]]?     // [day 0=Mon, from, to] minutes; nil = no hours known, treat as open
    var area: Double        // m², 0 for points
    var shape: [Coord]      // outline or line points; [] for points
    var wiki: Bool
    var note: PlaceNote?

    var isLarge: Bool { area >= 10_000 }

    /// Open at `date`, Singapore time. Unknown hours count as open, so a format the
    /// build couldn't read never hides a place; a note marked closed wins through its
    /// inclusive `valid_until` (no date = closed until the data says otherwise).
    func isOpen(at date: Date) -> Bool {
        if note?.status == "closed" {
            guard let end = note?.valid_until.flatMap(Closures.day) else { return false }
            if date < Closures.sg.date(byAdding: .day, value: 1, to: end)! { return false }
        }
        guard let hours else { return true }
        let c = Closures.sg.dateComponents([.weekday, .hour, .minute], from: date)
        let day = (c.weekday! + 5) % 7, minute = c.hour! * 60 + c.minute!   // weekday 1 = Sunday
        return hours.contains { $0.count == 3 && $0[0] == day && $0[1] <= minute && minute < $0[2] }
    }
}

nonisolated enum Discovery {
    /// Categories that count as a Leisure sight; stations, malls and rest-stop amenities
    /// (toilets, water, shelters, bike repair/parking/rental) are for search and rest stops only.
    static let leisureCategories: Set<String> = [
        "park", "nationalPark", "beach", "museum", "aquarium", "zoo", "amusementPark", "cafe",
        "marina", "stadium", "library", "attraction", "viewpoint", "hawker", "worship",
        "bridge", "waterway", "reservoir", "heritage", "artwork", "playground",
    ]

    /// Every bundled place, decoded once: OSM places plus the overlay's hand-added ones.
    static var places: [Sight] { bundle.places }
    /// Hours, size, outline and our research note per place, keyed by `Sight.osmID`.
    static var facts: [String: PlaceFacts] { bundle.facts }

    private static let bundle: (places: [Sight], facts: [String: PlaceFacts]) = {
        struct P: Decodable {
            let id: String?; let name, category: String; let lat, lon: Double; let address: String?
            let hours: [[Int]]?; let wiki: Bool?; let area: Double?; let shape: [[Double]]?
        }
        struct Hand: Decodable { let name, category: String?; let lat, lon: Double? }
        func load<T: Decodable>(_ name: String, as: T.Type) -> T? {
            guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
        let notes = load("places_overlay", as: [String: PlaceNote].self) ?? [:]
        var places: [Sight] = [], facts: [String: PlaceFacts] = [:]
        for p in load("places", as: [P].self) ?? [] {
            var s = Sight(name: p.name, category: p.category, lat: p.lat, lon: p.lon, address: p.address ?? "")
            s.osmID = p.id
            places.append(s)
            guard let id = p.id else { continue }
            let note = notes[id]
            facts[id] = PlaceFacts(hours: note?.osm_hours_wrong == true ? note?.hours : p.hours, area: p.area ?? 0,
                                   shape: (p.shape ?? []).compactMap { $0.count == 2 ? Coord(lat: $0[0], lon: $0[1]) : nil },
                                   wiki: p.wiki ?? false, note: note)
        }
        // Hand-added overlay places (keys "x-…") carry their own sourced coordinate.
        for (id, h) in load("places_overlay", as: [String: Hand].self) ?? [:] where id.hasPrefix("x-") {
            guard let name = h.name, let category = h.category, let lat = h.lat, let lon = h.lon else { continue }
            var s = Sight(name: name, category: category, lat: lat, lon: lon)
            s.osmID = id
            places.append(s)
            facts[id] = PlaceFacts(hours: nil, area: 0, shape: [], wiki: false, note: notes[id])
        }
        return (places, facts)
    }()

    /// A place counts as on the route within this many metres of the line,
    /// measured to its nearest point (pin or outline). Spec values.
    static let smallCorridor: Double = 100
    static let largeCorridor: Double = 300

    /// Pure corridor filter: keep candidates whose nearest point is within the
    /// corridor (300 m for large places, 100 m otherwise), stamp each with how far
    /// along the route that point sits, drop duplicates (same name at the same
    /// spot), and order by that distance.
    static func sightsAlong(_ candidates: [Sight], polyline: [CLLocationCoordinate2D], cumulative: [Double],
                            facts: [String: PlaceFacts] = Discovery.facts, small: Double = smallCorridor) -> [Sight] {
        guard polyline.count >= 2 else { return [] }
        var kept: [Sight] = []
        var seen: Set<String> = []
        for var c in candidates {
            guard !c.name.isEmpty else { continue }
            let f = c.osmID.flatMap { facts[$0] }
            let corridor = f?.isLarge == true ? max(largeCorridor, small) : small
            let points = [c.coordinate] + (f?.shape ?? []).map(\.cl)
            guard let s = points.compactMap({ Geo.snap($0, to: polyline, cumulative: cumulative) }).min(by: { $0.lateral < $1.lateral }),
                  s.lateral <= corridor else { continue }
            let key = "\(c.name.lowercased())|\(Int(c.lat * 1000))|\(Int(c.lon * 1000))"
            guard seen.insert(key).inserted else { continue }
            c.offsetAlong = s.along
            kept.append(c)
        }
        return kept.sorted { $0.offsetAlong < $1.offsetAlong }
    }

    /// Leisure places a rider on this line really passes: near it (see `sightsAlong`),
    /// open when they get there at the mode's planning speed from `start`, not inside an
    /// active closure, not inside a no-cycling zone unless it's a park-and-walk place,
    /// and at most `limit` of them spread along the whole route (nil: every one, for Kit to rank).
    /// `closed`/`walk` nil = the bundled closures active at `start`.
    static func sights(along polyline: [Coord], mode: RideMode = .leisure, start: Date = .now,
                       in places: [Sight] = Discovery.places, facts: [String: PlaceFacts] = Discovery.facts,
                       closed: [NoGoCircle]? = nil, walk: [NoGoCircle]? = nil, limit: Int? = 20) -> [Sight] {
        // A thinned line is plenty for a 100-300 m corridor and keeps the snap cheap.
        let coords = Geo.sample(polyline.map(\.cl), count: 400)
        guard coords.count >= 2, let inBox = box(coords, pad: largeCorridor) else { return [] }
        let active: (closed: [NoGoCircle], walk: [NoGoCircle]) = closed == nil || walk == nil ? Closures.activeCircles(on: start) : ([], [])
        let closed = closed ?? active.closed, walk = walk ?? active.walk
        let candidates = places.filter { p in
            // An unnamed playground is named "Playground" at build: fine to search, too vague to visit.
            // (It's the only leisure category that gets a made-up name; see scripts/places/build.py NAMELESS.)
            leisureCategories.contains(p.category) && !(p.category == "playground" && p.name == "Playground")
                && (inBox(p.coordinate) || (p.osmID.flatMap { facts[$0] }?.shape.contains { inBox($0.cl) } ?? false))
        }
        let cumulative = Geo.cumulative(coords)
        let metresPerSecond = mode.planningSpeedKmh / 3.6
        func inside(_ c: CLLocationCoordinate2D, _ circles: [NoGoCircle]) -> Bool {
            circles.contains { Geo.distance(c, $0.coord.cl) <= $0.radiusMeters }
        }
        let kept = sightsAlong(candidates, polyline: coords, cumulative: cumulative, facts: facts).filter { s in
            let f = s.osmID.flatMap { facts[$0] }
            if let f, !f.isOpen(at: start.addingTimeInterval(s.offsetAlong / metresPerSecond)) { return false }
            if inside(s.coordinate, closed) { return false }
            if inside(s.coordinate, walk), f?.note?.reasons?.contains("park_and_walk") != true { return false }
            return true
        }
        let one = onePerPlace(kept, polyline: coords, cumulative: cumulative, facts: facts)
        guard let limit else { return one }
        return spread(one, polyline: coords, cumulative: cumulative, limit: limit) { Double(notability($0, facts)) }
    }

    /// A research note 2, Wikipedia 1, else 0: how much a sight is worth a slot.
    static func notability(_ s: Sight, _ facts: [String: PlaceFacts]) -> Int {
        let f = s.osmID.flatMap { facts[$0] }
        return f?.note != nil ? 2 : f?.wiki == true ? 1 : 0
    }

    /// One sight per place: a park and its zones ("East Coast Park (Zone B)", "… Zone C")
    /// or same-named pieces of one river share a name once the zone is cut off. Keeps the
    /// most notable, then the one nearest the line; route order is kept.
    static func onePerPlace(_ sights: [Sight], polyline: [CLLocationCoordinate2D], cumulative: [Double],
                            facts: [String: PlaceFacts]) -> [Sight] {
        func base(_ name: String) -> String {
            name.lowercased()
                .replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+zone\s+\w+$"#, with: "", options: .regularExpression)
        }
        func lateral(_ s: Sight) -> Double { Geo.snap(s.coordinate, to: polyline, cumulative: cumulative)?.lateral ?? .infinity }
        var best: [String: Sight] = [:]
        for s in sights {
            let k = base(s.name)
            guard let b = best[k] else { best[k] = s; continue }
            if (notability(s, facts), -lateral(s)) > (notability(b, facts), -lateral(b)) { best[k] = s }
        }
        return best.values.sorted { $0.offsetAlong < $1.offsetAlong }
    }

    /// At most `limit` sights, spread along the line: the route is cut into `limit`
    /// equal stretches and each gives its best-scoring sight (ties to the one nearer
    /// the line); slots left over go to the best of the rest. Returned in route order.
    static func spread(_ sights: [Sight], polyline: [CLLocationCoordinate2D], cumulative: [Double],
                       limit: Int, score: (Sight) -> Double) -> [Sight] {
        guard limit > 0 else { return [] }
        guard sights.count > limit, let length = cumulative.last, length > 0 else { return sights }
        let scores = sights.map(score)
        let lateral = sights.map { Geo.snap($0.coordinate, to: polyline, cumulative: cumulative)?.lateral ?? .infinity }
        let ranked = sights.indices.sorted { (scores[$0], -lateral[$0]) > (scores[$1], -lateral[$1]) }
        var picked: [Int] = [], used = Set<Int>()
        for i in ranked {
            let bin = min(limit - 1, Int(sights[i].offsetAlong / (length / Double(limit))))
            if used.insert(bin).inserted { picked.append(i) }
        }
        for i in ranked where picked.count < limit && !picked.contains(i) { picked.append(i) }
        return picked.map { sights[$0] }.sorted { $0.offsetAlong < $1.offsetAlong }
    }

    /// Places whose name or category matches every word of `query`, nearest `center` first.
    /// `leisureOnly` limits it to sights (the taste panel); place search uses everything.
    static func search(_ query: String, near center: CLLocationCoordinate2D, within metres: Double = .infinity,
                       leisureOnly: Bool = false, in places: [Sight] = Discovery.places, limit: Int = 20) -> [Sight] {
        let words = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map { w in
            w.count > 3 && w.hasSuffix("s") ? String(w.dropLast()) : String(w)   // "temples" finds "temple"
        }
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let folded = words.map(fold)
        return places
            .compactMap { p -> (Sight, Bool, Double)? in
                guard !leisureOnly || leisureCategories.contains(p.category) else { return nil }
                let hay = fold(p.name + " " + icon(for: p.category).label + " " + keywords(p.category))
                guard folded.allSatisfy(hay.contains) else { return nil }
                // Whole words rank first, so "park" isn't buried under "Bike parking".
                let hayWords = Set(hay.split { !$0.isLetter && !$0.isNumber }.map { w in
                    w.count > 3 && w.hasSuffix("s") ? String(w.dropLast()) : String(w) })
                return (p, folded.allSatisfy(hayWords.contains), Geo.distance(center, p.coordinate))
            }
            .filter { $0.2 <= metres }
            .sorted { ($0.1 ? 0 : 1, $0.2) < ($1.1 ? 0 : 1, $1.2) }
            .prefix(limit).map(\.0)
    }

    /// Lat/lon box round a line, padded by `pad` metres.
    private static func box(_ line: [CLLocationCoordinate2D], pad: Double) -> ((CLLocationCoordinate2D) -> Bool)? {
        guard let la0 = line.map(\.latitude).min(), let la1 = line.map(\.latitude).max(),
              let lo0 = line.map(\.longitude).min(), let lo1 = line.map(\.longitude).max() else { return nil }
        let p = pad / PCNGraph.metresPerDegree
        return { (la0 - p...la1 + p).contains($0.latitude) && (lo0 - p...lo1 + p).contains($0.longitude) }
    }

    /// Extra words a category answers to, beyond its label.
    private static func keywords(_ category: String) -> String {
        switch category {
        case "worship": return "temple church mosque"
        case "hawker":  return "food court"
        case "cafe":    return "coffee"
        case "station": return "mrt lrt"
        case "toilets": return "toilet restroom loo"
        case "drinkingWater": return "water tap fountain"
        case "shelter": return "shade rain"
        case "repair": return "pump"
        case "bikeRental": return "hire rent"
        case "heritage": return "historic monument"
        default:        return ""
        }
    }

    /// A display symbol and label for a stored category (places.json, or an old MapKit rawValue).
    static func icon(for category: String) -> (symbol: String, label: String) {
        var key = category
        if key.hasPrefix("MKPOICategory") { key = String(key.dropFirst(13)); key = key.prefix(1).lowercased() + key.dropFirst() }
        switch key {
        case "park", "nationalPark": return ("tree.fill", "Park")
        case "beach":               return ("beach.umbrella.fill", "Beach")
        case "museum":              return ("building.columns.fill", "Museum")
        case "aquarium":            return ("fish.fill", "Aquarium")
        case "zoo":                 return ("pawprint.fill", "Zoo")
        case "amusementPark":       return ("sparkles", "Amusement park")
        case "cafe":                return ("cup.and.saucer.fill", "Café")
        case "restaurant":          return ("fork.knife", "Restaurant")
        case "hawker":              return ("fork.knife", "Hawker centre")
        case "marina":              return ("sailboat.fill", "Marina")
        case "stadium":             return ("sportscourt.fill", "Stadium")
        case "library":             return ("books.vertical.fill", "Library")
        case "attraction":          return ("star.fill", "Attraction")
        case "viewpoint":           return ("binoculars.fill", "Viewpoint")
        case "worship":             return ("building.fill", "Place of worship")
        case "station":             return ("tram.fill", "Station")
        case "mall":                return ("bag.fill", "Mall")
        case "bridge":              return ("road.lanes", "Bridge")
        case "waterway":            return ("water.waves", "River or canal")
        case "reservoir":           return ("water.waves", "Reservoir")
        case "heritage":            return ("scroll.fill", "Heritage")
        case "artwork":             return ("paintpalette.fill", "Public art")
        case "playground":          return ("figure.play", "Playground")
        case "toilets":             return ("toilet.fill", "Toilets")
        case "drinkingWater":       return ("drop.fill", "Drinking water")
        case "shelter":             return ("umbrella.fill", "Shelter")
        case "repair":              return ("wrench.and.screwdriver.fill", "Bike repair station")
        case "bikeParking":         return ("parkingsign", "Bike parking")
        case "bikeRental":          return ("bicycle", "Bike rental")
        default:                    return ("mappin.and.ellipse", "Point of interest")
        }
    }

    static func selfCheck() {
        assert(places.count > 1000, "places.json missing from the bundle: \(places.count)")
        // Corridor filter: a short west→east line; a point ~90 m off it is kept
        // and stamped with its offset, one ~2 km off is dropped, and a duplicate
        // at the same spot collapses.
        let line = [CLLocationCoordinate2D(latitude: 1.30, longitude: 103.80),
                    CLLocationCoordinate2D(latitude: 1.30, longitude: 103.81)]
        let cum = Geo.cumulative(line)
        let near = Sight(name: "Park", category: "park", lat: 1.3008, lon: 103.805)
        let far  = Sight(name: "Mall", category: "park", lat: 1.320, lon: 103.805)
        let dupe = Sight(name: "Park", category: "park", lat: 1.3008, lon: 103.805)
        let out = sightsAlong([far, near, dupe], polyline: line, cumulative: cum)
        assert(out.count == 1, "far dropped, dup collapsed: \(out.count)")
        assert(out.first?.name == "Park", "kept the near one")
        assert(out.first.map { $0.offsetAlong > 0 } == true, "offset stamped from the line")
        // Corridor sweep over a given list: only leisure categories near the line.
        let station = Sight(name: "Somewhere MRT", category: "station", lat: 1.3002, lon: 103.805)
        let found = sights(along: line.map { Coord($0) }, in: [far, near, station])
        assert(found.map(\.name) == ["Park"], "sweep must keep near leisure places only: \(found.map(\.name))")
        // Search: every word must match, plurals and keywords count, nearest first.
        let temple = Sight(name: "Thian Hock Keng", category: "worship", lat: 1.281, lon: 103.847)
        let cafe = Sight(name: "Café Kopi", category: "cafe", lat: 1.30, lon: 103.80)
        let hits = search("temples", near: line[0], in: [temple, cafe, station])
        assert(hits.map(\.name) == ["Thian Hock Keng"], "keyword search wrong: \(hits.map(\.name))")
        assert(search("cafe kopi", near: line[0], in: [temple, cafe]).first?.name == "Café Kopi", "diacritics must fold")
        assert(search("mrt", near: line[0], leisureOnly: true, in: [station]).isEmpty, "stations aren't sights")
        // Whole-word hits first: "park" puts a park 2 km away before bike parking next door; "parki" still finds it.
        let rack = Sight(name: "Bike parking", category: "bikeParking", lat: 1.30, lon: 103.8001)
        let farPark = Sight(name: "Telok Kurau Park", category: "park", lat: 1.31, lon: 103.81)
        assert(search("park", near: line[0], in: [rack, farPark]).map(\.name) == ["Telok Kurau Park", "Bike parking"], "whole words first")
        assert(search("parki", near: line[0], in: [rack, farPark]).map(\.name) == ["Bike parking"], "prefix typing still works")
        assert(icon(for: "MKPOICategoryPark").label == "Park", "old MapKit categories must still map")
        // Real data: the bundle knows Gardens by the Bay.
        assert(!search("gardens by the bay", near: line[0]).isEmpty, "Gardens by the Bay missing from places.json")

        // Old saves (no osmID) still decode.
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Park","category":"park","lat":1.3,"lon":103.8,"offsetAlong":0,"address":"","phone":"","url":""}"#
        let decoded = try? JSONDecoder().decode(Sight.self, from: Data(old.utf8))
        assert(decoded != nil && decoded?.osmID == nil, "old Sight must decode")
        // Hours: Monday 10:00 SGT open for Mo-Fr 08:00-20:00, closed at 21:00; past-midnight span open at 01:00 Tuesday.
        let mon10 = Closures.sg.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 10))!
        let f = PlaceFacts(hours: [[0, 480, 1200]], area: 0, shape: [], wiki: false, note: nil)
        assert(f.isOpen(at: mon10) && !f.isOpen(at: mon10.addingTimeInterval(11 * 3600)), "Mo 08-20 wrong")
        let late = PlaceFacts(hours: [[0, 1080, 1440], [1, 0, 120]], area: 0, shape: [], wiki: false, note: nil)
        assert(late.isOpen(at: mon10.addingTimeInterval(15 * 3600)), "18:00-02:00 must be open at 01:00 Tuesday")
        assert(PlaceFacts(hours: nil, area: 0, shape: [], wiki: false, note: nil).isOpen(at: mon10), "no hours = open")
        // Overlay closure, inclusive end date.
        var shut = PlaceNote(); shut.status = "closed"; shut.valid_until = "2026-11-23"
        assert(!PlaceFacts(hours: nil, area: 0, shape: [], wiki: false, note: shut).isOpen(at: mon10), "closed through its end day")
        assert(PlaceFacts(hours: nil, area: 0, shape: [], wiki: false, note: shut).isOpen(at: mon10.addingTimeInterval(86_400)), "open after it")
        // Real data.
        assert(places.contains { $0.category == "toilets" } && places.contains { $0.category == "drinkingWater" }, "rest-stop amenities missing")
        assert(facts.values.contains { $0.note?.dishes?.isEmpty == false }, "overlay missing or not joined")
        assert(facts.values.allSatisfy { $0.note == nil || $0.note?.sources?.isEmpty == false }, "every note must carry its sources")
        assert(!search("toilets", near: line[0]).isEmpty, "amenities must be searchable")
        // A note's sourced hours beat OSM's: Masjid Sultan is closed Fridays; Gardens by the Bay's OSM
        // 09:00-21:00 (the conservatories) must not hide the gardens at 06:00. 2026-11-27 is a Friday.
        let fri15 = Closures.sg.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 15))!
        let fri06 = Closures.sg.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 6))!
        func real(_ name: String) -> [PlaceFacts] { places.filter { $0.name == name }.compactMap { $0.osmID.flatMap { facts[$0] } } }
        assert(!real("Masjid Sultan").isEmpty && real("Masjid Sultan").allSatisfy { !$0.isOpen(at: fri15) }, "Masjid Sultan closed Fridays")
        assert(!real("Gardens by the Bay").isEmpty && real("Gardens by the Bay").allSatisfy { $0.isOpen(at: fri06) }, "Gardens by the Bay hidden at 06:00")

        // Places a rider really passes. 10 km west→east line at lat 1.30.
        let long = [Coord(lat: 1.30, lon: 103.80), Coord(lat: 1.30, lon: 103.8899)]
        func p(_ id: String, _ lon: Double, _ dLat: Double = 0, cat: String = "park") -> Sight {
            var s = Sight(name: id, category: cat, lat: 1.30 + dLat, lon: lon); s.osmID = id; return s
        }
        let none = PlaceFacts(hours: nil, area: 0, shape: [], wiki: false, note: nil)
        // Proximity: 90 m off kept, 200 m off dropped, a large park whose centre is 500 m off but whose edge touches the line kept.
        let big = PlaceFacts(hours: nil, area: 50_000, shape: [Coord(lat: 1.30, lon: 103.85)], wiki: false, note: nil)
        let near2 = sights(along: long, in: [p("a", 103.81, 0.0008), p("b", 103.82, 0.0018), p("c", 103.85, 0.0045)],
                           facts: ["a": none, "b": none, "c": big], closed: [], walk: [])
        assert(near2.map(\.name) == ["a", "c"], "proximity: \(near2.map(\.name))")
        // Closed when passed: hours Mon 08-09 only, ridden Monday 10:00 -> dropped.
        let early = PlaceFacts(hours: [[0, 480, 540]], area: 0, shape: [], wiki: false, note: nil)
        assert(sights(along: long, start: mon10, in: [p("h", 103.81)], facts: ["h": early], closed: [], walk: []).isEmpty,
               "closed at pass time kept")
        // No-cycling zone: dropped unless park_and_walk.
        let zone = [NoGoCircle(coord: Coord(lat: 1.30, lon: 103.81), radiusMeters: 50)]
        var walkNote = PlaceNote(); walkNote.reasons = ["park_and_walk"]
        let walked = sights(along: long, in: [p("z", 103.81), p("w", 103.8101)],
                            facts: ["z": none, "w": PlaceFacts(hours: nil, area: 0, shape: [], wiki: false, note: walkNote)],
                            closed: [], walk: zone)
        assert(walked.map(\.name) == ["w"], "no-cycling rule: \(walked.map(\.name))")
        // Inside an active closure: always dropped.
        assert(sights(along: long, in: [p("x", 103.81)], facts: ["x": none], closed: zone, walk: []).isEmpty, "closure kept")
        // Spread: 30 places in the first km plus one at km 9; limit 5 -> the km-9 one survives, 5 total, in order.
        let bunch = (0..<30).map { p("s\($0)", 103.80 + Double($0) * 0.0003) } + [p("end", 103.881)]
        let spread = sights(along: long, in: bunch, facts: Dictionary(uniqueKeysWithValues: bunch.map { ($0.osmID!, none) }),
                            closed: [], walk: [], limit: 5)
        assert(spread.count == 5 && spread.last?.name == "end", "spread: \(spread.map(\.name))")
        assert(spread.map(\.offsetAlong) == spread.map(\.offsetAlong).sorted(), "spread must stay in route order")
        assert(sights(along: long, in: bunch, facts: [:], closed: [], walk: [], limit: 0).isEmpty, "limit 0 means none")
        // An unnamed playground ("Playground", the label it was given at build) is not a sight; a named one is.
        let unnamed = sights(along: long, in: [p("Playground", 103.81, cat: "playground"), p("Kidztopia", 103.82, cat: "playground")],
                             facts: [:], closed: [], walk: [])
        assert(unnamed.map(\.name) == ["Kidztopia"], "unnamed places must not be sights: \(unnamed.map(\.name))")
        // One place, one slot: a park and its zones (or same-named pieces) count once, the most notable kept.
        var zoned = [p("East Coast Park (Zone B)", 103.81), p("East Coast Park", 103.83), p("East Coast Park Zone C", 103.85), p("Pelton Canal", 103.86), p("Pelton Canal", 103.87)]
        zoned[1].osmID = "ecp"
        let once = sights(along: long, in: zoned,
                          facts: ["East Coast Park (Zone B)": none, "ecp": PlaceFacts(hours: nil, area: 0, shape: [], wiki: true, note: nil),
                                  "East Coast Park Zone C": none, "Pelton Canal": none], closed: [], walk: [])
        assert(once.map(\.name) == ["East Coast Park", "Pelton Canal"], "one slot per place: \(once.map(\.name))")
        // Off the main thread: the whole sweep runs from a detached task (compiles = it's nonisolated).
        Task.detached { _ = Discovery.sights(along: long, in: [], facts: [:], closed: [], walk: []) }
    }
}

struct DiscoveryPanel: View {
    let region: MKCoordinateRegion
    let onPick: (CLLocationCoordinate2D) -> Void

    @AppStorage("leisureTastes") private var tastes = ""
    @State private var results: [Sight] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "leaf.fill").foregroundStyle(.green)
                TextField("What do you feel like? (hawker, temples…)", text: $tastes)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                Button(action: search) { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel("Search places")
            }
            if !results.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(results) { place in
                            Button {
                                onPick(place.coordinate)
                            } label: {
                                Text(place.name)
                                    .font(.footnote.weight(.medium))
                                    .lineLimit(1)
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(.quaternary, in: .capsule)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .onAppear(perform: search)   // auto-search on first show
    }

    /// Leisure places on screen, matching the tastes typed (all of them when blank).
    private func search() {
        let radius = max(region.span.latitudeDelta, region.span.longitudeDelta) * PCNGraph.metresPerDegree / 2
        results = Discovery.search(tastes, near: region.center, within: max(radius, 1000), leisureOnly: true)
    }
}

/// A sight's map pin: the category glyph on a green disc, mirroring ObstacleBadge.
struct SightBadge: View {
    let sight: Sight

    var body: some View {
        Image(systemName: Discovery.icon(for: sight.category).symbol)
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(6)
            .background(.green, in: .circle)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .shadow(radius: 2)
    }
}

/// The "what it's about" content, all from the bundled data: the category, the
/// address, and a call button when a number is known. Shared by the pre-ride
/// list sheet and the pass-by card.
struct SightDetail: View {
    let sight: Sight

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            let icon = Discovery.icon(for: sight.category)
            Label(icon.label, systemImage: icon.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if !sight.address.isEmpty {
                Text(sight.address).font(.body)
            }
            if let tel = telURL {
                Link(destination: tel) { Label("Call", systemImage: "phone") }
                    .font(.subheadline)
                    .buttonStyle(.bordered)
            }
        }
    }

    private var telURL: URL? {
        let digits = sight.phone.filter { $0.isNumber || $0 == "+" }
        return digits.isEmpty ? nil : URL(string: "tel://\(digits)")
    }
}

/// The pre-ride presentation: SightDetail as its own sheet with a title.
struct SightSheet: View {
    let sight: Sight
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                SightDetail(sight: sight).padding(20)
            }
            .navigationTitle(sight.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
