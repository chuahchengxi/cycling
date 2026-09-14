//
//  RouteBuilderView.swift
//  cyclingskibidi
//
//  Build your own route: drop pins, and every pin is pulled onto the nearest
//  real road before the leg is drawn, so the saved line is rideable rather than
//  a straight hop between taps.
//

import SwiftUI
import SwiftData
import MapKit

struct RouteBuilderView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var onSaved: (() -> Void)? = nil

    /// The mode CreateRouteFlow sent us in, kept as the map builder's starting
    /// point; the segmented control below can then move it to any of the three.
    @State private var mode: RideMode
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var mapRegion: MKCoordinateRegion?
    @State private var waypoints: [Coord] = []
    @State private var plan = RoutePlan()
    @State private var planning = false
    @State private var error: String?
    @State private var name = ""
    @State private var naming = false
    @State private var planTask: Task<Void, Never>?
    /// Bumped on every replan; a background continuation only applies its result
    /// if this still matches, so a stale plan or sights fetch can never clobber
    /// a newer mode/waypoint selection.
    @State private var generation = 0

    /// Leisure sights discovered along the current plan. `nil` means "not
    /// searched yet" (or cleared by a mode switch); `[]` means "searched, found
    /// none" — the two need different inline copy.
    @State private var sights: [Sight]?
    @State private var sightsLoading = false
    @State private var selectedSight: Sight?

    /// Search, so a route can start from an address instead of a lucky tap.
    @State private var query = ""
    @State private var results: [MKMapItem] = []

    init(mode: RideMode = .moderate, onSaved: (() -> Void)? = nil) {
        _mode = State(initialValue: mode)
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                map
                controls
            }
            .navigationTitle("New route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { naming = true }
                        .disabled(plan.polyline.isEmpty || planning || (mode == .leisure && sightsLoading))
                }
            }
            .searchable(text: $query, prompt: "Search for a place")
            .onSubmit(of: .search) { Task { await runSearch() } }
            .overlay(alignment: .top) { searchResults }
            .alert("Name this route", isPresented: $naming) {
                TextField("Route name", text: $name)
                Button("Save", action: save)
                Button("Cancel", role: .cancel) {}
            }
            .alert("Couldn't route that leg", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
            .sheet(item: $selectedSight) { SightSheet(sight: $0) }
            .onChange(of: mode) { _, _ in replan() }
        }
    }

    // MARK: Map

    private var map: some View {
        MapReader { proxy in
            Map(position: $camera) {
                UserAnnotation()

                if !plan.polyline.isEmpty {
                    MapPolyline(coordinates: plan.polyline.coordinates)
                        .stroke(.blue, style: .init(lineWidth: 6, lineCap: .round, lineJoin: .round))
                }
                // Off-connector stretches (roads/paths) drawn distinctly so the rider sees
                // exactly what leaves the PCN and can reject or redirect it.
                ForEach(Array(plan.offConnectorSegments.enumerated()), id: \.offset) { _, seg in
                    MapPolyline(coordinates: seg.coordinates)
                        .stroke(.orange, style: .init(lineWidth: 6, lineCap: .round, lineJoin: .round, dash: [2, 6]))
                }

                ForEach(Array(waypoints.enumerated()), id: \.offset) { index, point in
                    Annotation("", coordinate: point.cl) {
                        WaypointPin(index: index, last: index == waypoints.count - 1)
                    }
                }

                ForEach(sights ?? []) { sight in
                    Annotation(sight.name, coordinate: sight.coordinate) {
                        Button { selectedSight = sight } label: { SightBadge(sight: sight) }
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .mapControls { MapUserLocationButton(); MapCompass() }
            .onTapGesture { screenPoint in
                guard let coord = proxy.convert(screenPoint, from: .local) else { return }
                waypoints.append(Coord(coord))
                replan()
            }
            .onMapCameraChange(frequency: .onEnd) { context in mapRegion = context.region }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private var searchResults: some View {
        Group {
            if !results.isEmpty {
                List(results, id: \.self) { item in
                    Button {
                        let c = item.location.coordinate
                        waypoints.append(Coord(c))
                        camera = .region(.init(center: c, latitudinalMeters: 1500, longitudinalMeters: 1500))
                        replan()
                        results = []
                        query = ""
                    } label: {
                        VStack(alignment: .leading) {
                            Text(item.name ?? "Place").font(.body)
                            Text(item.address?.fullAddress ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.plain)
                .frame(maxHeight: 260)
                .background(.regularMaterial)
            }
        }
    }

    // MARK: Bottom bar

    private var controls: some View {
        VStack(spacing: 12) {
            if waypoints.count >= 2 {
                Picker("Mode", selection: $mode) {
                    ForEach(RideMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            if mode == .leisure, let region = mapRegion ?? camera.region {
                DiscoveryPanel(region: region) { coord in
                    waypoints.append(Coord(coord))
                    camera = .region(.init(center: coord, latitudinalMeters: 1500, longitudinalMeters: 1500))
                    replan()
                }
            }

            if planning {
                ProgressView("Finding a route…").font(.footnote)
            } else if plan.polyline.isEmpty {
                Text(waypoints.count < 2
                     ? "Tap the map to drop pins. Two or more makes a route."
                     : "No route between those pins yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                FlowLayout {
                    Pill(text: Fmt.km(plan.distance))
                    Pill(text: Fmt.duration(plan.expected))
                    Pill(text: difficulty.rawValue, tint: difficulty.color)
                    Pill(text: mode.rawValue, tint: .accentColor)
                    if plan.ascent > 0 { Pill(text: "↗ \(Int(plan.ascent)) m") }
                    if plan.offConnectorMeters > 0 {
                        Pill(text: "⚠︎ \(Fmt.km(plan.offConnectorMeters)) off-connector", tint: .orange)
                    }
                }
            }

            if mode == .leisure { placesSection }

            HStack {
                Button(role: .destructive) {
                    waypoints.removeLast()
                    replan()
                } label: {
                    Label("Undo pin", systemImage: "arrow.uturn.backward")
                }
                .disabled(waypoints.isEmpty)

                Spacer()

                Button {
                    waypoints = []
                    plan = RoutePlan()
                    generation += 1
                    sights = nil
                    sightsLoading = false
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(waypoints.isEmpty)
            }
            .font(.subheadline)
            .buttonStyle(.bordered)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: .rect(cornerRadius: 22))
        .padding(12)
    }

    private var difficulty: Difficulty {
        .rated(distanceMeters: plan.distance, ascentMeters: plan.ascent)
    }

    /// "Places along the way": a horizontally scrollable strip of the sights
    /// found near the current leisure plan, ordered by offset (Discovery
    /// already sorts them). Loading / empty states are inline so the map stays
    /// interactive underneath.
    @ViewBuilder
    private var placesSection: some View {
        if sightsLoading {
            HStack(spacing: 8) {
                ProgressView()
                Text("Finding places along the way…")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else if let sights {
            if sights.isEmpty {
                Text("No places found along this route.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Places along the way").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(sights) { sight in
                                Button { selectedSight = sight } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(sight.name).font(.footnote.weight(.semibold)).lineLimit(1)
                                        Text("\(Discovery.icon(for: sight.category).label) · \(Fmt.km(sight.offsetAlong))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 12)
                                    .frame(minHeight: 44, alignment: .leading)
                                    .background(.quaternary, in: .rect(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(sight.name), \(Discovery.icon(for: sight.category).label), \(Fmt.km(sight.offsetAlong)) along the route")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Actions

    /// Re-routes on every pin/mode change. `generation` guards two async
    /// stages — the plan itself and, for leisure, the sights search that
    /// follows it — so a superseded request can never overwrite a newer one,
    /// even if its network call is still in flight when the next starts.
    private func replan() {
        planTask?.cancel()
        generation += 1
        let gen = generation
        guard waypoints.count >= 2 else { plan = RoutePlan(); planning = false; sights = nil; sightsLoading = false; return }
        planning = true
        if mode != .leisure { sights = nil; sightsLoading = false }
        let currentMode = mode
        let currentWaypoints = waypoints
        planTask = Task {
            do {
                let fresh = try await Routing.plan(through: currentWaypoints, mode: currentMode)
                guard gen == generation else { return }
                plan = fresh
                planning = false
                if currentMode == .leisure, !fresh.polyline.isEmpty {
                    sights = nil
                    sightsLoading = true
                    let found = await Discovery.sights(along: fresh.polyline)
                    guard gen == generation else { return }
                    sights = found
                    sightsLoading = false
                }
            } catch {
                guard gen == generation else { return }
                self.error = error.localizedDescription
                planning = false
            }
        }
    }

    private func save() {
        let route = Route.make(
            name: name.isEmpty ? "Route \(Date.now.formatted(date: .abbreviated, time: .shortened))" : name,
            mode: mode, waypoints: waypoints, plan: plan, sights: sights ?? [])
        context.insert(route)
        try? context.save()
        (onSaved ?? { dismiss() })()
    }

    private func runSearch() async {
        guard !query.isEmpty else { results = []; return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let region = camera.region { request.region = region }
        results = (try? await MKLocalSearch(request: request).start())?.mapItems ?? []
    }
}

private struct WaypointPin: View {
    let index: Int
    let last: Bool

    var body: some View {
        ZStack {
            Circle().fill(last ? Color.red : index == 0 ? .green : .blue)
            Text("\(index + 1)").font(.caption2.bold()).foregroundStyle(.white)
        }
        .frame(width: 26, height: 26)
        .shadow(radius: 2)
    }
}

#Preview {
    RouteBuilderView()
        .modelContainer(for: [Route.self, Ride.self], inMemory: true)
}
