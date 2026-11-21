//
//  Discovery.swift
//  cyclingskibidi
//
//  Leisure sights and place search, both from the bundled places.json (named
//  OpenStreetMap places in Singapore, see scripts/places/build.py) — offline.
//

import SwiftUI
import MapKit

enum Discovery {
    /// Categories that count as a Leisure sight; stations and malls are for search only.
    static let leisureCategories: Set<String> = [
        "park", "nationalPark", "beach", "museum", "aquarium", "zoo", "amusementPark", "cafe",
        "marina", "stadium", "library", "attraction", "viewpoint", "hawker", "worship",
    ]

    /// Every bundled place, decoded once.
    static let places: [Sight] = {
        struct P: Decodable { let name, category: String; let lat, lon: Double; let address: String }
        guard let url = Bundle.main.url(forResource: "places", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([P].self, from: data) else { return [] }
        return list.map { Sight(name: $0.name, category: $0.category, lat: $0.lat, lon: $0.lon, address: $0.address) }
    }()

    /// Pure corridor filter: keep only candidates within `corridor` metres of the
    /// line, stamp each with how far along the route it sits, drop duplicates
    /// (same name at the same spot), and order by that distance.
    static func sightsAlong(_ candidates: [Sight], polyline: [CLLocationCoordinate2D],
                            cumulative: [Double], corridor: Double = 150) -> [Sight] {
        guard polyline.count >= 2 else { return [] }
        var kept: [Sight] = []
        var seen: Set<String> = []
        for var c in candidates {
            guard !c.name.isEmpty,
                  let s = Geo.snap(c.coordinate, to: polyline, cumulative: cumulative),
                  s.lateral <= corridor else { continue }
            let key = "\(c.name.lowercased())|\(Int(c.lat * 1000))|\(Int(c.lon * 1000))"
            guard seen.insert(key).inserted else { continue }
            c.offsetAlong = s.along
            kept.append(c)
        }
        return kept.sorted { $0.offsetAlong < $1.offsetAlong }
    }

    /// Leisure places within a corridor of the route line, first 20 along it.
    /// ponytail: 20 kept, ordered by offset; spread them along the route if long
    /// leisure rides end up with every sight in the first few km.
    static func sights(along polyline: [Coord], in places: [Sight] = Discovery.places) -> [Sight] {
        // A thinned line is plenty for a 150 m corridor and keeps the snap cheap.
        let coords = Geo.sample(polyline.map(\.cl), count: 400)
        guard coords.count >= 2, let box = box(coords, pad: 150) else { return [] }
        let candidates = places.filter { leisureCategories.contains($0.category) && box($0) }
        return Array(sightsAlong(candidates, polyline: coords, cumulative: Geo.cumulative(coords)).prefix(20))
    }

    /// Places whose name or category matches every word of `query`, nearest `center` first.
    /// `leisureOnly` limits it to sights (the taste panel); place search uses everything.
    static func search(_ query: String, near center: CLLocationCoordinate2D, within metres: Double = .infinity,
                       leisureOnly: Bool = false, in places: [Sight] = Discovery.places, limit: Int = 20) -> [Sight] {
        let words = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map { w in
            w.count > 3 && w.hasSuffix("s") ? String(w.dropLast()) : String(w)   // "temples" finds "temple"
        }
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        return places
            .filter { p in
                guard !leisureOnly || leisureCategories.contains(p.category) else { return false }
                let hay = fold(p.name + " " + icon(for: p.category).label + " " + keywords(p.category))
                return words.allSatisfy { hay.contains(fold($0)) }
            }
            .map { ($0, Geo.distance(center, $0.coordinate)) }
            .filter { $0.1 <= metres }
            .sorted { $0.1 < $1.1 }
            .prefix(limit).map(\.0)
    }

    /// Lat/lon box round a line, padded by `pad` metres.
    private static func box(_ line: [CLLocationCoordinate2D], pad: Double) -> ((Sight) -> Bool)? {
        guard let la0 = line.map(\.latitude).min(), let la1 = line.map(\.latitude).max(),
              let lo0 = line.map(\.longitude).min(), let lo1 = line.map(\.longitude).max() else { return nil }
        let p = pad / PCNGraph.metresPerDegree
        return { (la0 - p...la1 + p).contains($0.lat) && (lo0 - p...lo1 + p).contains($0.lon) }
    }

    /// Extra words a category answers to, beyond its label.
    private static func keywords(_ category: String) -> String {
        switch category {
        case "worship": return "temple church mosque"
        case "hawker":  return "food court"
        case "cafe":    return "coffee"
        case "station": return "mrt lrt"
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
        assert(icon(for: "MKPOICategoryPark").label == "Park", "old MapKit categories must still map")
        // Real data: the bundle knows Gardens by the Bay.
        assert(!search("gardens by the bay", near: line[0]).isEmpty, "Gardens by the Bay missing from places.json")
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
