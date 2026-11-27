//
//  RouteListView.swift
//  cyclingskibidi
//
//  First screen on the board: search pinned to the top, filter chips and route
//  cards below. The `+` button launches the create-route wizard.
//

import SwiftUI
import SwiftData
import MapKit

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
    @Query(sort: \Route.createdAt, order: .reverse) private var routes: [Route]
    @Query(sort: \Ride.startedAt, order: .reverse) private var rides: [Ride]

    @State private var search = ""
    @State private var distance: DistanceFilter = .any
    @State private var duration: DurationFilter = .any
    @State private var difficulty: DifficultyFilter = .any

    @State private var creating = false
    @State private var showingStats = false
    @AppStorage("statsSeenCount") private var statsSeen = 0
    @State private var showingMarks = false
    @State private var showingCredits = false
    @State private var showingInterests = false
    @State private var showingSettings = false

    private var filtered: [Route] {
        routes.filter { r in
            distance.accepts(r.distanceMeters)
                && duration.accepts(r.currentExpectedSeconds)
                && difficulty.accepts(r.difficulty)
                && (search.isEmpty || r.name.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                filterBar
                if !filtered.isEmpty {
                    Text("\(filtered.count) \(filtered.count == 1 ? "route" : "routes")")
                        .font(.footnote).foregroundStyle(KitColor.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
        .kitScreen()
        .navigationTitle("Routes")
        .navigationDestination(for: Route.self) { RouteDetailView(route: $0) }
        .searchable(text: $search, placement: .toolbar, prompt: "Search...")
        .toolbar { toolbarItems }
        .sheet(isPresented: $creating) { CreateRouteFlow() }
        #if DEBUG
        .onAppear { if Demo.screen == "build" { creating = true } }
        #endif
        .sheet(isPresented: $showingStats) { StatsView() }
        .sheet(isPresented: $showingMarks) { MarksView() }
        .sheet(isPresented: $showingCredits) { CreditsView() }
        .sheet(isPresented: $showingInterests) { InterestsSheet() }
        .sheet(isPresented: $showingSettings) { SettingsView() }
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
                KitButton(title: "Create a route", style: .primary) { creating = true }
            }
        }
        .padding(.top, 40)
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showingStats = true; statsSeen = rides.count } label: {
                Label("Statistics", systemImage: "chart.bar.xaxis")
            }
            // New rides since the stats were last opened; gone once looked at.
            .badge(max(0, rides.count - statsSeen))
            .onChange(of: rides.count) { _, n in if n < statsSeen { statsSeen = n } }   // a deleted ride never hides the next one
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { showingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                Button { showingInterests = true } label: { Label("Your interests", systemImage: "heart") }
                Button { showingMarks = true } label: { Label("Your marks", systemImage: "exclamationmark.triangle") }
                Button { showingCredits = true } label: { Label("Credits", systemImage: "info.circle") }
            } label: { Label("More", systemImage: "ellipsis.circle") }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { creating = true } label: { Label("Create route", systemImage: "plus") }
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
            HStack(spacing: 6) {
                Text(isDefault ? title : value.rawValue)
                Image("kit-icon-chevron").renderingMode(.template).resizable()
                    .frame(width: 14, height: 14)
                    .rotationEffect(.degrees(90))
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(KitColor.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(isDefault ? KitColor.paper : KitColor.sage)
            .overlay(Rectangle().strokeBorder(KitColor.ink, lineWidth: 2))
            .environment(\.colorScheme, isDefault ? colorScheme : .light)   // only sage keeps dark ink
        }
        .buttonStyle(.plain)
    }

    private var isDefault: Bool { value.rawValue == "Any" }
    @Environment(\.colorScheme) private var colorScheme
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
            RouteMapPreview(coords: route.polyline)
                .frame(height: 100)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)

            Text(route.name)
                .font(.title3.weight(.semibold))
                .lineLimit(1)

            FlowLayout {
                KitChip(text: Fmt.km(route.distanceMeters), caps: false)
                KitChip(text: Fmt.duration(route.currentExpectedSeconds), caps: false)
                KitChip(text: route.difficulty.rawValue, caps: false)
                ModeTag(mode: route.mode)
            }
            .padding(.top, 10)
        }
        .kitCard()
        .contentShape(Rectangle())
    }
}

/// Kit's tag fills: light colours with dark ink in both themes.


extension RideMode {
    /// Each way to ride has its own colour; difficulty stays plain text.
    var tint: Color {
        switch self {
        case .fast: KitColor.terracotta
        case .moderate: KitColor.gold
        case .leisure: KitColor.sage
        }
    }
}

/// The ride mode as the emphasised tag: its pixel icon, bold, on the mode's colour.
struct ModeTag: View {
    let mode: RideMode
    var body: some View {
        HStack(spacing: 6) {
            Image(mode.kitIcon).renderingMode(.template).resizable().frame(width: 16, height: 16).accessibilityHidden(true)
            Text(mode.rawValue).font(.footnote.weight(.bold))
        }
        .foregroundStyle(KitColor.ink)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(mode.tint)
        .overlay(Rectangle().strokeBorder(KitColor.ink, lineWidth: 2))
        .environment(\.colorScheme, .light)   // light fills keep dark ink in both themes
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mode.rawValue) ride")
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
            let inset = 10.0
            let w = max(maxLon - minLon, 1e-6), h = max(maxLat - minLat, 1e-6)
            let scale = min((size.width - inset * 2) / w, (size.height - inset * 2) / h)
            let ox = (size.width - w * scale) / 2, oy = (size.height - h * scale) / 2

            var path = Path()
            var first: CGPoint?
            var last: CGPoint?
            for (i, c) in coords.enumerated() {
                let p = CGPoint(x: ox + (c.lon - minLon) * scale,
                                y: size.height - oy - (c.lat - minLat) * scale)
                if i == 0 {
                    path.move(to: p)
                    first = p
                } else {
                    path.addLine(to: p)
                }
                last = p
            }
            ctx.stroke(path, with: .color(KitColor.accentStrong),
                       style: .init(lineWidth: 3, lineCap: .butt, lineJoin: .miter))

            if let first {
                let square = CGRect(x: first.x - 5, y: first.y - 5, width: 10, height: 10)
                ctx.fill(Path(square), with: .color(KitColor.sage))
                ctx.stroke(Path(square), with: .color(KitColor.ink), style: .init(lineWidth: 2))
            }
            if let last {
                ctx.fill(Path(CGRect(x: last.x - 5, y: last.y - 5, width: 10, height: 10)),
                         with: .color(KitColor.ink))
            }
        }
        .background(KitColor.board)
    }
}

/// The route on a real Apple Maps picture of its surroundings (a snapshot, so a list of
/// cards stays cheap), with the line and start / end markers drawn on top. Cached per
/// route, size and theme; the plain sketch shows while it loads or with no signal.
struct RouteMapPreview: View {
    let coords: [Coord]
    @Environment(\.colorScheme) private var scheme
    @State private var image: UIImage?

    private static let cache = NSCache<NSString, UIImage>()

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image { Image(uiImage: image).resizable() } else { RouteSketch(coords: coords) }
            }
            .task(id: key(geo.size)) { image = await snapshot(geo.size) }
        }
        .clipShape(.rect(cornerRadius: 12))
        .accessibilityHidden(true)
    }

    private func key(_ size: CGSize) -> String {
        "\(coords.count)-\(coords.first.map { "\($0.lat),\($0.lon)" } ?? "")-\(coords.last.map { "\($0.lat),\($0.lon)" } ?? "")-\(Int(size.width))x\(Int(size.height))-\(scheme == .dark)"
    }

    private func snapshot(_ size: CGSize) async -> UIImage? {
        guard coords.count > 1, size.width > 0, size.height > 0 else { return nil }
        let k = key(size) as NSString
        if let hit = Self.cache.object(forKey: k) { return hit }
        let lats = coords.map(\.lat), lons = coords.map(\.lon)
        let options = MKMapSnapshotter.Options()
        options.size = size
        options.traitCollection = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        options.preferredConfiguration = MKStandardMapConfiguration(emphasisStyle: .muted)
        options.region = MKCoordinateRegion(
            center: .init(latitude: (lats.min()! + lats.max()!) / 2, longitude: (lons.min()! + lons.max()!) / 2),
            span: .init(latitudeDelta: max((lats.max()! - lats.min()!) * 1.5, 0.004),
                        longitudeDelta: max((lons.max()! - lons.min()!) * 1.5, 0.004)))
        guard let shot = try? await MKMapSnapshotter(options: options).start() else { return nil }
        let points = coords.map { shot.point(for: $0.cl) }
        let image = UIGraphicsImageRenderer(size: size).image { r in
            shot.image.draw(at: .zero)
            let c = r.cgContext
            c.setLineWidth(4); c.setLineCap(.round); c.setLineJoin(.round)
            c.setStrokeColor(UIColor.systemBlue.cgColor)
            c.addLines(between: points); c.strokePath()
            for (p, color) in [(points.first!, UIColor.systemGreen), (points.last!, UIColor.systemRed)] {
                let dot = CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)
                c.setFillColor(color.cgColor); c.fillEllipse(in: dot)
                c.setStrokeColor(UIColor.white.cgColor); c.setLineWidth(2); c.strokeEllipse(in: dot)
            }
        }
        Self.cache.setObject(image, forKey: k)
        return image
    }
}
