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
    @State private var focus: MapFocus?
    /// Bundled closures and the rider's own closed marks this route rides — checked when opened.
    @State private var closureHits: (active: [Closure], expired: [Closure]) = ([], [])
    @State private var replanning = false
    @State private var confirmClosedStart = false
    /// The last re-plan still crossed a closure (no way round).
    @State private var replanFailed = false

    private var blockingClosures: [Closure] { closureHits.active.filter { $0.kind == .closure } }

    /// Obstacles within 60 m of the line — the ones that will actually be ridden past.
    private var nearby: [Obstacle] {
        let poly = route.polyline.coordinates
        guard poly.count > 1 else { return [] }
        let cum = Geo.cumulative(poly)
        return obstacles.filter(\.isActive).filter {
            (Geo.snap($0.coordinate, to: poly, cumulative: cum)?.lateral ?? .greatestFiniteMagnitude) < 60
        }
    }

    var body: some View {
        OfflineMap(lines: [MapLine(coords: route.polyline.coordinates, color: .systemBlue, width: 6)],
                   discs: closureHits.active.flatMap { c in
                       c.circles.map { MapDisc(center: .init(latitude: $0.lat, longitude: $0.lon), radius: $0.radiusM,
                                               color: .systemRed.withAlphaComponent(c.kind == .closure ? 0.3 : 0.15)) }
                   },
                   pins: mapPins, focus: focus, showsUser: true)
        .ignoresSafeArea(edges: .bottom)
        // Keep the title inline so the large title bar doesn't cover the map.
        .navigationTitle(route.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            frameRoute()
            checkClosures()
        }
        .task {
            // Leisure sights are found afresh on every open: what's open and what's
            // closed depends on when you ride, not on when the route was planned.
            // The ride uses what this saves.
            guard route.mode == .leisure, route.polyline.count > 1 else { return }
            let (line, mode) = (route.polyline, route.mode)
            let found = await Task.detached { Discovery.sights(along: line, mode: mode) }.value
            route.sightData = found.isEmpty ? nil : Blob.encode(found)
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

    private var mapPins: [MapPin] {
        var pins: [MapPin] = []
        if let start = route.polyline.first {
            pins.append(MapPin(id: "start", coordinate: start.cl, title: "Start", look: .marker(symbol: "flag.fill", tint: .systemGreen)))
        }
        if let end = route.polyline.last {
            pins.append(MapPin(id: "finish", coordinate: end.cl, title: "Finish", look: .marker(symbol: "flag.checkered", tint: .systemRed)))
        }
        pins += nearby.map { o in
            MapPin(id: o.pinID, coordinate: o.coordinate, title: o.kind.rawValue, look: .view(AnyView(ObstacleBadge(kind: o.kind))))
        }
        pins += route.sights.map { s in
            MapPin(id: s.id.uuidString, coordinate: s.coordinate, title: s.name, look: .view(AnyView(SightBadge(sight: s))))
        }
        return pins
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
        closureHits = Closures.hits(route.polyline, in: Closures.bundled() + Closures.marked, on: Closures.now)
    }

    /// Re-plan the saved route through its waypoints; routing now bends round active closures.
    private func replan(thenStart: Bool = false) {
        guard !replanning else { return }
        replanning = true
        Task {
            defer { replanning = false }
            if let plan = try? await Routing.plan(through: route.waypoints, mode: route.mode), plan.polyline.count > 1 {
                route.apply(plan)   // new line, turns and climb chart together
                // Sights follow the new line: found afresh for Leisure, offline.
                let (line, mode) = (route.polyline, route.mode)
                let sights = mode == .leisure ? await Task.detached { Discovery.sights(along: line, mode: mode) }.value : route.sights
                route.sightData = sights.isEmpty ? nil : Blob.encode(sights)
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
        focus = .fit(route.polyline.coordinates, pad: 1.6)
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
