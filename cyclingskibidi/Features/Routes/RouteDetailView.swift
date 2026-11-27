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
    @Query(sort: \Ride.startedAt, order: .reverse) private var rides: [Ride]
    @AppStorage(RiderProfile.storageKey) private var profileRaw = ""
    private var profile: RiderProfile { RiderProfile.decode(profileRaw) ?? RiderProfile() }

    /// A place tapped on the map, shown as Kit's card over the map.
    @State private var tapped: Sight?
    @State private var detent: PresentationDetent = {
        #if DEBUG
        if Demo.screen == "detail-full" { return .large }
        #endif
        return SheetView.collapsedDetent
    }()
    @State private var focus: MapFocus?
    /// Bundled closures and the rider's own closed marks this route rides — checked when opened.
    @State private var closureHits: (active: [Closure], expired: [Closure]) = ([], [])
    @State private var replanning = false
    @State private var confirmClosedStart = false
    /// The last re-plan still crossed a closure (no way round).
    @State private var replanFailed = false
    @State private var kitByModel = false
    @State private var restLevel: RiderLevel?

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
                   pins: mapPins, focus: focus, showsUser: true, onFeatureTap: { tapped = $0 })
        .ignoresSafeArea()
        // The map runs under the bar; the back button and title float over it.
        .toolbarBackground(.hidden, for: .navigationBar)
        .overlay(alignment: .top) {
            if let s = tapped {
                PassBySightCard(sight: s) { tapped = nil }
                    .padding(.horizontal, 16).padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.default, value: tapped?.id)
        #if DEBUG
        .task { if Demo.screen == "detail-tap" { try? await Task.sleep(for: .seconds(2)); tapped = route.sights.first } }
        #endif
        // Keep the title inline so the large title bar doesn't cover the map.
        .navigationTitle(route.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            frameRoute()
            checkClosures()
        }
        .task {
            // Kit's picks are found afresh on every open: what's open and what's
            // closed depends on when you ride, not on when the route was planned.
            // The ride uses what this saves.
            guard route.mode != .fast, route.polyline.count > 1 else { return }
            await pick()
        }
        // The brief is part of this screen, not a system sheet: a sheet is its own layer and
        // only slid away after the pop to Routes had finished. As an overlay it leaves with
        // the screen, swipe-back included. Drag or tap the grabber to expand / collapse.
        .overlay(alignment: .bottom) { briefPanel }
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
        pins += route.restStops.map { r in
            MapPin(id: "rest-\(r.id.uuidString)", coordinate: r.coordinate, title: "Rest stop, \(r.name)",
                   look: .marker(symbol: r.amenities.contains("drinkingWater") ? "drop.fill" : Discovery.icon(for: r.amenities.first ?? "").symbol, tint: .systemTeal))
        }
        pins += route.sights.map { s in
            MapPin(id: s.id.uuidString, coordinate: s.coordinate, title: s.name, look: .view(AnyView(SightBadge(sight: s))), onTap: { tapped = s })
        }
        return pins
    }

    private var closedStartTitle: String {
        let what = blockingClosures.count == 1 ? blockingClosures[0].name : "\(blockingClosures.count) closures"
        return replanFailed ? "Couldn't find a way round \(what)" : "\(what) \(blockingClosures.count == 1 ? "is" : "are") closed on this route"
    }

    private func start() { trip.begin(route) }

    private var expanded: Bool { detent == .large }

    private var briefPanel: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                Capsule().fill(.secondary).frame(width: 36, height: 5).padding(.top, 8).padding(.bottom, 4)
                    .frame(maxWidth: .infinity, minHeight: 22)
                    .contentShape(.rect)
                    .onTapGesture { withAnimation(.snappy) { detent = expanded ? SheetView.collapsedDetent : .large } }
                    .accessibilityElement()
                    .accessibilityLabel(expanded ? "Collapse route brief" : "Expand route brief")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { detent = expanded ? SheetView.collapsedDetent : .large }
                SheetView(route: route, obstacles: nearby, closures: closureHits, replanning: replanning, kitByModel: kitByModel, restLevel: restLevel ?? RiderLevel.effective(profile: profile, rides: rides),
                          currentDetent: $detent, onStart: {
                    // Saved routes are rechecked at ride start too: a closure may have begun since opening.
                    checkClosures()
                    replanFailed = false
                    if blockingClosures.isEmpty { start() } else { confirmClosedStart = true }
                }, onReplan: { replan() }, onAddStop: addStop, onRemoveStop: removeStop)
                .padding(.top, -24)   // SheetView's own top inset was for the system grabber
            }
            .frame(height: expanded ? geo.size.height * 0.92 : 170, alignment: .top)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 34, topTrailingRadius: 34))
            .shadow(color: .black.opacity(0.15), radius: 12, y: -2)
            .gesture(DragGesture(minimumDistance: 20).onEnded { g in
                withAnimation(.snappy) {
                    if g.translation.height < -40 { detent = .large } else if g.translation.height > 40 { detent = SheetView.collapsedDetent }
                }
            })
            .frame(maxHeight: .infinity, alignment: .bottom)
            .confirmationDialog(closedStartTitle, isPresented: $confirmClosedStart, titleVisibility: .visible) {
                if !replanFailed { Button(blockingClosures.count == 1 ? "Re-plan around it" : "Re-plan around them") { replan(thenStart: true) } }
                Button("Ride anyway") { start() }
                Button("Cancel", role: .cancel) {}
            }
        }
        .ignoresSafeArea(edges: .bottom)
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
            if let plan = try? await Routing.plan(through: route.waypoints, mode: route.mode, context: profile.today, scenic: route.scenic), plan.polyline.count > 1 {
                route.apply(plan)   // new line, turns and climb chart together
                // Sights follow the new line: found afresh for Leisure, offline.
                await pick()
                checkClosures()
                frameRoute()
            }
            guard thenStart else { return }
            // Only start if the new line is actually clear; otherwise ask again, honestly.
            checkClosures()
            if blockingClosures.isEmpty { start() } else { replanFailed = true; confirmClosedStart = true }
        }
    }

    /// Ride to a sight: it becomes a pin between the two pins it falls between, then re-plan.
    private func addStop(_ sight: Sight) {
        let line = route.polyline.map(\.cl), cum = Geo.cumulative(line), pins = route.waypoints
        guard pins.count >= 2, !Self.isPin(sight, in: pins) else { return }
        // Snap each pin forward from the last, so an out-and-back's return pins get return-leg distances.
        var from = 0
        let alongs = pins.map { p -> Double in
            guard let s = Geo.snap(p.cl, to: line, cumulative: cum, from: from) else { return 0 }
            from = s.index
            return s.along
        }
        var updated = pins
        updated.insert(Coord(sight.coordinate), at: Self.stopIndex(along: sight.offsetAlong, pinAlongs: alongs))
        route.waypointData = Blob.encode(updated)
        replan()
    }

    /// Drop a sight: a pin placed on it goes (never the start or finish), else it leaves the picks.
    private func removeStop(_ sight: Sight) {
        let pins = route.waypoints
        let kept = pins.enumerated().filter { i, p in
            i == 0 || i == pins.count - 1 || Geo.distance(p.cl, sight.coordinate) > Self.pinRadius
        }.map(\.element)
        if kept.count < pins.count {
            route.waypointData = Blob.encode(kept)
            replan()
        } else {
            let left = route.sights.filter { $0.id != sight.id }
            route.sightData = left.isEmpty ? nil : Blob.encode(left)
            try? context.save()
        }
    }

    nonisolated static let pinRadius: Double = 30
    nonisolated static func isPin(_ sight: Sight, in pins: [Coord]) -> Bool {
        pins.contains { Geo.distance($0.cl, sight.coordinate) <= pinRadius }
    }
    /// Where a stop `along` metres into the ride goes among pins at `pinAlongs`: after the
    /// last pin before it, never before the start or after the finish.
    nonisolated static func stopIndex(along: Double, pinAlongs: [Double]) -> Int {
        let after = pinAlongs.dropFirst().dropLast().firstIndex { $0 > along } ?? pinAlongs.count - 1
        return max(1, min(after, pinAlongs.count - 1))
    }

    static func selfCheck() {
        assert(stopIndex(along: 500, pinAlongs: [0, 1000]) == 1, "between start and finish")
        assert(stopIndex(along: 1500, pinAlongs: [0, 1000, 2000]) == 2, "after the middle pin")
        assert(stopIndex(along: 200, pinAlongs: [0, 1000, 2000]) == 1, "before the middle pin")
        assert(stopIndex(along: 9000, pinAlongs: [0, 1000, 2000]) == 2, "never after the finish")
    }

    /// Kit's quick picks now, saved; the model's later if it answers for this same line.
    private func pick() async {
        guard route.mode != .fast, route.polyline.count > 1 else { return }
        let (line, mode, profile) = (route.polyline, route.mode, profile)
        let level = RiderLevel.effective(profile: profile, rides: rides)
        let (found, stops) = await Task.detached {
            (Kit.picks(along: line, mode: mode, profile: profile), RestStops.along(line, mode: mode, level: level))
        }.value
        guard route.polyline == line else { return }
        kitByModel = false
        restLevel = level
        route.sightData = found.quick.isEmpty ? nil : Blob.encode(found.quick)
        route.restStopData = stops.isEmpty ? nil : Blob.encode(stops)
        try? context.save()
        Task {
            // Not once the ride has started: it already copied the quick picks, and the
            // saved route should show what's being ridden.
            guard let better = await KitModel.refine(line: line, quick: found.quick, candidates: found.candidates, profile: profile),
                  route.polyline == line, trip.route == nil else { return }
            route.sightData = Blob.encode(better)
            kitByModel = true
            try? context.save()
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
