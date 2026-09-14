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
    @Environment(ObstacleStore.self) private var obstacleStore
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var camera: MapCameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
    @State private var detent: PresentationDetent = .height(150)
    @State private var line: [CLLocationCoordinate2D] = []
    @State private var reporting = false
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
                    if let message = obstacleStore.errorMessage {
                        ObstacleErrorBanner(message: message) { obstacleStore.errorMessage = nil }
                    }
                }
                .padding(.horizontal, 12)
            }
            .overlay(alignment: .bottomTrailing) {
                sideButtons.padding(.bottom, geo.safeAreaInsets.bottom + Self.collapsedSheet + 12)
            }
            .overlay { passBySight }
            .animation(.default, value: recorder.passingSight?.id)
            .animation(.default, value: obstacleStore.errorMessage)
            .ignoresSafeArea(edges: .bottom)
        }
        .onAppear(perform: begin)
        .sheet(isPresented: $showSheet) {
            navSheet
                .presentationDetents([.height(150), .fraction(0.45), .large], selection: $detent)
                .presentationBackgroundInteraction(.enabled)
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
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
        Map(position: $camera) {
            MapPolyline(coordinates: line)
                .stroke(.blue, style: .init(lineWidth: 7, lineCap: .round, lineJoin: .round))

            if let step = recorder.currentStep {
                Marker(step.maneuver.glyph, coordinate: step.coordinate).tint(.purple)
            }
            if let end = line.last {
                Marker("Finish", systemImage: "flag.checkered", coordinate: end).tint(.red)
            }
            ForEach(obstacleStore.obstacles) { obstacle in
                Annotation(obstacle.kind.rawValue, coordinate: obstacle.coordinate) {
                    ObstacleBadge(kind: obstacle.kind)
                }
            }
            ForEach(recorder.sights) { sight in
                Annotation(sight.name, coordinate: sight.coordinate) {
                    SightBadge(sight: sight)
                        .onTapGesture { recorder.passingSight = sight }
                }
            }
            UserAnnotation()
        }
        .mapStyle(.standard(elevation: .realistic))
        .mapControls { MapUserLocationButton() }
    }

    private var sideButtons: some View {
        VStack(spacing: 12) {
            CircleButton(symbol: "exclamationmark.triangle.fill", tint: .orange) { reporting = true }
            CircleButton(symbol: recorder.voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                         tint: .secondary) { recorder.voiceEnabled.toggle() }
            CircleButton(symbol: "location.north.fill", tint: .blue) {
                camera = .userLocation(followsHeading: true, fallback: .automatic)
            }
        }
        .padding(.trailing, 12)
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
        // Presented from inside the nav sheet, not beside it: two sibling sheets
        // on the same presenter is the "only a single sheet is supported" error.
        .sheet(isPresented: $reporting) {
            ObstacleReportView(coordinate: recorder.location ?? route.polyline.first?.cl) { kind, coord, note in
                Task { await obstacleStore.report(kind: kind, at: coord, note: note) }
            }
            .presentationDetents([.medium])
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
                Text("END TRIP")
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
        Task { await obstacleStore.load(around: route.polyline) }
    }

    private func end() {
        let ride = recorder.finish()
        context.insert(ride)
        try? context.save()
        trip.finished = ride
    }
}

// MARK: - Shared-hazard error

/// A dismissible notice when the shared-hazard store can't reach CloudKit
/// (offline, or not signed into iCloud) — so an empty map reads as "couldn't
/// load", not "no hazards here".
struct ObstacleErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "icloud.slash.fill").foregroundStyle(.orange)
            Text(message).font(.footnote).lineLimit(2)
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .shadow(radius: 4, y: 1)
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
            Image(systemName: offRoute ? "exclamationmark.triangle.fill" : (step?.maneuver.symbol ?? "arrow.up"))
                .font(.system(size: 40, weight: .semibold))
                .frame(width: 54)

            VStack(alignment: .leading, spacing: 2) {
                Text(offRoute ? (rerouting ? "Recalculating…" : "Off route") : Fmt.km(distance))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text(step?.instruction ?? "Follow the route")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(offRoute ? Color.orange : Color.primary)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 22))
        .shadow(radius: 8, y: 2)
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

/// Marked obstacles are shared with every rider: the store writes them to the
/// CloudKit public database, so one dropped here shows on this route's brief and
/// mid-ride for everyone who passes, not just this account's own devices.
struct ObstacleReportView: View {
    let coordinate: CLLocationCoordinate2D?
    /// Handed the mark to post; the parent forwards it to the shared store.
    var onReport: (ObstacleKind, CLLocationCoordinate2D, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: ObstacleKind = .pothole
    @State private var note = ""

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
            }
            .navigationTitle("Mark an obstacle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Mark") {
                        guard let coordinate else { return dismiss() }
                        onReport(kind, coordinate, note)
                        dismiss()
                    }
                    .disabled(coordinate == nil)
                }
            }
        }
    }
}
