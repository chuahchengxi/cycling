//
//  FinishedView.swift
//  cyclingskibidi
//
//  The end page (Figma v3 · 06 "Finished · Kit recap"): Kit pleased, "Nice ride.",
//  four native stat cards, the Kit speed bars, what Kit noted, then Share and Done.
//

import SwiftUI
import Charts

struct FinishedView: View {
    let ride: Ride
    /// What Kit learned on this ride, e.g. "More bridges, fewer cafés next time".
    var kitNote: String? = nil
    let onDone: () -> Void

    private var track: [TrackPoint] { ride.track }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image("kit-happy").resizable().interpolation(.none).frame(width: 96, height: 96).accessibilityHidden(true)
                Text("Nice ride.").font(.largeTitle.bold())
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    stat("Distance", Fmt.km(ride.distanceMeters))
                    stat("Moving", Fmt.duration(ride.movingSeconds))
                    stat("Avg speed", Fmt.speed(ride.averageSpeed))
                    stat("Climbed", "\(Int(ride.ascentMeters)) m")
                }
                speedGraph
                if let kitNote { KitBubble(label: "Kit · noted", text: kitNote) }
                HStack(spacing: 12) {
                    ShareLink(item: shareText) { KitButtonLabel(title: "Share", icon: "kit-icon-share") }
                        .buttonStyle(.plain)
                    KitButton(title: "Done", icon: "kit-icon-check", style: .primary, action: onDone)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 24)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    // MARK: Pieces

    private var subtitle: String {
        let when = ride.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        return ride.routeName.isEmpty ? when : "\(ride.routeName) · \(when)"
    }

    private var shareText: String {
        "\(ride.routeName.isEmpty ? "A ride" : ride.routeName): \(Fmt.km(ride.distanceMeters)) in \(Fmt.duration(ride.movingSeconds)), \(Fmt.speed(ride.averageSpeed)) average, \(Int(ride.ascentMeters)) m climbed."
    }

    /// Native card, as in the Figma frame: the stats are the rider's, not Kit's voice.
    private func stat(_ caption: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption).font(.footnote).foregroundStyle(.secondary)
            Text(value).font(.title2.bold()).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .combine)
    }

    /// Kit/chart (v3 · 06): board, 2 pt ink border, sage bars, the fastest stretch in ochre.
    @ViewBuilder
    private var speedGraph: some View {
        if track.count > 2 {
            let bars = KitChart.buckets(sampled.map { $0.speed * 3.6 })
            let fastest = bars.indices.max { bars[$0] < bars[$1] }
            let minutes = max((sampled.last?.t ?? 0) / 60, 0.1)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Speed · max \(Int((ride.maxSpeed * 3.6).rounded())) km/h").font(.footnote.weight(.semibold))
                    Spacer()
                    Text(Fmt.duration(ride.movingSeconds)).font(.kitNumber(.headline))
                }
                Chart(Array(bars.enumerated()), id: \.offset) { i, kmh in
                    let step = minutes / Double(bars.count)
                    RectangleMark(xStart: .value("Minutes", (Double(i) + 0.15) * step), xEnd: .value("Minutes", (Double(i) + 0.85) * step),
                                  yStart: .value("km/h", 0), yEnd: .value("km/h", kmh))
                        .foregroundStyle(i == fastest ? KitColor.gold : KitColor.accentStrong)
                }
                .chartXScale(domain: 0...minutes)
                .chartYAxis(.hidden)
                .chartXAxis { AxisMarks { AxisValueLabel().font(.kitNumber(.caption2)).foregroundStyle(KitColor.muted) } }
                .frame(height: 110)
            }
            .foregroundStyle(KitColor.ink)
            .kitCard(KitColor.board)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Speed over time")
            .accessibilityValue("Avg \(Fmt.speed(ride.averageSpeed)), max \(Fmt.speed(ride.maxSpeed))")
        }
    }

    /// A 1 Hz track over two hours is 7000 points; the chart only needs a few
    /// hundred, and smoothing them makes the line readable instead of hairy.
    private var sampled: [TrackPoint] {
        guard track.count > 240 else { return track }
        let stride = track.count / 240
        return Swift.stride(from: 0, to: track.count, by: stride).map { i in
            let window = track[i..<min(i + stride, track.count)]
            var point = track[i]
            point.speed = window.map(\.speed).reduce(0, +) / Double(window.count)
            return point
        }
    }
}

#Preview {
    let ride = Ride(routeName: "Sample")
    ride.distanceMeters = 25_400
    ride.movingSeconds = 3720
    ride.maxSpeed = 11.2
    ride.ascentMeters = 143
    return FinishedView(ride: ride) {}
}
