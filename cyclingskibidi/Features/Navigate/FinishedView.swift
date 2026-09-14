//
//  FinishedView.swift
//  cyclingskibidi
//
//  The end page, laid out the way the board draws it: FINISHED across the top,
//  then the map overview beside a column of distance / time / average speed,
//  the speed graph underneath, and Done at the bottom back to the route list.
//

import SwiftUI
import Charts
import MapKit

struct FinishedView: View {
    let ride: Ride
    let onDone: () -> Void

    private var track: [TrackPoint] { ride.track }

    var body: some View {
        VStack(spacing: 16) {
            header
            HStack(spacing: 12) {
                mapOverview
                    .frame(maxWidth: .infinity)
                statColumn
                    .frame(width: 150)
            }
            .frame(height: 280)

            speedGraph
                .frame(height: 200)

            Spacer(minLength: 0)

            Button(action: onDone) {
                Text("Done")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 16))
        }
        .padding(20)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: Pieces

    private var header: some View {
        Text("FINISHED")
            .font(.system(size: 30, weight: .heavy, design: .rounded))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(.tint.opacity(0.15), in: .rect(cornerRadius: 18))
            .foregroundStyle(.tint)
    }

    private var mapOverview: some View {
        Group {
            if track.count > 1 {
                Map(initialPosition: .region(region), interactionModes: []) {
                    MapPolyline(coordinates: track.map(\.cl))
                        .stroke(.blue, style: .init(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    if let start = track.first {
                        Marker("", systemImage: "flag.fill", coordinate: start.cl).tint(.green)
                    }
                    if let end = track.last {
                        Marker("", systemImage: "flag.checkered", coordinate: end.cl).tint(.red)
                    }
                }
            } else {
                ContentUnavailableView("No track", systemImage: "map")
            }
        }
        .clipShape(.rect(cornerRadius: 16))
    }

    private var statColumn: some View {
        VStack(spacing: 8) {
            StatBox(title: "Distance", value: String(format: "%.1f", ride.distanceKM), unit: "km")
            StatBox(title: "Time", value: Fmt.clock(ride.movingSeconds), unit: "")
            // The board gives average speed the tall box; it gets the climb
            // totals and the top speed as well, since there is room.
            VStack(spacing: 6) {
                Text("Avg speed").font(.caption).foregroundStyle(.secondary)
                Text(String(format: "%.1f", ride.averageSpeed * 3.6))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("km/h").font(.caption2).foregroundStyle(.secondary)
                Divider().padding(.horizontal, 12)
                Text("max \(String(format: "%.1f", ride.maxSpeed * 3.6)) km/h")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("↗ \(Int(ride.ascentMeters)) m   ↘ \(Int(ride.descentMeters)) m")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background, in: .rect(cornerRadius: 14))
        }
    }

    @ViewBuilder
    private var speedGraph: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Speed").font(.headline)
            if track.count > 2 {
                Chart(sampled, id: \.t) { point in
                    AreaMark(x: .value("Time", point.t / 60),
                             y: .value("Speed", point.speed * 3.6))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.55), .accentColor.opacity(0.05)],
                                                         startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Time", point.t / 60),
                             y: .value("Speed", point.speed * 3.6))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Color.accentColor)
                }
                .chartXAxisLabel("minutes")
                .chartYAxisLabel("km/h")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Speed over time")
                .accessibilityValue("Avg \(Fmt.speed(ride.averageSpeed)), max \(Fmt.speed(ride.maxSpeed))")
            } else {
                Text("Not enough data for a speed graph.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.background, in: .rect(cornerRadius: 16))
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

    private var region: MKCoordinateRegion {
        let lats = track.map(\.lat), lons = track.map(\.lon)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else {
            return .init(center: .init(latitude: 0, longitude: 0),
                         span: .init(latitudeDelta: 1, longitudeDelta: 1))
        }
        return .init(center: .init(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
                     span: .init(latitudeDelta: max((maxLat - minLat) * 1.4, 0.004),
                                 longitudeDelta: max((maxLon - minLon) * 1.4, 0.004)))
    }
}

struct StatBox: View {
    let title: String
    let value: String
    let unit: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.headline).monospacedDigit()
            if !unit.isEmpty { Text(unit).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(.background, in: .rect(cornerRadius: 14))
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
