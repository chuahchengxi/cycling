//
//  SheetView.swift
//  cyclingskibidi
//
//  Created by cheng xi on 23/5/26.
//
//  The route brief. Collapsed it is the one line from the board — distance,
//  time, difficulty — over a START button. Expanded it adds the climb figures,
//  the elevation graph and the marked obstacles.
//

import SwiftUI
import Charts

struct SheetView: View {
    let route: Route
    var obstacles: [Obstacle] = []
    @Binding var currentDetent: PresentationDetent
    var onStart: () -> Void

    @State private var selectedSight: Sight?

    private var collapsed: Bool { currentDetent == .fraction(0.28) }

    var body: some View {
        VStack(spacing: 0) {
            if collapsed {
                summary.padding(.top, 24)
                Spacer(minLength: 12)
                startButton.padding([.horizontal, .bottom], 20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        summary
                        climb
                        elevationGraph
                        if !obstacles.isEmpty { obstacleList }
                        if !route.sights.isEmpty { sightList }
                        turnList
                    }
                    .padding(20)
                    .padding(.bottom, 90)
                }
                .safeAreaInset(edge: .bottom) {
                    startButton.padding([.horizontal, .bottom], 20)
                }
            }
        }
        .sheet(item: $selectedSight) { SightSheet(sight: $0) }
    }

    // MARK: Pieces

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(Fmt.km(route.distanceMeters))
            summaryDivider
            Text(Fmt.duration(route.expectedSeconds))
            summaryDivider
            Text(route.difficulty.rawValue).foregroundStyle(route.difficulty.color)
            Spacer(minLength: 0)
            Label(route.mode.rawValue, systemImage: route.mode.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)   // keep the mode on one line
        }
        .font(.title2.bold())
        .lineLimit(1)
        .minimumScaleFactor(0.75)   // shrink to fit rather than wrap ("Leisure"/"Moderate")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, collapsed ? 20 : 0)
    }

    /// A vertical rule whose centre sits on the row's text baseline, so the big
    /// metrics and the smaller mode label all line up rather than the mode text
    /// floating above the numbers.
    private var summaryDivider: some View {
        Divider()
            .frame(height: 22)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] }
    }

    private var climb: some View {
        HStack(spacing: 28) {
            Label("Uphill \(Int(route.ascentMeters)) m", systemImage: "arrow.up.right")
            Label("Downhill \(Int(route.descentMeters)) m", systemImage: "arrow.down.right")
        }
        .font(.headline)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var elevationGraph: some View {
        let profile = route.elevations
        VStack(alignment: .leading, spacing: 8) {
            Text("Elevation").font(.headline)
            if profile.count > 1 {
                Chart(Array(profile.enumerated()), id: \.offset) { index, metres in
                    AreaMark(
                        x: .value("Distance", Double(index) / Double(profile.count - 1) * route.distanceKM),
                        y: .value("Elevation", metres))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.6), .accentColor.opacity(0.05)],
                                                     startPoint: .top, endPoint: .bottom))
                    LineMark(
                        x: .value("Distance", Double(index) / Double(profile.count - 1) * route.distanceKM),
                        y: .value("Elevation", metres))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.accentColor)
                }
                .chartXAxisLabel("km")
                .chartYAxisLabel("m")
                .frame(height: 160)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Elevation profile")
                .accessibilityValue("Climbs \(Int(route.ascentMeters)) metres, from \(Int(profile.min() ?? 0)) up to \(Int(profile.max() ?? 0)) metres")
            } else {
                Text("No elevation data for this route.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(height: 60)
            }
        }
    }

    private var obstacleList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Marked on this route").font(.headline)
            ForEach(obstacles) { obstacle in
                HStack(spacing: 12) {
                    ObstacleBadge(kind: obstacle.kind)
                    VStack(alignment: .leading) {
                        Text(obstacle.kind.rawValue).font(.subheadline.weight(.semibold))
                        Text(obstacle.note.isEmpty
                             ? obstacle.reportedAt.formatted(.relative(presentation: .named))
                             : obstacle.note)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if obstacle.confirmations > 0 {
                        Text("\(obstacle.confirmations)×").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// The sights the ride passes, in the order they come up. Tapping one opens
    /// its brief; the same content pops up automatically when you ride past it.
    private var sightList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sights along the way").font(.headline)
            ForEach(route.sights) { sight in
                Button { selectedSight = sight } label: {
                    HStack(spacing: 12) {
                        Image(systemName: Discovery.icon(for: sight.category).symbol)
                            .font(.title3).frame(width: 30).foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sight.name).font(.subheadline.weight(.semibold))
                            Text(Discovery.icon(for: sight.category).label)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(Fmt.km(sight.offsetAlong)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var turnList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Directions").font(.headline)
            ForEach(route.steps) { step in
                StepRow(step: step, distanceLabel: Fmt.km(step.maneuverOffset))
            }
        }
    }

    private var startButton: some View {
        Button(action: onStart) {
            Text("Start Ride")
                .font(.title2.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 18))
        .disabled(route.polyline.count < 2)
    }
}

/// One line of the turn list: the arrow, the distance, the instruction.
struct StepRow: View {
    let step: StoredStep
    var distanceLabel: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: step.maneuver.symbol)
                .font(.title3)
                .frame(width: 30)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(distanceLabel).font(.subheadline.weight(.semibold))
                Text(step.instruction)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
