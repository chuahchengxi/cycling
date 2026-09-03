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

    private var navigating: some View {
        ZStack(alignment: .top) {
            map
            GuidanceBanner(step: recorder.currentStep,
                           distance: recorder.distanceToManeuver,
                           offRoute: recorder.offRoute,
                           rerouting: recorder.rerouting)
                .padding(.horizontal, 12)
        }
        .overlay(alignment: .trailing) { sideButtons }
        .ignoresSafeArea(edges: .bottom)
        .onAppear(perform: begin)
        .sheet(isPresented: $showSheet) {
            navSheet
                .presentationDetents([.height(150), .fraction(0.45), .large], selection: $detent)
                .presentationBackgroundInteraction(.enabled)
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $reporting) {
            ObstacleReportView(coordinate: recorder.location ?? route.polyline.first?.cl)
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
            ForEach(obstacles) { obstacle in
                Annotation(obstacle.kind.rawValue, coordinate: obstacle.coordinate) {
                    ObstacleBadge(kind: obstacle.kind)
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
        .padding(.bottom, 180)
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
    }

    private func end() {
        let ride = recorder.finish()
        context.insert(ride)
        try? context.save()
        trip.finished = ride
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

/// Marked obstacles are the thing that syncs: drop one here and it is on every
/// other device signed into the same iCloud account, and on this route's brief
/// the next time anyone opens it.
struct ObstacleReportView: View {
    let coordinate: CLLocationCoordinate2D?

    @Environment(\.modelContext) private var context
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
                        context.insert(Obstacle(kind: kind, at: coordinate, note: note))
                        try? context.save()
                        dismiss()
                    }
                    .disabled(coordinate == nil)
                }
            }
        }
    }
}
