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

    var mode: RideMode = .moderate
    var onSaved: (() -> Void)? = nil

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var mapRegion: MKCoordinateRegion?
    @State private var waypoints: [Coord] = []
    @State private var plan = RoutePlan()
    @State private var planning = false
    @State private var error: String?
    @State private var name = ""
    @State private var naming = false
    @State private var planTask: Task<Void, Never>?

    /// Search, so a route can start from an address instead of a lucky tap.
    @State private var query = ""
    @State private var results: [MKMapItem] = []

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
                        .disabled(plan.polyline.isEmpty)
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

    // MARK: Actions

    /// Re-routes on every pin change. The previous attempt is cancelled so a
    /// quick run of taps only pays for the last one.
    private func replan() {
        planTask?.cancel()
        guard waypoints.count >= 2 else { plan = RoutePlan(); planning = false; return }
        planning = true
        planTask = Task {
            do {
                let fresh = try await Routing.plan(through: waypoints, mode: mode)
                guard !Task.isCancelled else { return }
                plan = fresh
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            planning = false
        }
    }

    private func save() {
        let route = Route.make(
            name: name.isEmpty ? "Route \(Date.now.formatted(date: .abbreviated, time: .shortened))" : name,
            mode: mode, waypoints: waypoints, plan: plan)
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
        .modelContainer(for: [Route.self, Obstacle.self, Ride.self], inMemory: true)
}
