//
//  RideDetailView.swift
//  cyclingskibidi
//
//  One past ride, opened from the statistics list: the recorded track on a map,
//  the headline numbers, and elevation / speed graphs — all drawn from the GPS
//  trace already stored on the Ride in SwiftData, no refetch.
//

import SwiftUI
import Charts
import MapKit

struct RideDetailView: View {
    let ride: Ride

    var body: some View {
        List {
            if coords.count > 1 {
                Section {
                    map.frame(height: 220).listRowInsets(.init())
                }
            }

            Section("Summary") {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("When").font(.kitLabel).foregroundStyle(KitColor.muted)
                        Text(ride.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.subheadline.weight(.semibold))
                            .accessibilityLabel("When, \(ride.startedAt.formatted(date: .abbreviated, time: .shortened))")
                        Text("Source: \(ride.source.rawValue)")
                            .font(.caption).foregroundStyle(KitColor.muted)
                            .accessibilityLabel("Source, \(ride.source.rawValue)")
                    }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                        KitStat(value: Fmt.km(ride.distanceMeters), caption: "Distance")
                        KitStat(value: Fmt.clock(ride.movingSeconds), caption: "Moving time")
                        KitStat(value: Fmt.speed(ride.averageSpeed), caption: "Avg speed")
                        KitStat(value: Fmt.speed(ride.maxSpeed), caption: "Max speed")
                        KitStat(value: "\(Int(ride.ascentMeters)) m", caption: "Climbed")
                        KitStat(value: "\(Int(ride.descentMeters)) m", caption: "Descended")
                    }
                }
                .kitCard()
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            if elevation.count > 1 {
                Section("Elevation") {
                    elevationChart
                        .frame(height: 170)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
            if speed.count > 1 {
                Section("Speed") {
                    speedChart
                        .frame(height: 170)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .kitScreen()
        .navigationTitle(ride.routeName.isEmpty ? "Ride" : ride.routeName)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Data (all from the stored track)

    private var points: [TrackPoint] { ride.track }
    private var coords: [CLLocationCoordinate2D] { points.map(\.cl) }

    /// Down-sample so the charts stay snappy on a long ride.
    private func thin<T>(_ xs: [T], to limit: Int = 250) -> [T] {
        guard xs.count > limit else { return xs }
        return stride(from: 0, to: xs.count, by: xs.count / limit).map { xs[$0] }
    }

    /// (km along, altitude m) — altitude over distance.
    private var elevation: [(km: Double, alt: Double)] {
        let cum = Geo.cumulative(coords)
        return thin(Array(zip(cum, points))).map { (km: $0.0 / 1000, alt: $0.1.alt) }
    }

    /// (minutes, km/h) — speed over time.
    private var speed: [(min: Double, kmh: Double)] {
        thin(points).map { (min: $0.t / 60, kmh: max(0, $0.speed) * 3.6) }
    }

    /// Frame the whole track with a little air around it.
    private var region: MKCoordinateRegion {
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else {
            return MKCoordinateRegion(center: coords.first ?? .init(),
                                      latitudinalMeters: 2000, longitudinalMeters: 2000)
        }
        return MKCoordinateRegion(
            center: .init(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: .init(latitudeDelta: max((maxLat - minLat) * 1.4, 0.01),
                        longitudeDelta: max((maxLon - minLon) * 1.4, 0.01)))
    }

    // MARK: Pieces

    private var map: some View {
        OfflineMap(lines: [MapLine(coords: coords, color: .systemBlue, width: 5)],
                   pins: endPins(coords), initialRegion: region)
    }

    /// Kit/chart · elevation: board fill, 2 pt ink border, sage bars, ochre steepest climb.
    private var elevationChart: some View {
        let samples = elevation
        let steepest = Self.steepestClimb(in: samples)
        return Chart(Array(samples.enumerated()), id: \.offset) { i, p in
            BarMark(x: .value("km", p.km), y: .value("m", p.alt))
                .foregroundStyle(i == steepest ? KitColor.gold : KitColor.sage)
        }
        .chartXAxisLabel("km")
        .chartYAxisLabel("m")
        .foregroundStyle(KitColor.muted)
        .background(KitColor.board)
        .overlay(Rectangle().strokeBorder(KitColor.ink, lineWidth: 2))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Elevation profile")
        .accessibilityValue("Min \(Int(samples.map(\.alt).min() ?? 0)) m, max \(Int(samples.map(\.alt).max() ?? 0)) m, \(Int(ride.ascentMeters)) m climbed")
    }

    /// Point at the top of the steepest climb, so only that bar is ochre.
    private static func steepestClimb(in samples: [(km: Double, alt: Double)]) -> Int? {
        var bestDelta = 0.0
        var bestIndex: Int?
        for i in 1..<samples.count {
            let climb = samples[i].alt - samples[i - 1].alt
            if climb > bestDelta { bestDelta = climb; bestIndex = i }
        }
        return bestIndex
    }

    private var speedChart: some View {
        Chart(Array(speed.enumerated()), id: \.offset) { _, p in
            LineMark(x: .value("min", p.min), y: .value("km/h", p.kmh))
                .interpolationMethod(.monotone)
                .foregroundStyle(KitColor.sage)
        }
        .chartXAxisLabel("min")
        .chartYAxisLabel("km/h")
        .foregroundStyle(KitColor.muted)
        .background(KitColor.board)
        .overlay(Rectangle().strokeBorder(KitColor.ink, lineWidth: 2))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Speed over time")
        .accessibilityValue("Avg \(Fmt.speed(ride.averageSpeed)), max \(Fmt.speed(ride.maxSpeed))")
    }
}
