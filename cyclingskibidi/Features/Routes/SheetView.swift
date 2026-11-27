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
    var closures: (active: [Closure], expired: [Closure]) = ([], [])
    var replanning = false
    var kitByModel = false
    var restLevel: RiderLevel = .regular
    @Binding var currentDetent: PresentationDetent
    var onStart: () -> Void
    var onReplan: () -> Void = {}
    /// Ride to this sight as a stop, or drop it. Nil hides the actions.
    var onAddStop: ((Sight) -> Void)? = nil
    var onRemoveStop: ((Sight) -> Void)? = nil

    @State private var selectedSight: Sight?
    /// No-bike crossings and walk stretches, worked out once per line off the main actor.
    @State private var noBike: (crossings: [(line: NoBikeLine?, along: Double, legLength: Double)], walk: [(name: String, along: Double, length: Double)]) = ([], [])

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
                        returnBikeLine
                        heatHint
                        climb
                        elevationGraph
                        if !noBike.crossings.isEmpty || !noBike.walk.isEmpty { noBikeList }
                        if closures.active.contains(where: { $0.kind == .closure }) || !closures.expired.isEmpty { closureList }
                        if !obstacles.isEmpty { obstacleList }
                        if !route.sights.isEmpty {
                            KitCard(count: route.sights.count, byModel: kitByModel)
                            sightList
                        }
                        if !route.restStops.isEmpty { restStopList }
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
        .task(id: [AnyHashable(route.polylineData)] + closures.active.map { AnyHashable($0.id) }) {
            let (polyline, found) = (route.polyline, route.noBikeCrossings)
            let walk = closures.active.filter { $0.kind == .noCycling }
            let circles = walk.flatMap(\.noGoCircles), names = walk.flatMap { c in c.noGoCircles.map { _ in c.name } }
            noBike = await Task.detached {
                let line = polyline.map(\.cl), cum = Geo.cumulative(line)
                return (found.map { NoBike.describe($0, on: line, cumulative: cum) },
                        NoBike.walkStretches(on: polyline, walk: circles, names: names))
            }.value
        }
    }

    // MARK: Pieces

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(Fmt.km(route.distanceMeters))
            summaryDivider
            Text(Fmt.duration(route.currentExpectedSeconds))
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

    /// When the ride ends at a bike place, say so: the rider knows where to
    /// put the bike back before they start looking for a rack.
    @ViewBuilder
    private var returnBikeLine: some View {
        if let last = route.waypoints.last,
           let line = PresetLoops.returnLine(for: last, in: Discovery.places) {
            Label(line, systemImage: "parkingsign")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(KitColor.accentStrong)
        }
    }

    /// Afternoon heat and storms matter on the slower, scenic rides; a Fast
    /// route brief stays as compact as before.
    @ViewBuilder
    private var heatHint: some View {
        if route.mode != .fast {
            VStack(alignment: .leading, spacing: 4) {
                Text(HeatHint.text)
                if let suggestion = HeatHint.shelterSuggestion(start: .now, stops: route.restStops) {
                    Text(suggestion)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
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

    /// Kit/chart · elevation (Figma v3 · 03): board fill, 2 pt ink border, sage bars, ochre steepest climb.
    @ViewBuilder
    private var elevationGraph: some View {
        let profile = route.elevations
        if profile.count > 1 {
            let bars = KitChart.buckets(profile), steepest = KitChart.steepestClimb(bars)
            // Floor just under the lowest point, so a 30 m climb still reads as a climb.
            let low = bars.min() ?? 0, high = max(bars.max() ?? 1, low + 1), floor = low - (high - low) * 0.25
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Elevation · climbs \(Int(route.ascentMeters)) m").font(.footnote.weight(.semibold))
                    Spacer()
                    Text(Fmt.km(route.distanceMeters)).font(.kitNumber(.headline))
                }
                Chart(Array(bars.enumerated()), id: \.offset) { i, metres in
                    let step = route.distanceKM / Double(bars.count)
                    RectangleMark(xStart: .value("Distance", (Double(i) + 0.15) * step),
                                  xEnd: .value("Distance", (Double(i) + 0.85) * step),
                                  yStart: .value("Elevation", floor), yEnd: .value("Elevation", metres))
                        .foregroundStyle(i == steepest ? KitColor.gold : KitColor.accentStrong)
                }
                .chartXScale(domain: 0...max(route.distanceKM, 0.1))
                .chartYScale(domain: floor...high)
                .chartYAxis(.hidden)
                .chartXAxis { AxisMarks { AxisValueLabel().font(.kitNumber(.caption2)).foregroundStyle(KitColor.muted) } }
                .frame(height: 120)
            }
            .foregroundStyle(KitColor.ink)
            .kitCard(KitColor.board)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Elevation profile")
            .accessibilityValue("Climbs \(Int(route.ascentMeters)) metres, from \(Int(profile.min() ?? 0)) up to \(Int(profile.max() ?? 0)) metres")
        } else {
            Text("No elevation data for this route.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// Closures as Kit's heads-up (Figma v3 · 03 "Kit · closed on your line").
    private var closureList: some View {
        let active = closures.active.filter { $0.kind == .closure }
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(active) { c in
                KitBubble(label: "Kit · closed on your line", text: "\(c.name) is closed. \(c.note)")
            }
            if !active.isEmpty {
                KitButton(title: replanning ? "Re-planning…" : active.count == 1 ? "Re-plan around it" : "Re-plan around them",
                          icon: "kit-icon-chevron", style: .tertiary, action: onReplan)
                    .disabled(replanning)
            }
            ForEach(closures.expired) { c in
                Label("\(c.name): was closed until \(c.untilText ?? "recently")", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// No bike path and walk-your-bike rows (Figma v3 · 13): terracotta where a straight
    /// leg crosses a no-bike way, gold where the rider must walk. The line is decoded once.
    @ViewBuilder
    private var noBikeList: some View {
        let (crossings, stretches) = noBike
        if !crossings.isEmpty || !stretches.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if let first = crossings.first {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("KIT · NO BIKE PATH HERE").font(.caption.weight(.bold)).tracking(1)
                        Text(NoBike.cardText(first)).font(.subheadline)
                    }
                    .foregroundStyle(KitColor.ink)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(KitColor.terracotta)
                    .overlay(Rectangle().stroke(KitColor.ink, lineWidth: 2))
                    .kitSurface()
                    .accessibilityElement(children: .combine)
                }
                ForEach(Array(crossings.enumerated()), id: \.offset) { _, c in
                    HStack(spacing: 12) {
                        RoadLabel(kind: c.line?.kind == "expressway" || c.line == nil ? .expressway : .noBikes)
                        Text("No bike path · \(Fmt.km(c.along))").font(.subheadline.weight(.semibold))
                    }
                }
                ForEach(Array(stretches.enumerated()), id: \.offset) { _, w in
                    HStack(spacing: 12) {
                        RoadLabel(kind: .walkYourBike)
                        VStack(alignment: .leading) {
                            Text("\(w.name) · \(Fmt.km(w.along))").font(.subheadline.weight(.semibold))
                            Text("No cycling here: walk your bike \(Int(w.length.rounded())) m.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
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
                        PixelIcon(rows: PixelArt.forCategory(sight.category), size: 24)
                            .foregroundStyle(KitColor.accentStrong).frame(width: 30)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sight.name).font(.body.weight(.semibold))
                            Text(sight.note ?? Discovery.icon(for: sight.category).label)
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(Fmt.km(sight.offsetAlong)).font(.footnote).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 52)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(sight.name), \(Discovery.icon(for: sight.category).label), \(Fmt.km(sight.offsetAlong))")
                // The brief is a scroll view, not a List, so swipe actions can't attach:
                // the same add / remove sit on long-press and in the VoiceOver actions rotor.
                .contextMenu { stopActions(sight) }
                .accessibilityActions { stopActions(sight) }
            }
        }
    }

    @ViewBuilder
    private func stopActions(_ sight: Sight) -> some View {
        if let onAddStop { Button("Add as a stop", systemImage: "plus.circle") { onAddStop(sight) } }
        if let onRemoveStop { Button("Remove from the route", systemImage: "minus.circle", role: .destructive) { onRemoveStop(sight) } }
    }

    /// Rest stops (spec section 3): water and toilets under 20 km, else spaced by the rider's level.
    private var restStopList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rest stops").font(.headline)
            Text((Geo.cumulative(route.polyline.map(\.cl)).last ?? 0) < 20_000 ? "Water and toilets on the way"
                 : { let w = RestStops.spacing(restLevel); return "A rest stop every \(Int(w.lowerBound / 1000))–\(Int(w.upperBound / 1000)) km for a \(restLevel.label.lowercased()) rider" }())
                .font(.subheadline).foregroundStyle(.secondary)
            ForEach(route.restStops) { stop in
                HStack(alignment: .top, spacing: 12) {
                    PixelIcon(rows: PixelArt.forCategory(stop.amenities.contains("drinkingWater") ? "drinkingWater" : stop.amenities.first ?? ""), size: 24)
                        .frame(width: 30).foregroundStyle(KitColor.accentStrong)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stop.name).font(.subheadline.weight(.semibold))
                        Text(stop.amenities.map { Discovery.icon(for: $0).label }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        if let warning = stop.warning {
                            Text(warning).font(.caption.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(KitColor.gold).foregroundStyle(KitColor.ink).kitSurface()
                        }
                    }
                    Spacer(minLength: 8)
                    if stop.sheltered {
                        Image(systemName: "umbrella.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                            .accessibilityLabel("Sheltered")
                    }
                    Text(Fmt.km(stop.offsetAlong)).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Rest stop, \(stop.name), \(Fmt.km(stop.offsetAlong)). \(stop.amenities.map { Discovery.icon(for: $0).label }.joined(separator: ", "))."
                                    + (stop.sheltered ? " Sheltered." : "") + (stop.warning.map { " \($0)" } ?? ""))
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

    /// Kit/button primary (Figma v3 · 03): the one sage button on the brief.
    private var startButton: some View {
        let disabled = route.polyline.count < 2 || replanning
        return KitButton(title: "Start ride", icon: "kit-icon-play", style: .primary, action: onStart)
            .disabled(disabled)
            .opacity(disabled ? 0.5 : 1)
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
                .foregroundStyle(KitColor.accentStrong)
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
