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

    /// A local-search request bounded to the visible region. With tastes typed,
    /// it becomes a natural-language search; empty tastes fall back to a broad
    /// "points of interest" sweep filtered to the leisure categories.
    static func request(tastes: String, in region: MKCoordinateRegion) -> MKLocalSearch.Request {
        let trimmed = tastes.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = MKLocalSearch.Request()
        request.region = region
        request.resultTypes = .pointOfInterest
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: leisureCategories)
        request.naturalLanguageQuery = trimmed.isEmpty ? "points of interest" : trimmed
        return request
    }

    static func selfCheck() {
        let region = MKCoordinateRegion(center: .init(latitude: 1.30, longitude: 103.80),
                                        latitudinalMeters: 2000, longitudinalMeters: 2000)
        let typed = request(tastes: "  hawker, temples ", in: region)
        assert(typed.naturalLanguageQuery == "hawker, temples", "tastes should be trimmed, not blanked")
        let empty = request(tastes: "   ", in: region)
        assert(empty.naturalLanguageQuery == "points of interest", "empty tastes need a fallback query")
        assert(empty.resultTypes == .pointOfInterest)
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
