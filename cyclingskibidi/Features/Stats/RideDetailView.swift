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
                LabeledContent("When", value: ride.startedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Source", value: ride.source.rawValue)
                LabeledContent("Distance", value: Fmt.km(ride.distanceMeters))
                LabeledContent("Moving time", value: Fmt.clock(ride.movingSeconds))
                LabeledContent("Avg speed", value: Fmt.speed(ride.averageSpeed))
                LabeledContent("Max speed", value: Fmt.speed(ride.maxSpeed))
                LabeledContent("Climbed", value: "\(Int(ride.ascentMeters)) m")
                LabeledContent("Descended", value: "\(Int(ride.descentMeters)) m")
            }

            if elevation.count > 1 {
                Section("Elevation") { elevationChart.frame(height: 170) }
            }
            if speed.count > 1 {
                Section("Speed") { speedChart.frame(height: 170) }
            }
        }
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
        Map(initialPosition: .region(region)) {
            MapPolyline(coordinates: coords)
                .stroke(.blue, style: .init(lineWidth: 5, lineCap: .round, lineJoin: .round))
            if let start = coords.first {
                Marker("Start", systemImage: "flag.fill", coordinate: start).tint(.green)
            }
            if let end = coords.last {
                Marker("End", systemImage: "flag.checkered", coordinate: end).tint(.red)
            }
        }
        .mapStyle(.standard(elevation: .realistic))
    }

    private var elevationChart: some View {
        Chart(Array(elevation.enumerated()), id: \.offset) { _, p in
            AreaMark(x: .value("km", p.km), y: .value("m", p.alt))
                .interpolationMethod(.monotone)
                .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.6), .accentColor.opacity(0.05)],
                                                 startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("km", p.km), y: .value("m", p.alt))
                .interpolationMethod(.monotone)
                .foregroundStyle(Color.accentColor)
        }
        .chartXAxisLabel("km")
        .chartYAxisLabel("m")
    }

    private var speedChart: some View {
        Chart(Array(speed.enumerated()), id: \.offset) { _, p in
            LineMark(x: .value("min", p.min), y: .value("km/h", p.kmh))
                .interpolationMethod(.monotone)
                .foregroundStyle(Color.orange)
        }
        .chartXAxisLabel("min")
        .chartYAxisLabel("km/h")
    }
}
