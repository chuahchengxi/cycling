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
    @State private var focus: MapFocus? = .user()
    @State private var mapRegion: MKCoordinateRegion?
    @State private var waypoints: [Coord] = []
    @State private var plan = RoutePlan()
    @State private var planning = false
    /// Direct ↔ Scenic (Leisure only); the plan follows on release.
    @State private var scenic = Route.defaultScenic
    /// Direct distance for the current pins, planned once per pin change.
    @State private var direct: (waypoints: [Coord], distance: Double)?
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
    @State private var editingInterests = false
    /// The model's picks replaced the quick ones for the current line.
    @State private var kitByModel = false
    @AppStorage(RiderProfile.storageKey) private var profileRaw = ""

    /// Search the bundled places, so a route can start from a name instead of a lucky tap.
    @State private var query = ""
    @State private var results: [Sight] = []

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
                        .disabled(plan.polyline.isEmpty || planning || (mode != .fast && sightsLoading))
                }
            }
            .searchable(text: $query, prompt: "Search for a place")
            .onSubmit(of: .search, runSearch)
            .onChange(of: query) { if query.isEmpty { results = [] } }
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
            .sheet(isPresented: $editingInterests) { InterestsSheet() }
            .onChange(of: mode) { _, _ in replan() }
            .onChange(of: profileRaw) { _, _ in replan() }   // "For you" edits re-pick
        }
    }

    // MARK: Map

    private var map: some View {
        OfflineMap(lines: mapLines, pins: mapPins, focus: focus, showsUser: true, showsUserButton: true,
                   onTap: { coord in waypoints.append(Coord(coord)); replan() },
                   onRegionChange: { mapRegion = $0 })
            .ignoresSafeArea(edges: .bottom)
    }

    private var mapLines: [MapLine] {
        // Off-connector stretches (roads/paths) drawn distinctly so the rider sees
        // exactly what leaves the PCN and can reject or redirect it.
        [MapLine(coords: plan.polyline.coordinates, color: .systemBlue, width: 6)]
            + plan.offConnectorSegments.map { MapLine(coords: $0.coordinates, color: .systemOrange, width: 6, dashed: true) }
    }

    private var mapPins: [MapPin] {
        let pins = waypoints.enumerated().map { index, point in
            MapPin(id: "wp\(index)", coordinate: point.cl, title: "Pin \(index + 1)",
                   look: .view(AnyView(WaypointPin(index: index, last: index == waypoints.count - 1))))
        }
        return pins + (sights ?? []).map { sight in
            MapPin(id: sight.id.uuidString, coordinate: sight.coordinate, title: sight.name,
                   look: .view(AnyView(SightBadge(sight: sight))), onTap: { selectedSight = sight })
        }
    }

    private var searchResults: some View {
        Group {
            if !results.isEmpty {
                List(results) { item in
                    Button {
                        let c = item.coordinate
                        waypoints.append(Coord(c))
                        focus = .region(.init(center: c, latitudinalMeters: 1500, longitudinalMeters: 1500))
                        replan()
                        results = []
                        query = ""
                    } label: {
                        VStack(alignment: .leading) {
                            Text(item.name).font(.body)
                            Text([Discovery.icon(for: item.category).label, item.address].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
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
                HStack {
                    Picker("Mode", selection: $mode) {
                        ForEach(RideMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if mode != .fast {
                        Button { editingInterests = true } label: { Label("For you", systemImage: "heart") }
                            .buttonStyle(.bordered)
                    }
                }
            }

            if mode == .leisure, waypoints.count >= 2 {
                HStack(spacing: 10) {
                    Text("Direct").font(.footnote).foregroundStyle(.secondary)
                    Slider(value: $scenic, in: 0...1) { Text("Scenery") } onEditingChanged: { editing in
                        if !editing { replan() }
                    }
                    .accessibilityValue(scenic < 0.05 ? "Direct" : scenic > 0.95 ? "Most scenic" : "\(Int((scenic * 100).rounded())) percent scenic")
                    Text("Scenic").font(.footnote).foregroundStyle(.secondary)
                    if !planning, let d = direct, d.waypoints == waypoints, let extra = Self.extraLabel(scenic: plan.distance, direct: d.distance) {
                        Text(extra).font(.footnote.monospacedDigit().weight(.semibold))
                            .accessibilityLabel("\(extra) longer than direct")
                    }
                }
            }

            if mode == .leisure, let region = mapRegion {
                DiscoveryPanel(region: region) { coord in
                    waypoints.append(Coord(coord))
                    focus = .region(.init(center: coord, latitudinalMeters: 1500, longitudinalMeters: 1500))
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

            if mode != .fast, let sights, !sights.isEmpty, !sightsLoading { KitCard(count: sights.count, byModel: kitByModel) }
            if mode != .fast { placesSection }

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
                                        Text("\(sight.note ?? Discovery.icon(for: sight.category).label) · \(Fmt.km(sight.offsetAlong))")
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
    /// even if it is still in flight when the next starts.
    private func replan() {
        planTask?.cancel()
        generation += 1
        let gen = generation
        guard waypoints.count >= 2 else { plan = RoutePlan(); planning = false; sights = nil; sightsLoading = false; return }
        planning = true
        if mode == .fast { sights = nil; sightsLoading = false }
        let currentMode = mode
        let profile = RiderProfile.decode(profileRaw) ?? RiderProfile()
        let currentWaypoints = waypoints
        planTask = Task {
            do {
                let s = scenic
                let fresh = try await Routing.plan(through: currentWaypoints, mode: currentMode, context: profile.today, scenic: s)
                guard gen == generation else { return }
                // The extra-distance label needs the direct length once per pin set.
                if currentMode == .leisure, direct?.waypoints != currentWaypoints {
                    let d = s == 0 ? fresh : try await Routing.plan(through: currentWaypoints, mode: .leisure, context: profile.today)
                    guard gen == generation else { return }
                    direct = (currentWaypoints, d.distance)
                }
                plan = fresh
                planning = false
                if currentMode != .fast, !fresh.polyline.isEmpty {
                    sights = nil
                    sightsLoading = true
                    kitByModel = false
                    let line = fresh.polyline
                    let found = await Task.detached { Kit.picks(along: line, mode: currentMode, profile: profile) }.value
                    guard gen == generation else { return }
                    sights = found.quick
                    sightsLoading = false
                    // Quick picks are showing; the model's replace them only if this line is still current.
                    Task {
                        guard let better = await KitModel.refine(line: line, quick: found.quick, candidates: found.candidates, profile: profile),
                              let applied = Self.apply(better, forGeneration: gen, current: generation) else { return }
                        sights = applied
                        kitByModel = true
                    }
                }
            } catch {
                guard gen == generation else { return }
                self.error = error.localizedDescription
                planning = false
            }
        }
    }

    /// "+1.2 km" beside the slider; nil when Scenic adds under 50 m (nothing worth showing).
    nonisolated static func extraLabel(scenic: Double, direct: Double) -> String? {
        let extra = scenic - direct
        return extra < 50 ? nil : "+" + (extra / 1000).formatted(.number.precision(.fractionLength(1))) + " km"
    }

    /// A model answer lands only if no newer pin or mode change has happened since it was asked.
    nonisolated static func apply(_ result: [Sight], forGeneration g: Int, current: Int) -> [Sight]? {
        g == current ? result : nil
    }

    private func save() {
        let route = Route.make(
            name: name.isEmpty ? "Route \(Date.now.formatted(date: .abbreviated, time: .shortened))" : name,
            mode: mode, waypoints: waypoints, plan: plan, sights: sights ?? [])
        route.scenicRaw = mode == .leisure ? scenic : nil
        context.insert(route)
        try? context.save()
        (onSaved ?? { dismiss() })()
    }

    private func runSearch() {
        let centre = mapRegion?.center ?? .init(latitude: 1.3521, longitude: 103.8198)
        results = Discovery.search(query, near: centre)
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
