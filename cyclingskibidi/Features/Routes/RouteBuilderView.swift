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
    @State private var draggingScenic = false
    /// The scenic value the current plan was asked for, so a settled slider doesn't re-plan twice.
    @State private var plannedScenic = Route.defaultScenic
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
    /// A place tapped on the map: Kit's card over the map, Details opens the full sheet.
    @State private var tapped: Sight?
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
                if let s = tapped {
                    VStack {
                        PassBySightCard(sight: s, onClose: { tapped = nil }, onMore: { tapped = nil; selectedSight = s })
                            .padding(.horizontal, 16).padding(.top, 8)
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.default, value: tapped?.id)
            // The map runs under the bar; the title and buttons float over it.
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationTitle("New route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { naming = true }.disabled(!canSave)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search for a place")
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
            #if DEBUG
            .task { if Demo.screen == "builder-route", waypoints.isEmpty, let loop = PresetLoops.all.dropFirst().first { use(loop) } }
            #endif
            .onChange(of: profileRaw) { _, _ in direct = nil }   // today's context changes the direct line too
            .onChange(of: profileRaw) { _, _ in replan() }   // "For you" edits re-pick
        }
    }

    // MARK: Map

    private var map: some View {
        OfflineMap(lines: mapLines, pins: mapPins, focus: focus, showsUser: true, showsUserButton: true,
                   onTap: { coord in tapped = nil; waypoints.append(Coord(coord)); replan() },
                   onRegionChange: { mapRegion = $0 },
                   onFeatureTap: { tapped = $0 })
            .ignoresSafeArea()
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
                   look: .view(AnyView(SightBadge(sight: sight))), onTap: { tapped = sight })
        }
    }

    private var searchResults: some View {
        Group {
            if !results.isEmpty {
                List(results) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.name).font(.body)
                        Text([Discovery.icon(for: item.category).label, item.address].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            if PresetLoops.isBikePlace(item) {
                                actionButton("Start here") { addWaypoint(item.coordinate, atStart: true) }
                                actionButton("Return the bike here") { addWaypoint(item.coordinate) }
                            } else {
                                actionButton("Add as a stop") { addWaypoint(item.coordinate) }
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.plain)
                .frame(maxHeight: 300)
                .background(.regularMaterial)
            }
        }
    }

    // MARK: Bottom bar

    /// Native glass panel, capped so the map and route stay visible; it scrolls when full.
    private var controls: some View {
        ViewThatFits(in: .vertical) {
            panel
            ScrollView { panel }.scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxHeight: 380)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: .rect(cornerRadius: 22))
        .padding(12)
    }

    private var panel: some View {
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
                VStack(alignment: .leading, spacing: 2) {
                    Slider(value: $scenic, in: 0...1) {
                        Text("Scenery")
                    } minimumValueLabel: {
                        Text("Direct").font(.footnote).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    } maximumValueLabel: {
                        Text("Scenic").font(.footnote).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    } onEditingChanged: { editing in
                        draggingScenic = editing
                        if !editing { replan() }
                    }
                    .accessibilityValue(scenic < 0.05 ? "Direct" : scenic > 0.95 ? "Most scenic" : "\(Int((scenic * 100).rounded())) percent scenic")
                    .accessibilityHint("Direct is shortest; scenic bends toward water and parks, up to 30 percent longer.")
                    // VoiceOver and Switch Control adjust without a drag: re-plan once they settle.
                    .task(id: scenic) {
                        guard !draggingScenic, scenic != plannedScenic else { return }
                        try? await Task.sleep(for: .milliseconds(500))
                        if !Task.isCancelled, !draggingScenic { replan() }
                    }
                    if !planning, let d = direct, d.waypoints == waypoints, let extra = Self.extraLabel(scenic: plan.distance, direct: d.distance) {
                        Text("\(extra) for the scenery").font(.footnote.monospacedDigit().weight(.semibold))
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
                // Figma v3 · 02: three big figures, then the extras as Kit tags.
                HStack(alignment: .firstTextBaseline) {
                    figure(Fmt.km(plan.distance), "Distance")
                    figure(Fmt.duration(plan.expected), "At \(mode.rawValue.lowercased()) pace")
                    figure(difficulty.rawValue, "Difficulty")
                }
                if plan.ascent > 0 {
                    Label("\(Int(plan.ascent)) m of climbing", systemImage: "arrow.up.right")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if plan.offConnectorMeters > 0 {
                    Label("\(Fmt.km(plan.offConnectorMeters)) is off the park connectors", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if mode != .fast, let sights, !sights.isEmpty, !sightsLoading {
                // One quiet line here; the full Kit bubble lives on the route brief.
                Label {
                    Text(kitByModel ? "Kit picked \(sights.count) places for what you like" : "Kit's quick picks: \(sights.count) places for what you like")
                } icon: { KitAvatar(size: 22) }
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if mode != .fast { placesSection }
            if waypoints.isEmpty { loopsSection }   // never wipes pins the rider placed

            HStack {
                Button {
                    waypoints.removeLast()
                    replan()
                } label: {
                    Label("Undo pin", systemImage: "arrow.uturn.backward")
                }
                .disabled(waypoints.isEmpty)

                Spacer()

                Button(role: .destructive) {
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
            .buttonBorderShape(.capsule)
        }
        .padding(16)
    }

    private func figure(_ value: String, _ caption: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var canSave: Bool { !plan.polyline.isEmpty && !planning && !(mode != .fast && sightsLoading) }

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
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .frame(minHeight: 44, alignment: .leading)
                                    .background(.fill.tertiary, in: .rect(cornerRadius: 12))
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

    /// Three ready-made park connector circuits; picking one replaces the pins
    /// and switches the map to Leisure so the whole line follows connectors.
    private var loopsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Loops").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(PresetLoops.all) { loop in
                        Button { use(loop) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(loop.name).font(.footnote.weight(.semibold)).lineLimit(1)
                                Text(loop.blurb).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .frame(width: 240, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .frame(minHeight: 44, alignment: .leading)
                            .background(.fill.tertiary, in: .rect(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(loop.name). \(loop.blurb)")
                    }
                }
            }
        }
    }

    private func actionButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(minHeight: 44) }
    }

    private func addWaypoint(_ c: CLLocationCoordinate2D, atStart: Bool = false) {
        if atStart { waypoints.insert(Coord(c), at: 0) } else { waypoints.append(Coord(c)) }
        focus = .region(.init(center: c, latitudinalMeters: 1500, longitudinalMeters: 1500))
        replan()
        results = []
        query = ""
    }

    private func use(_ loop: PresetLoop) {
        waypoints = loop.waypoints
        // Whole loop in view; extra padding since the panel covers the lower part of the map.
        // The panel covers the lower half of the map: centre the loop in the half above it.
        let lats = loop.waypoints.map(\.lat), lons = loop.waypoints.map(\.lon)
        if let la0 = lats.min(), let la1 = lats.max(), let lo0 = lons.min(), let lo1 = lons.max() {
            let span = max(la1 - la0, lo1 - lo0, 0.01) * 1.6
            focus = .region(.init(center: .init(latitude: (la0 + la1) / 2 - span * 0.9, longitude: (lo0 + lo1) / 2),
                                  span: .init(latitudeDelta: span * 2.6, longitudeDelta: span)))
        }
        sights = nil
        sightsLoading = false
        direct = nil
        results = []
        query = ""
        // onChange(of: mode) replans by itself; only replan here when the mode is already Leisure.
        if mode == .leisure { replan() } else { mode = .leisure }
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
                plannedScenic = s
                let fresh = try await Routing.plan(through: currentWaypoints, mode: currentMode, context: profile.today, scenic: s)
                guard gen == generation else { return }
                // The extra-distance label needs the direct length once per pin set.
                if currentMode == .leisure, direct?.waypoints != currentWaypoints {
                    // A failed comparison plan only loses the label, never the route.
                    let d = s == 0 ? fresh : try? await Routing.plan(through: currentWaypoints, mode: .leisure, context: profile.today)
                    guard gen == generation else { return }
                    if let d { direct = (currentWaypoints, d.distance) }
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
        // Round with a white ring, as Maps draws its own markers: start green, end red.
        Text("\(index + 1)").font(.caption2.bold()).foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(last ? Color.red : index == 0 ? Color.green : Color.blue, in: .circle)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}

#Preview {
    RouteBuilderView()
        .modelContainer(for: [Route.self, Ride.self], inMemory: true)
}
