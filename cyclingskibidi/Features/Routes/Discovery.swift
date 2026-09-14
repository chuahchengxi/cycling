//
//  Discovery.swift
//  cyclingskibidi
//
//  Leisure landmark discovery: Apple Maps POI around the map, filtered to
//  interesting categories, plus a free-text taste query. Pure query building is
//  separated from the view so it can be self-checked without the network.
//

import SwiftUI
import MapKit

enum Discovery {
    static let leisureCategories: [MKPointOfInterestCategory] = [
        .park, .nationalPark, .beach, .museum, .aquarium, .zoo, .amusementPark,
        .cafe, .restaurant, .marina, .stadium, .library,
    ]

    /// A local-search request bounded to the visible region, for the user's
    /// typed taste query. MKLocalSearch.Request is a text-search API: it ANDs
    /// `naturalLanguageQuery` against the filter, so this only makes sense once
    /// there's real text to match against POI names.
    static func request(tastes: String, in region: MKCoordinateRegion) -> MKLocalSearch.Request {
        let trimmed = tastes.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = MKLocalSearch.Request()
        request.region = region
        request.resultTypes = .pointOfInterest
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: leisureCategories)
        request.naturalLanguageQuery = trimmed.isEmpty ? nil : trimmed
        return request
    }

    /// A points-of-interest request bounded to the region, for the automatic
    /// corridor sweep (no typed text). MKLocalSearch.Request has no "browse by
    /// category" mode — leaving `naturalLanguageQuery` nil doesn't relax it to
    /// filter-only, it just has nothing to match and returns zero results every
    /// time. MKLocalPointsOfInterestRequest is the separate API Apple built for
    /// exactly this: region + category filter, no query text.
    static func pointsOfInterestRequest(in region: MKCoordinateRegion) -> MKLocalPointsOfInterestRequest {
        let request = MKLocalPointsOfInterestRequest(coordinateRegion: region)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: leisureCategories)
        return request
    }

    /// Pure corridor filter: keep only candidates within `corridor` metres of the
    /// line, stamp each with how far along the route it sits, drop duplicates
    /// (same name at the same spot), and order by that distance. Split out from
    /// the network so it can be self-checked.
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

    /// Leisure POIs within a corridor of the route line. Samples the line into a
    /// few regions, runs the leisure search in each, and keeps what lands near
    /// the line. Network; call off the main actor.
    /// ponytail: ~6 sample regions, ~20 sights kept. Raise if long leisure
    /// routes come back sparse.
    static func sights(along polyline: [Coord]) async -> [Sight] {
        let coords = polyline.map(\.cl)
        guard coords.count >= 2 else { return [] }
        let cumulative = Geo.cumulative(coords)
        let total = cumulative.last ?? 0
        guard total > 0 else { return [] }

        let samples = min(6, max(2, Int(total / 2000) + 1))
        var candidates: [Sight] = []
        for i in 0..<samples {
            let along = total * Double(i) / Double(samples - 1)
            guard let center = Geo.point(at: along, on: coords, cumulative: cumulative) else { continue }
            let region = MKCoordinateRegion(center: center, latitudinalMeters: 2500, longitudinalMeters: 2500)
            guard let items = try? await MKLocalSearch(request: pointsOfInterestRequest(in: region)).start().mapItems
            else { continue }
            for item in items {
                candidates.append(Sight(
                    name: item.name ?? "",
                    category: item.pointOfInterestCategory?.rawValue ?? "",
                    lat: item.location.coordinate.latitude,
                    lon: item.location.coordinate.longitude,
                    address: item.address?.fullAddress ?? "",
                    phone: item.phoneNumber ?? "",
                    url: item.url?.absoluteString ?? ""))
            }
        }
        return Array(sightsAlong(candidates, polyline: coords, cumulative: cumulative).prefix(20))
    }

    /// A display symbol and label for a stored category rawValue.
    static func icon(for category: String) -> (symbol: String, label: String) {
        switch category.isEmpty ? nil : MKPointOfInterestCategory(rawValue: category) {
        case .park, .nationalPark: return ("tree.fill", "Park")
        case .beach:               return ("beach.umbrella.fill", "Beach")
        case .museum:              return ("building.columns.fill", "Museum")
        case .aquarium:            return ("fish.fill", "Aquarium")
        case .zoo:                 return ("pawprint.fill", "Zoo")
        case .amusementPark:       return ("sparkles", "Amusement park")
        case .cafe:                return ("cup.and.saucer.fill", "Café")
        case .restaurant:          return ("fork.knife", "Restaurant")
        case .marina:              return ("sailboat.fill", "Marina")
        case .stadium:             return ("sportscourt.fill", "Stadium")
        case .library:             return ("books.vertical.fill", "Library")
        default:                   return ("mappin.and.ellipse", "Point of interest")
        }
    }

    static func selfCheck() {
        let region = MKCoordinateRegion(center: .init(latitude: 1.30, longitude: 103.80),
                                        latitudinalMeters: 2000, longitudinalMeters: 2000)
        let typed = request(tastes: "  hawker, temples ", in: region)
        assert(typed.naturalLanguageQuery == "hawker, temples", "tastes should be trimmed, not blanked")
        let empty = request(tastes: "   ", in: region)
        assert(empty.naturalLanguageQuery == nil, "empty tastes must not set a query MapKit will AND against the filter")
        assert(empty.resultTypes == .pointOfInterest)

        // Automatic corridor sweep: MKLocalPointsOfInterestRequest, not
        // MKLocalSearch.Request — the latter has no query-free browse mode, it
        // just returns nothing when naturalLanguageQuery is nil.
        let poi = pointsOfInterestRequest(in: region)
        assert(poi.pointOfInterestFilter == MKPointOfInterestFilter(including: leisureCategories),
               "corridor sweep still relies on the leisure category filter")
        assert(abs(poi.coordinate.latitude - region.center.latitude) < 0.0001,
               "sweep request centered on the sample region")

        // Corridor filter: a short west→east line; a point ~90 m off it is kept
        // and stamped with its offset, one ~2 km off is dropped, and a duplicate
        // at the same spot collapses.
        let line = [CLLocationCoordinate2D(latitude: 1.30, longitude: 103.80),
                    CLLocationCoordinate2D(latitude: 1.30, longitude: 103.81)]
        let cum = Geo.cumulative(line)
        let near = Sight(name: "Park", lat: 1.3008, lon: 103.805)
        let far  = Sight(name: "Mall", lat: 1.320, lon: 103.805)
        let dupe = Sight(name: "Park", lat: 1.3008, lon: 103.805)
        let out = sightsAlong([far, near, dupe], polyline: line, cumulative: cum)
        assert(out.count == 1, "far dropped, dup collapsed: \(out.count)")
        assert(out.first?.name == "Park", "kept the near one")
        assert(out.first.map { $0.offsetAlong > 0 } == true, "offset stamped from the line")
    }
}

struct DiscoveryPanel: View {
    let region: MKCoordinateRegion
    let onPick: (CLLocationCoordinate2D) -> Void

    @AppStorage("leisureTastes") private var tastes = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "leaf.fill").foregroundStyle(.green)
                TextField("What do you feel like? (hawker, temples…)", text: $tastes)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search() } }
                Button { Task { await search() } } label: { Image(systemName: "magnifyingglass") }
            }
            if searching {
                ProgressView().frame(maxWidth: .infinity)
            } else if !results.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(results, id: \.self) { item in
                            Button {
                                onPick(item.location.coordinate)
                            } label: {
                                Text(item.name ?? "Place")
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
        .task { await search() }   // auto-search on first show
    }

    private func search() async {
        searching = true
        defer { searching = false }
        let response = try? await MKLocalSearch(request: Discovery.request(tastes: tastes, in: region)).start()
        results = response?.mapItems ?? []
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

/// The "what it's about" content, from MapKit only: a Look Around preview when
/// one exists, the category, the address, and quick actions. Shared by the
/// pre-ride list sheet and the pass-by card.
struct SightDetail: View {
    let sight: Sight
    @State private var scene: MKLookAroundScene?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let scene {
                LookAroundPreview(initialScene: scene)
                    .frame(height: 180)
                    .clipShape(.rect(cornerRadius: 16))
            }
            let icon = Discovery.icon(for: sight.category)
            Label(icon.label, systemImage: icon.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if !sight.address.isEmpty {
                Text(sight.address).font(.body)
            }
            HStack(spacing: 10) {
                if let url = URL(string: sight.url), !sight.url.isEmpty {
                    Link(destination: url) { Label("Website", systemImage: "safari") }
                }
                if let tel = telURL {
                    Link(destination: tel) { Label("Call", systemImage: "phone") }
                }
                Button { openInMaps() } label: { Label("Maps", systemImage: "map") }
            }
            .font(.subheadline)
            .buttonStyle(.bordered)
        }
        .task(id: sight.id) {
            scene = try? await MKLookAroundSceneRequest(coordinate: sight.coordinate).scene
        }
    }

    private var telURL: URL? {
        let digits = sight.phone.filter { $0.isNumber || $0 == "+" }
        return digits.isEmpty ? nil : URL(string: "tel://\(digits)")
    }

    private func openInMaps() {
        let item = MKMapItem(location: CLLocation(latitude: sight.lat, longitude: sight.lon), address: nil)
        item.name = sight.name
        item.openInMaps()
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
