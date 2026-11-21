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
    /// Bundled closures this route crosses — checked when the route is opened.
    @State private var closureHits: (active: [Closure], expired: [Closure]) = ([], [])
    @State private var replanning = false
    @State private var confirmClosedStart = false
    /// The last re-plan still crossed a closure (offline, or no way round).
    @State private var replanFailed = false

    private var blockingClosures: [Closure] { closureHits.active.filter { $0.kind == .closure } }

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
            ForEach(closureHits.active) { c in
                ForEach(Array(c.circles.enumerated()), id: \.offset) { _, ci in
                    MapCircle(center: .init(latitude: ci.lat, longitude: ci.lon), radius: ci.radiusM)
                        .foregroundStyle(.red.opacity(c.kind == .closure ? 0.3 : 0.15))
                }
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
        // Keep the title inline so the large title bar doesn't cover the map.
        .navigationTitle(route.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            frameRoute()
            checkClosures()
        }
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
            SheetView(route: route, obstacles: nearby, closures: closureHits, replanning: replanning,
                      currentDetent: $detent, onStart: {
                // Saved routes are rechecked at ride start too: a closure may have begun since opening.
                checkClosures()
                replanFailed = false
                if blockingClosures.isEmpty { start() } else { confirmClosedStart = true }
            }, onReplan: { replan() })
            .confirmationDialog(closedStartTitle, isPresented: $confirmClosedStart, titleVisibility: .visible) {
                if !replanFailed { Button(blockingClosures.count == 1 ? "Re-plan around it" : "Re-plan around them") { replan(thenStart: true) } }
                Button("Ride anyway") { start() }
                Button("Cancel", role: .cancel) {}
            }
            .presentationDetents([.fraction(0.28), .large], selection: $detent)
            .presentationBackgroundInteraction(.enabled)
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled()
        }
    }

    private var closedStartTitle: String {
        let what = blockingClosures.count == 1 ? blockingClosures[0].name : "\(blockingClosures.count) closures"
        return replanFailed ? "Couldn't find a way round \(what)" : "\(what) \(blockingClosures.count == 1 ? "is" : "are") closed on this route"
    }

    private func start() {
        startPending = true
        sheetShown = false
    }

    private func checkClosures() {
        closureHits = Closures.hits(route.polyline, in: Closures.bundled(), on: Closures.now)
    }

    /// Re-plan the saved route through its waypoints; routing now bends round active closures.
    private func replan(thenStart: Bool = false) {
        guard !replanning else { return }
        replanning = true
        Task {
            defer { replanning = false }
            if let plan = try? await Routing.plan(through: route.waypoints, mode: route.mode), plan.polyline.count > 1 {
                route.apply(plan)
                route.sightData = nil
                try? context.save()
                checkClosures()
                frameRoute()
            }
            guard thenStart else { return }
            // Only start if the new line is actually clear; otherwise ask again, honestly.
            checkClosures()
            if blockingClosures.isEmpty { start() } else { replanFailed = true; confirmClosedStart = true }
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
