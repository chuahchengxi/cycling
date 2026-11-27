//
//  CreateRouteFlow.swift
//  cyclingskibidi
//
//  Guided route creation: pick a mode, pick a source, then build or import.
//

import SwiftUI
import SwiftData
import MapKit
import HealthKit
import UniformTypeIdentifiers

/// Guided route creation: pick a mode, pick a source, then build or import.
/// Import means "build a plannable Route from the track", never a logged ride.
///
/// The chosen RideMode is carried as the navigation path value (mode → source),
/// so there is no optional-mode state to guard. The map builder owns its own
/// NavigationStack, so SourceStep presents it as a fullScreenCover rather than
/// pushing it here — nesting NavigationStacks is what we are avoiding.
struct CreateRouteFlow: View {
    @Environment(\.dismiss) private var dismiss

    @State private var path: [RideMode] = []
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack(path: $path) {
            modeStep
                .navigationTitle("New route")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                .navigationDestination(for: RideMode.self) { m in
                    SourceStep(mode: m, onFinish: { dismiss() })
                        .navigationTitle(m.rawValue)
                        .navigationBarTitleDisplayMode(.inline)
                }
        }
    }

    private var modeStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("How do you want to ride?")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(RideMode.allCases) { m in
                    Button {
                        path.append(m)
                    } label: {
                        HStack(spacing: 14) {
                            Image(m.kitIcon).renderingMode(.template).resizable()
                                .frame(width: 22, height: 22)
                                .frame(width: 40, height: 40)
                                .background(m == .moderate ? KitColor.sage : KitColor.paper)
                                .overlay(Rectangle().strokeBorder(KitColor.ink, lineWidth: 2))
                                .environment(\.colorScheme, m == .moderate ? .light : colorScheme)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(m.rawValue).font(.headline)
                                Text(m.subtitle).font(.subheadline).foregroundStyle(KitColor.muted)
                            }
                            Spacer(minLength: 4)
                            Image("kit-icon-chevron").renderingMode(.template).resizable()
                                .frame(width: 16, height: 16)
                        }
                        .foregroundStyle(KitColor.ink)
                        .frame(minHeight: 72)
                        .kitCard(m == .moderate ? KitColor.board : KitColor.paper, padding: 14)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .kitScreen()
    }

    static func selfCheck() {
        // RideMode is the navigation path element (mode → source); it must be
        // Hashable and round-trip, or the wizard cannot advance.
        assert(RideMode.allCases.allSatisfy { RideMode(rawValue: $0.rawValue) != nil })
        assert(Set(RideMode.allCases).count == RideMode.allCases.count)
    }
}

extension RideMode {
    /// Kit's pixel mark for the mode (Figma v2 · 02).
    var kitIcon: String {
        switch self {
        case .fast: "kit-icon-bolt"
        case .moderate: "kit-icon-bike"
        case .leisure: "kit-icon-leaf"
        }
    }
}

/// The four ways to seed a route. Map presents the builder (which owns its own
/// NavigationStack) as a fullScreenCover; the three import paths parse a track,
/// plan it, and open a save preview.
private struct SourceStep: View {
    let mode: RideMode
    let onFinish: () -> Void

    /// One sheet, enum-driven — never two `.sheet` modifiers on one view. The
    /// workout picker swaps this to `.preview` in place, so there is no
    /// sheet-over-sheet race.
    private enum ActiveSheet: Identifiable {
        case workouts
        case preview(PreviewBox)
        var id: String {
            switch self {
            case .workouts:        return "workouts"
            case .preview(let b):  return b.id.uuidString
            }
        }
    }

    @State private var showingMap = false
    @State private var importingFile = false
    @State private var busy = false
    @State private var message: String?
    @State private var activeSheet: ActiveSheet?
    @State private var pendingBox: PreviewBox?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                KitHeader("Where does it come from?")
                VStack(spacing: 0) {
                    sourceRow(icon: "map", title: "Create from map") { showingMap = true }
                    rowDivider
                    sourceRow(icon: "doc.badge.plus", title: "Import a GPX file") { importingFile = true }
                    rowDivider
                    sourceRow(icon: "applewatch.side.right", title: "Import from Garmin / COROS") { activeSheet = .workouts }
                    rowDivider
                    sourceRow(icon: "arrow.down.doc", title: "Import from Strava (GPX export)") { importingFile = true }
                }
                .background(KitColor.paper)
                .overlay(Rectangle().strokeBorder(KitColor.ink, lineWidth: 2))
            }
            .padding(20)
        }
        .kitScreen()
        .fullScreenCover(isPresented: $showingMap) {
            // Builder owns its NavigationStack; Save closes the cover and the flow.
            RouteBuilderView(mode: mode) { showingMap = false; onFinish() }
        }
        .fileImporter(isPresented: $importingFile,
                      allowedContentTypes: [.xml, .init(filenameExtension: "gpx") ?? .xml],
                      allowsMultipleSelection: false) { result in
            Task { await handleFile(result) }
        }
        .overlay { if busy { ProgressView("Building route…").controlSize(.large) } }
        .alert("Import", isPresented: .constant(message != nil)) { Button("OK") { message = nil } } message: { Text(message ?? "") }
        .sheet(item: $activeSheet, onDismiss: { if let box = pendingBox { pendingBox = nil; activeSheet = .preview(box) } }) { sheet in
            switch sheet {
            case .workouts:
                WorkoutPicker(mode: mode) { box in pendingBox = box; activeSheet = nil }
            case .preview(let box):
                RoutePreview(name: box.name, waypoints: box.waypoints, plan: box.plan, mode: mode) { onFinish() }
            }
        }
    }

    private var rowDivider: some View {
        Rectangle().fill(KitColor.line).frame(height: 1)
    }

    private func sourceRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body)
                    .frame(width: 24)
                    .foregroundStyle(KitColor.ink)
                Text(title).font(.body)
                Spacer(minLength: 4)
                Image("kit-icon-chevron").renderingMode(.template).resizable()
                    .frame(width: 16, height: 16)
            }
            .foregroundStyle(KitColor.ink)
            .padding(.horizontal, 14)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func handleFile(_ result: Result<[URL], Error>) async {
        busy = true; defer { busy = false }
        do {
            guard let url = try result.get().first else { return }
            let parsed = try GPXParser.parse(url)
            let waypoints = parsed.makeWaypoints()
            guard waypoints.count >= 2 else { message = "No usable track in that file."; return }
            let plan = try await Routing.plan(through: waypoints, mode: mode)
            activeSheet = .preview(PreviewBox(name: parsed.name, waypoints: waypoints, plan: plan))
        } catch {
            message = error.localizedDescription
        }
    }
}

/// A built-but-unsaved route, carried into the save preview. Stable `id` so the
/// sheet presents once rather than thrashing on identity.
private struct PreviewBox: Identifiable {
    let id = UUID()
    let name: String
    let waypoints: [Coord]
    let plan: RoutePlan
}

/// Lists recent cycling workouts; the chosen one is thinned to waypoints and
/// planned into a Route preview.
private struct WorkoutPicker: View {
    @Environment(\.dismiss) private var dismiss
    let mode: RideMode
    let onBuilt: (PreviewBox) -> Void

    @State private var workouts: [HKWorkout] = []
    @State private var loading = true
    @State private var building = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if loading { ProgressView() }
                else if workouts.isEmpty {
                    ContentUnavailableView("No cycling workouts",
                        systemImage: "applewatch.slash",
                        description: Text("Garmin and COROS rides show up once their app has synced to Apple Health."))
                } else {
                    List(workouts, id: \.uuid) { w in
                        Button { Task { await build(w) } } label: {
                            VStack(alignment: .leading) {
                                Text(w.startDate.formatted(date: .abbreviated, time: .shortened))
                                Text(Fmt.km(w.statistics(for: HKQuantityType(.distanceCycling))?.sumQuantity()?.doubleValue(for: .meter()) ?? 0))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Pick a ride")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .overlay { if building { ProgressView("Building route…").controlSize(.large) } }
            .alert("Import", isPresented: .constant(error != nil)) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        }
        .task {
            loading = true
            workouts = (try? await Providers.recentCyclingWorkouts()) ?? []
            loading = false
        }
    }

    private func build(_ workout: HKWorkout) async {
        building = true; defer { building = false }
        do {
            let waypoints = try await Providers.waypoints(for: workout)
            guard waypoints.count >= 2 else { error = "That ride has no GPS track."; return }
            let plan = try await Routing.plan(through: waypoints, mode: mode)
            // Parent swaps the sheet to the preview in place; do not dismiss here.
            onBuilt(PreviewBox(name: "\(workout.startDate.formatted(date: .abbreviated, time: .omitted)) ride",
                               waypoints: waypoints, plan: plan))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Confirm the built route, name it, and save. Reuses RouteSketch for the shape.
private struct RoutePreview: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let name: String
    let waypoints: [Coord]
    let plan: RoutePlan
    let mode: RideMode
    let onSaved: () -> Void

    @State private var editedName: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                RouteSketch(coords: plan.polyline).frame(height: 160)
                FlowLayout {
                    Pill(text: Fmt.km(plan.distance))
                    Pill(text: Fmt.duration(plan.expected))
                    Pill(text: Difficulty.rated(distanceMeters: plan.distance, ascentMeters: plan.ascent).rawValue,
                         tint: Difficulty.rated(distanceMeters: plan.distance, ascentMeters: plan.ascent).color)
                    Pill(text: mode.rawValue, tint: KitColor.accentStrong)
                }
                TextField("Route name", text: $editedName).textFieldStyle(.roundedBorder)
                Spacer()
            }
            .padding(20)
            .navigationTitle("Save route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
            .onAppear { if editedName.isEmpty { editedName = name } }
        }
    }

    private func save() {
        let route = Route.make(name: editedName.isEmpty ? name : editedName,
                               mode: mode, waypoints: waypoints, plan: plan)
        route.scenicRaw = 0   // an imported ride is kept as ridden; re-plans don't bend it
        context.insert(route)
        try? context.save()
        dismiss()
        onSaved()
    }
}
