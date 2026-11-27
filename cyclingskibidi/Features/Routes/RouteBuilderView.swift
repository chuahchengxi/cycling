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
    /// The collapsed sheet's content, measured: the small detent fits it exactly.
    @State private var topHeight: CGFloat = 200
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
            map
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
            // The panel is a native sheet: summary on top, drag up for Kit's places.
            .sheet(isPresented: .constant(true)) { panelSheet }
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
        // Figma (03 Route builder): off-connector stretches are square terracotta dashes with
        // map in the gaps, so the blue line is broken where they are, not drawn underneath.
        Self.connectorRuns(plan.polyline, off: plan.offConnectorSegments).map { MapLine(coords: $0.coordinates, color: .systemBlue, width: 6) }
            + plan.offConnectorSegments.map { MapLine(coords: $0.coordinates, color: UIColor(KitColor.terracotta), width: 6, dashed: true) }
    }

    /// The stretches of `line` not in any off-connector segment (matched edge by edge).
    nonisolated static func connectorRuns(_ line: [Coord], off: [[Coord]]) -> [[Coord]] {
        func key(_ a: Coord, _ b: Coord) -> String { "\(a.lat),\(a.lon)>\(b.lat),\(b.lon)" }
        let offEdges = Set(off.flatMap { s in zip(s, s.dropFirst()).map { key($0, $1) } })
        var runs: [[Coord]] = [], run: [Coord] = []
        for (a, b) in zip(line, line.dropFirst()) {
            if offEdges.contains(key(a, b)) {
                if run.count > 1 { runs.append(run) }
                run = []
            } else {
                if run.isEmpty { run = [a] }
                run.append(b)
            }
        }
        if run.count > 1 { runs.append(run) }
        return runs
    }

    static func selfCheck() {
        let p = (0..<5).map { Coord(lat: Double($0), lon: 0, alt: 0) }
        assert(connectorRuns(p, off: []) == [p], "no off stretch: one run")
        assert(connectorRuns(p, off: [[p[1], p[2], p[3]]]) == [[p[0], p[1]], [p[3], p[4]]], "gap where it's off")
        assert(connectorRuns(p, off: [p]).isEmpty, "all off: no blue")
    }

    private var mapPins: [MapPin] {
        let pins = waypoints.enumerated().map { index, point in
            MapPin(id: "wp\(index)", coordinate: point.cl, title: "Pin \(index + 1)",
                   look: .view(AnyView(WaypointPin(index: index, last: index == waypoints.count - 1))), onTop: true)
        }
        return pins + (sights ?? []).map { sight in
            MapPin(id: sight.id.uuidString, coordinate: sight.coordinate, title: sight.name,
                   look: .view(AnyView(SightBadge(sight: sight))), onTap: { tapped = sight })
        } + (tapped.map { s in [.callout(for: s, onClose: { tapped = nil }, onMore: { tapped = nil; selectedSight = s })] } ?? [])
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

    // MARK: Bottom sheet

    /// Collapsed: distance, time, difficulty, mode and Undo / Clear. Drag up for the
    /// scenery slider, Kit's places and the search.
    private var panelSheet: some View {
        ScrollView {
            VStack(spacing: 12) {
                top.onGeometryChange(for: CGFloat.self, of: \.size.height) { topHeight = $0 }
                if waypoints.count >= 2 { more }
            }
            .padding(16).padding(.top, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents(waypoints.count >= 2 ? [.height(topHeight + 26), .medium, .large]
                             // Before a route there's little to show: a floor keeps it from shrinking to a cramped strip.
                             : [.height(max(topHeight + 40, 180))])
        .presentationBackgroundInteraction(.enabled)
        .presentationDragIndicator(waypoints.count >= 2 ? .visible : .hidden)
        .interactiveDismissDisabled()
        // Presented from the sheet: only the topmost sheet can present.
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
    }

    @ViewBuilder
    private var top: some View {
        VStack(spacing: 12) {
            if waypoints.count >= 2 {
                summary
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
            } else {
                discovery
                Text("Tap the map to drop pins. Two or more makes a route.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if waypoints.isEmpty { loopsSection }   // never wipes pins the rider placed
            }
            undoClear
        }
    }

    @ViewBuilder
    private var summary: some View {
        if planning {
            ProgressView("Finding a route…").font(.footnote)
        } else if plan.polyline.isEmpty {
            Text("No route between those pins yet.").font(.footnote).foregroundStyle(.secondary)
        } else {
            // Figma v3 · 02: three big figures.
            HStack(alignment: .firstTextBaseline) {
                figure(Fmt.km(plan.distance), "Distance")
                figure(Fmt.duration(plan.expected), "At \(mode.rawValue.lowercased()) pace")
                figure(difficulty.rawValue, "Difficulty")
            }
            if plan.offConnectorMeters > 0 {
                Label("\(Fmt.km(plan.offConnectorMeters)) is off the park connectors", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Below the fold: the scenery slider, climbing, Kit's places, the search.
    @ViewBuilder
    private var more: some View {
        if mode == .leisure {
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
        if !planning, plan.ascent > 0 {
            Label("\(Int(plan.ascent)) m of climbing", systemImage: "arrow.up.right")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if mode != .fast, let sights, !sights.isEmpty, !sightsLoading {
            // One quiet line here; the full Kit bubble lives on the route brief.
            Label {
                Text(kitByModel ? "Kit picked \(sights.count) places for what you like" : "Kit's quick picks: \(sights.count) places for what you like")
            } icon: { KitAvatar(size: 22) }
            .font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        pinList
        if mode != .fast { placesSection }
        discovery
    }

    /// Every pin, each removable on its own; the route re-plans through the rest.
    private var pinList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pins").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(waypoints.indices, id: \.self) { i in
                HStack(spacing: 12) {
                    WaypointPin(index: i, last: i == waypoints.count - 1)
                    Text(i == 0 ? "Start" : i == waypoints.count - 1 ? "Finish" : "Stop \(i)")
                    Spacer()
                    Button(role: .destructive) {
                        waypoints.remove(at: i)
                        replan()
                    } label: {
                        Image(systemName: "minus.circle.fill").font(.title3).frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Delete pin \(i + 1)")
                }
            }
            Button(role: .destructive, action: clearAll) {
                Label("Clear all pins", systemImage: "trash").font(.subheadline)
            }
            .buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func clearAll() {
        waypoints = []
        plan = RoutePlan()
        generation += 1
        sights = nil
        sightsLoading = false
    }

    @ViewBuilder
    private var discovery: some View {
        if mode == .leisure, let region = mapRegion {
            DiscoveryPanel(region: region) { coord in
                waypoints.append(Coord(coord))
                focus = .region(.init(center: coord, latitudinalMeters: 1500, longitudinalMeters: 1500))
                replan()
            }
        }
    }

    private var undoClear: some View {
        HStack {
            Button {
                waypoints.removeLast()
                replan()
            } label: {
                Label("Undo pin", systemImage: "arrow.uturn.backward")
            }
            .disabled(waypoints.isEmpty)

            Spacer()
            // Single pins (and Clear all) are in the Pins list when the sheet is dragged up.
        }
        .font(.subheadline)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
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
                // Every place in ride order, one per row: the whole visit list at a glance.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Places along the way").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        ForEach(sights) { sight in
                            Button { selectedSight = sight } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: Discovery.icon(for: sight.category).symbol)
                                        .frame(width: 28).foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(sight.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                                        Text(sight.note ?? Discovery.icon(for: sight.category).label)
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer(minLength: 8)
                                    Text(Fmt.km(sight.offsetAlong)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 10)
                                .frame(minHeight: 44)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(sight.name), \(Discovery.icon(for: sight.category).label), \(Fmt.km(sight.offsetAlong)) along the route")
                            if sight.id != sights.last?.id { Divider().padding(.leading, 40) }
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
