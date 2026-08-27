//
//  RouteListView.swift
//  cyclingskibidi
//
//  First screen on the board: filter chips across the top, route cards down the
//  page, search pinned to the bottom bar. Plus the two entry points the board
//  leaves off — building your own route, and pulling rides off a Garmin or COROS.
//

import SwiftUI
import SwiftData
import MapKit
import UniformTypeIdentifiers

// MARK: - Filters

enum DistanceFilter: String, CaseIterable, Identifiable {
    case any = "Any", under1 = "<1 km", oneToFive = "1 km - 5 km", overFive = ">5 km"
    var id: String { rawValue }

    func accepts(_ metres: Double) -> Bool {
        switch self {
        case .any: return true
        case .under1: return metres < 1000
        case .oneToFive: return metres >= 1000 && metres <= 5000
        case .overFive: return metres > 5000
        }
    }
}

enum DurationFilter: String, CaseIterable, Identifiable {
    case any = "Any", under30 = "< 30 mins", halfToHour = "30 mins - 1h", oneToTwo = "1h - 2h"
    var id: String { rawValue }

    func accepts(_ seconds: Double) -> Bool {
        switch self {
        case .any: return true
        case .under30: return seconds < 1800
        case .halfToHour: return seconds >= 1800 && seconds <= 3600
        case .oneToTwo: return seconds > 3600 && seconds <= 7200
        }
    }
}

enum DifficultyFilter: String, CaseIterable, Identifiable {
    case any = "Any", easy = "Easy", medium = "Medium", hard = "Hard"
    var id: String { rawValue }

    func accepts(_ d: Difficulty) -> Bool {
        self == .any || rawValue == d.rawValue
    }
}

// MARK: - Screen

struct RouteListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Route.createdAt, order: .reverse) private var routes: [Route]
    @Query(sort: \Ride.startedAt, order: .reverse) private var rides: [Ride]

    @State private var search = ""
    @State private var distance: DistanceFilter = .any
    @State private var duration: DurationFilter = .any
    @State private var difficulty: DifficultyFilter = .any

    @State private var building = false
    @State private var showingStats = false
    @State private var importingFile = false
    @State private var importMessage: String?
    @State private var importing = false

    private var filtered: [Route] {
        routes.filter { r in
            distance.accepts(r.distanceMeters)
                && duration.accepts(r.expectedSeconds)
                && difficulty.accepts(r.difficulty)
                && (search.isEmpty || r.name.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                filterBar
                if filtered.isEmpty {
                    emptyState
                } else {
                    ForEach(filtered) { route in
                        NavigationLink(value: route) {
                            RouteCard(route: route)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Routes")
        .navigationDestination(for: Route.self) { RouteDetailView(route: $0) }
        .searchable(text: $search, placement: .toolbar, prompt: "Search...")
        .searchToolbarBehavior(.minimize)
        .toolbar { toolbarItems }
        .sheet(isPresented: $building) { RouteBuilderView() }
        #if DEBUG
        .onAppear { if Demo.screen == "build" { building = true } }
        #endif
        .sheet(isPresented: $showingStats) { StatsView() }
        .fileImporter(isPresented: $importingFile,
                      allowedContentTypes: [.xml, .init(filenameExtension: "gpx") ?? .xml],
                      allowsMultipleSelection: true,
                      onCompletion: handleFiles)
        .alert("Import", isPresented: .constant(importMessage != nil)) {
            Button("OK") { importMessage = nil }
        } message: {
            Text(importMessage ?? "")
        }
        .overlay { if importing { ProgressView().controlSize(.large) } }
    }

    // MARK: Pieces

    private var filterBar: some View {
        HStack(spacing: 8) {
            FilterChip(title: "Distance", value: $distance)
            FilterChip(title: "Difficulty", value: $difficulty)
            FilterChip(title: "Duration", value: $duration)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(routes.isEmpty ? "No routes yet" : "Nothing matches",
                  systemImage: routes.isEmpty ? "point.topleft.down.to.point.bottomright.curvepath" : "line.3.horizontal.decrease.circle")
        } description: {
            Text(routes.isEmpty
                 ? "Drop pins on the map and we'll snap them to real roads."
                 : "Loosen a filter to see more routes.")
        } actions: {
            if routes.isEmpty {
                Button("Create a route") { building = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.top, 40)
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showingStats = true } label: {
                Label("Statistics", systemImage: "chart.bar.xaxis")
            }
            .badge(rides.count)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { building = true } label: { Label("Build a route", systemImage: "map") }
                Divider()
                Button { Task { await importHealth() } } label: {
                    Label("Import from Garmin / COROS", systemImage: "applewatch.side.right")
                }
                Button { importingFile = true } label: {
                    Label("Import a GPX file", systemImage: "doc.badge.plus")
                }
            } label: {
                Image(systemName: "plus")
            }
        }
    }

    // MARK: Imports

    private func importHealth() async {
        importing = true
        defer { importing = false }
        do {
            let n = try await Providers.importRides(into: context)
            importMessage = n == 0
                ? "No new cycling workouts found. Garmin and COROS rides show up here once their app has synced to Apple Health."
                : "Imported \(n) ride\(n == 1 ? "" : "s")."
        } catch {
            importMessage = "Could not read Apple Health: \(error.localizedDescription)"
        }
    }

    private func handleFiles(_ result: Result<[URL], Error>) {
        do {
            var count = 0
            for url in try result.get() {
                let parsed = try GPXParser.parse(url)
                guard !parsed.points.isEmpty else { continue }
                context.insert(parsed.makeRide())
                count += 1
            }
            try? context.save()
            importMessage = count == 0 ? "No track points in that file." : "Imported \(count) file\(count == 1 ? "" : "s")."
        } catch {
            importMessage = error.localizedDescription
        }
    }
}

// MARK: - Chips

private struct FilterChip<T: RawRepresentable & CaseIterable & Identifiable & Hashable>: View
where T.RawValue == String, T.AllCases: RandomAccessCollection {
    let title: String
    @Binding var value: T

    var body: some View {
        Menu {
            Picker(title, selection: $value) {
                ForEach(T.allCases) { Text($0.rawValue).tag($0) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(isDefault ? title : value.rawValue)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isDefault ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.tint.opacity(0.18)),
                        in: .capsule)
            .foregroundStyle(isDefault ? Color.primary : Color.accentColor)
        }
    }

    private var isDefault: Bool { value.rawValue == "Any" }
}

struct Pill: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.15), in: .capsule)
            .foregroundStyle(tint)
    }
}

// MARK: - Card

struct RouteCard: View {
    let route: Route

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RouteSketch(coords: route.polyline)
                .frame(height: 96)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)

            Text(route.name)
                .font(.title3.bold())
                .lineLimit(1)

            HStack(spacing: 8) {
                Pill(text: Fmt.km(route.distanceMeters))
                Pill(text: route.difficulty.rawValue, tint: route.difficulty.color)
                Pill(text: Fmt.duration(route.expectedSeconds))
            }
            .padding(.top, 8)
        }
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.separator))
        .contentShape(.rect)
    }
}

extension Difficulty {
    var color: Color {
        switch self {
        case .easy: return .green
        case .medium: return .orange
        case .hard: return .red
        }
    }
}

/// The route line normalised into the view's bounds. Cheaper than a live Map in
/// every scrolling cell, and it reads the way the wireframe's squiggle does.
struct RouteSketch: View {
    let coords: [Coord]

    var body: some View {
        Canvas { ctx, size in
            guard coords.count > 1 else { return }
            let lats = coords.map(\.lat), lons = coords.map(\.lon)
            guard let minLat = lats.min(), let maxLat = lats.max(),
                  let minLon = lons.min(), let maxLon = lons.max() else { return }

            // Keep the shape's aspect ratio; a squashed route is a lie about it.
            let inset = 8.0
            let w = max(maxLon - minLon, 1e-6), h = max(maxLat - minLat, 1e-6)
            let scale = min((size.width - inset * 2) / w, (size.height - inset * 2) / h)
            let ox = (size.width - w * scale) / 2, oy = (size.height - h * scale) / 2

            var path = Path()
            for (i, c) in coords.enumerated() {
                let p = CGPoint(x: ox + (c.lon - minLon) * scale,
                                y: size.height - oy - (c.lat - minLat) * scale)
                i == 0 ? path.move(to: p) : path.addLine(to: p)
            }
            ctx.stroke(path, with: .color(.accentColor), style: .init(lineWidth: 3, lineCap: .round, lineJoin: .round))

            if let start = path.currentPoint {
                ctx.fill(Path(ellipseIn: .init(x: start.x - 4, y: start.y - 4, width: 8, height: 8)),
                         with: .color(.red))
            }
        }
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
    }
}
