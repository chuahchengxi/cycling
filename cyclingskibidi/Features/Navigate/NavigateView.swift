//
//  NavigateView.swift
//  cyclingskibidi
//
//  Turn-by-turn. Guidance banner across the top, the route under a
//  heading-locked camera, and a sheet that goes from a single progress line, to
//  the pause / end controls, to the full turn list. Ending the trip swaps this
//  screen for the finished screen — the conditional render on the board.
//

import SwiftUI
import SwiftData
import MapKit

struct NavigateView: View {
    let route: Route

    @Environment(Trip.self) private var trip
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var obstacles: [Obstacle]

    @State private var focus: MapFocus? = .user(heading: true)
    @State private var detent: PresentationDetent = .height(150)
    @State private var line: [CLLocationCoordinate2D] = []
    @State private var placing = false
    @State private var pending: PendingObstacle?
    @State private var showSheet = true

    private var recorder: RideRecorder { trip.recorder }

    var body: some View {
        Group {
            if let ride = trip.finished {
                FinishedView(ride: ride) {
                    trip.clear()
                    dismiss()
                }
            } else {
                navigating
            }
        }
        .animation(.default, value: trip.finished == nil)
    }

    // MARK: Navigating

    /// Collapsed nav-sheet detent. The side buttons clear this plus the home-
    /// indicator inset the sheet sits on, so the bottom one isn't tucked under it.
    private static let collapsedSheet: CGFloat = 150

    private var navigating: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                map
                VStack(spacing: 8) {
                    GuidanceBanner(step: recorder.currentStep,
                                   distance: recorder.distanceToManeuver,
                                   offRoute: recorder.offRoute,
                                   rerouting: recorder.rerouting)
                    if let failure = recorder.rerouteFailure {
                        RerouteFailureBanner(message: failure) { recorder.dismissRerouteFailure() }
                    }
                    if let hazard = recorder.nearHazard {
                        HazardBanner(alert: hazard).transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 12)
            }
            .overlay(alignment: .bottomTrailing) {
                sideButtons.padding(.bottom, geo.safeAreaInsets.bottom + Self.collapsedSheet + 12)
            }
            .overlay { passBySight }
            .overlay(alignment: .bottom) { if placing { placementBar } }
            .animation(.default, value: recorder.passingSight?.id)
            .animation(.default, value: placing)
            .animation(.default, value: recorder.nearHazard == nil)
            .ignoresSafeArea(edges: .bottom)
        }
        .onAppear(perform: begin)
        // Every marked hazard warns on approach, whatever route is being ridden.
        .onChange(of: obstacles, initial: true) { recorder.hazards = obstacles.filter(\.isActive) }
        .sheet(isPresented: $showSheet) {
            navSheet
                .presentationDetents([.height(150), .fraction(0.45), .large], selection: $detent)
                .presentationBackgroundInteraction(.enabled)
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
        }
        // Presented from the main nav view, never stacked on the persistent nav
        // sheet — that sheet is hidden while placing, so the two never coexist.
        .sheet(item: $pending, onDismiss: { showSheet = true }) { item in
            ObstacleReportView(coordinate: item.coordinate, onSaveClosed: recorder.rerouteAround)
                .presentationDetents([.medium])
        }
        .alert("Location is off", isPresented: .constant(recorder.authorizationDenied)) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("End trip", role: .cancel) { end() }
        } message: {
            Text("Turn-by-turn needs your location while you ride.")
        }
    }

    /// The pass-by card: when the ride reaches a sight, its brief pops over the
    /// map on a dim scrim — tap outside or the close button to dismiss.
    @ViewBuilder
    private var passBySight: some View {
        if let sight = recorder.passingSight {
            ZStack {
                Color.black.opacity(0.25).ignoresSafeArea()
                    .onTapGesture { recorder.passingSight = nil }
                PassBySightCard(sight: sight) { recorder.passingSight = nil }
                    .padding(.horizontal, 20)
            }
            .transition(.opacity)
        }
    }

    private var map: some View {
        // Only taps while placing do anything; pan/zoom are untouched.
        OfflineMap(lines: [MapLine(coords: line, color: .systemBlue, width: 7)],
                   pins: mapPins, focus: focus, showsUser: true,
                   onTap: { coord in if placing { place(at: coord) } })
    }

    private var mapPins: [MapPin] {
        var pins: [MapPin] = []
        if let step = recorder.currentStep {
            pins.append(MapPin(id: "step", coordinate: step.coordinate, title: step.instruction,
                               look: .marker(symbol: step.maneuver.symbol, tint: .systemPurple)))
        }
        if let end = line.last {
            pins.append(MapPin(id: "finish", coordinate: end, title: "Finish", look: .marker(symbol: "flag.checkered", tint: .systemRed)))
        }
        pins += obstacles.filter(\.isActive).map { o in
            MapPin(id: o.pinID, coordinate: o.coordinate, title: o.kind.rawValue, look: .view(AnyView(ObstacleBadge(kind: o.kind))))
        }
        if let pending {
            pins.append(MapPin(id: "pending", coordinate: pending.coordinate, title: "New obstacle",
                               look: .marker(symbol: "exclamationmark.triangle.fill", tint: .systemOrange)))
        }
        pins += recorder.sights.map { sight in
            MapPin(id: sight.id.uuidString, coordinate: sight.coordinate, title: sight.name,
                   look: .view(AnyView(SightBadge(sight: sight))), onTap: { recorder.passingSight = sight })
        }
        return pins
    }

    private var sideButtons: some View {
        VStack(spacing: 12) {
            CircleButton(symbol: "exclamationmark.triangle.fill", tint: .orange) {
                placing = true
                showSheet = false
            }
            .accessibilityLabel("Mark obstacle")
            CircleButton(symbol: recorder.voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                         tint: .secondary) { recorder.voiceEnabled.toggle() }
            .accessibilityLabel(recorder.voiceEnabled ? "Mute guidance" : "Unmute guidance")
            CircleButton(symbol: "location.north.fill", tint: .blue) {
                focus = .user(heading: true)
            }
            .accessibilityLabel("Recenter map")
        }
        .padding(.trailing, 12)
    }

    /// Compact placement prompt shown while the rider is choosing a hazard spot.
    private var placementBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.tap.fill")
            Text("Tap the blue route to place the obstacle")
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 8)
            Button("Cancel") { placing = false; pending = nil; showSheet = true }
                .font(.subheadline.bold())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: .capsule)
        .shadow(radius: 8, y: 2)
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }

    // MARK: Sheet

    private var navSheet: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Fmt.km(recorder.remainingDistance)).font(.title.bold())
                    Text("to go").font(.caption2).foregroundStyle(.secondary)
                }
                Divider().frame(height: 34)
                VStack(alignment: .leading, spacing: 0) {
                    Text(Fmt.clock(recorder.remainingSeconds)).font(.title.bold())
                    Text("left").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(Fmt.eta(recorder.remainingSeconds)).font(.headline)
                    Text("arrival").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)

            ProgressView(value: recorder.progress)
                .padding(.horizontal, 20)
                .padding(.top, 10)

            if detent != .height(150) {
                controls.padding(.top, 18)
            }
            if detent == .large {
                Divider().padding(.top, 12)
                turnList
            }
            Spacer(minLength: 0)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 24) {
                Stat(title: "Distance", value: Fmt.km(recorder.distance))
                Stat(title: "Moving", value: Fmt.clock(recorder.movingSeconds))
                Stat(title: "Speed", value: Fmt.speed(recorder.speed))
            }

            Button {
                recorder.phase == .running ? recorder.pause() : recorder.resume()
            } label: {
                Label(recorder.phase == .running ? "Pause" : "Resume",
                      systemImage: recorder.phase == .running ? "pause.fill" : "play.fill")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 18))

            Button(action: end) {
                Text("End Ride")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .buttonBorderShape(.roundedRectangle(radius: 18))
        }
        .padding(.horizontal, 20)
    }

    private var turnList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(recorder.upcomingSteps) { step in
                    StepRow(step: step,
                            distanceLabel: Fmt.km(max(0, step.maneuverOffset - recorder.distanceAlong)))
                }
            }
            .padding(20)
        }
    }

    // MARK: Actions

    private func begin() {
        line = route.polyline.coordinates
        recorder.onReroute = { plan in line = plan.polyline.coordinates }
        recorder.start()
    }

    /// Snap the tapped point onto the displayed route and stage it for the form.
    /// No GPS or route-start fallback: a tap that can't snap places nothing.
    private func place(at coord: CLLocationCoordinate2D) {
        guard let snapped = Geo.snap(coord, to: line, cumulative: Geo.cumulative(line))?.coordinate
        else { return }
        placing = false
        pending = PendingObstacle(coordinate: snapped)
    }

    private func end() {
        let ride = recorder.finish()
        context.insert(ride)
        try? context.save()
        trip.finished = ride
    }
}

// MARK: - Pass-by sight

/// The sight brief that pops up as the rider passes it: a title row with a close
/// button over the shared SightDetail. Wraps the same content the pre-ride list
/// shows, styled as a floating card rather than a system sheet (the nav screen
/// already owns a persistent sheet).
struct PassBySightCard: View {
    let sight: Sight
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(sight.name).font(.title3.bold())
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2).foregroundStyle(.secondary)
                }
            }
            SightDetail(sight: sight)
        }
        .padding(18)
        .background(.regularMaterial, in: .rect(cornerRadius: 22))
        .shadow(radius: 8, y: 2)
    }
}

// MARK: - Banner

struct GuidanceBanner: View {
    let step: StoredStep?
    let distance: Double
    let offRoute: Bool
    let rerouting: Bool

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: rerouting ? "arrow.triangle.2.circlepath" : (offRoute ? "exclamationmark.triangle.fill" : (step?.maneuver.symbol ?? "arrow.up")))
                .font(.system(.largeTitle, weight: .semibold))
                .frame(width: 54)

            VStack(alignment: .leading, spacing: 2) {
                // Rerouting always wins the headline, whether it was triggered by
                // drifting off the line or by marking a closure on it.
                Text(rerouting ? "Recalculating…" : (offRoute ? "Off route" : Fmt.km(distance)))
                    .font(.system(.title, design: .rounded, weight: .bold))
                Text(step?.instruction ?? "Follow the route")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle((rerouting || offRoute) ? Color.orange : Color.primary)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 22))
        .shadow(radius: 8, y: 2)
    }
}

/// A reroute that couldn't find a way around a closure: shown inline until the
/// rider explicitly dismisses it, never auto-dismissed and never a modal alert
/// so it doesn't block the map.
struct RerouteFailureBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 8)
            Button("Dismiss", action: onDismiss)
                .font(.subheadline.bold())
        }
        .foregroundStyle(Color.orange)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
        .shadow(radius: 8, y: 2)
    }
}

/// A marked hazard close by: what it is, how far, and the rider's note.
struct HazardBanner: View {
    let alert: HazardAlert

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: alert.kind.symbol).font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(alert.kind.rawValue) · \(Fmt.km(alert.distance))").font(.headline)
                if !alert.note.isEmpty {
                    Text(alert.note).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.orange)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
        .shadow(radius: 8, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Caution: \(alert.kind.rawValue), \(Fmt.km(alert.distance)) away. \(alert.note)")
    }
}

// MARK: - Bits

struct CircleButton: View {
    let symbol: String
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.headline)
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: .circle)
                .foregroundStyle(tint)
        }
        .shadow(radius: 3)
    }
}

struct Stat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.bold()).monospacedDigit()
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Marking an obstacle

/// The snapped spot awaiting the type/note form. Identifiable so it drives the
/// form via `.sheet(item:)` and also the orange preview marker on the map.
private struct PendingObstacle: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
}

/// Mark an obstacle and keep it on this device: it warns on every later ride,
/// and a "Path closed" mark is avoided by every route from now on.
struct ObstacleReportView: View {
    let coordinate: CLLocationCoordinate2D?
    /// Fired after persisting a `.closed` obstacle, so the live ride can
    /// reroute around it. Other kinds only save.
    var onSaveClosed: (CLLocationCoordinate2D) -> Void = { _ in }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ObstacleKind = .pothole
    @State private var note = ""
    @State private var keep: Keep = .week

    /// How long the mark lasts: through the last day, or until the rider removes it.
    enum Keep: Int, CaseIterable, Identifiable {
        case today = 0, threeDays = 2, week = 7, month = 30, untilRemoved = -1
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .today: return "Today"
            case .threeDays: return "3 days"
            case .week: return "1 week"
            case .month: return "1 month"
            case .untilRemoved: return "Until I remove it"
            }
        }
        var lastDay: Date? {
            self == .untilRemoved ? nil : Closures.sg.date(byAdding: .day, value: rawValue, to: Closures.now)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("What's there?") {
                    Picker("Type", selection: $kind) {
                        ForEach(ObstacleKind.allCases) { k in
                            Label(k.rawValue, systemImage: k.symbol).tag(k)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("Note (optional)") {
                    TextField("e.g. deep, on the left", text: $note, axis: .vertical)
                }
                Section {
                    Picker("Keep it", selection: $keep) {
                        ForEach(Keep.allCases) { Text($0.label).tag($0) }
                    }
                } footer: {
                    Text("Remove it sooner from Your marks once it's cleared.")
                }
            }
            .navigationTitle("Obstacle Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let coordinate else { return dismiss() }
                        let mark = Obstacle(kind: kind, at: coordinate, note: note)
                        mark.expiresAt = keep.lastDay
                        context.insert(mark)
                        try? context.save()
                        if kind == .closed { onSaveClosed(coordinate) }
                        dismiss()
                    }
                    .disabled(coordinate == nil)
                }
            }
        }
    }
}
