//
//  RouteDetailView.swift
//  cyclingskibidi
//
//  Second screen on the board: the route drawn on a map, with a sheet that sits
//  low showing distance / time / difficulty and START, and expands to the full
//  brief — climb totals, elevation graph, and every obstacle riders have marked
//  along the way.
//

import SwiftUI
import SwiftData
import MapKit

struct RouteDetailView: View {
    let route: Route

    @Environment(Trip.self) private var trip
    @Environment(\.modelContext) private var context
    @Query private var obstacles: [Obstacle]

    @State private var sheetShown = true
    @State private var startPending = false
    @State private var detent: PresentationDetent = .fraction(0.28)
    @State private var camera: MapCameraPosition = .automatic

    /// Obstacles within 60 m of the line — the ones that will actually be ridden past.
    private var nearby: [Obstacle] {
        let poly = route.polyline.coordinates
        guard poly.count > 1 else { return [] }
        let cum = Geo.cumulative(poly)
        return obstacles.filter {
            (Geo.snap($0.coordinate, to: poly, cumulative: cum)?.lateral ?? .greatestFiniteMagnitude) < 60
        }
    }

    var body: some View {
        Map(position: $camera) {
            if route.polyline.count > 1 {
                MapPolyline(coordinates: route.polyline.coordinates)
                    .stroke(.blue, style: .init(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }
            if let start = route.polyline.first {
                Marker("Start", systemImage: "flag.fill", coordinate: start.cl).tint(.green)
            }
            if let end = route.polyline.last {
                Marker("Finish", systemImage: "flag.checkered", coordinate: end.cl).tint(.red)
            }
            ForEach(nearby) { obstacle in
                Annotation(obstacle.kind.rawValue, coordinate: obstacle.coordinate) {
                    ObstacleBadge(kind: obstacle.kind)
                }
            }
            ForEach(route.sights) { sight in
                Annotation(sight.name, coordinate: sight.coordinate) {
                    SightBadge(sight: sight)
                }
            }
            UserAnnotation()
        }
        .mapStyle(.standard(elevation: .realistic))
        .ignoresSafeArea(edges: .bottom)
        // A long route name doesn't fit beside the back button (it truncated to
        // "Bu…"), so show it in full as the large title below the bar instead.
        .navigationTitle(route.name)
        .navigationBarTitleDisplayMode(.large)
        .onAppear(perform: frameRoute)
        .task {
            // Leisure routes gather the sights along the line once, then reuse
            // them on every open and during the ride.
            guard route.mode == .leisure, route.sights.isEmpty, route.polyline.count > 1 else { return }
            let found = await Discovery.sights(along: route.polyline)
            guard !found.isEmpty else { return }
            route.sightData = Blob.encode(found)
            try? context.save()
        }
        .sheet(isPresented: $sheetShown, onDismiss: {
            // Begin navigation only once the brief sheet is fully dismissed.
            // Presenting the navigate cover while this sheet is still up is the
            // "the current sheet is blocking the next one" failure.
            if startPending { startPending = false; trip.begin(route) }
        }) {
            SheetView(route: route, obstacles: nearby, currentDetent: $detent) {
                startPending = true
                sheetShown = false
            }
            .presentationDetents([.fraction(0.28), .large], selection: $detent)
            .presentationBackgroundInteraction(.enabled)
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled()
        }
    }

    /// Fit the whole route on screen with a little air around it.
    private func frameRoute() {
        let coords = route.polyline.coordinates
        guard !coords.isEmpty else { return }
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return }
        camera = .region(MKCoordinateRegion(
            center: .init(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: .init(latitudeDelta: max((maxLat - minLat) * 1.6, 0.005),
                        longitudeDelta: max((maxLon - minLon) * 1.6, 0.005))))
    }
}

struct ObstacleBadge: View {
    let kind: ObstacleKind

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(6)
            .background(.orange, in: .circle)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .shadow(radius: 2)
    }
}
