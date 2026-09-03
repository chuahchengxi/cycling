//
//  Providers.swift
//  cyclingskibidi
//
//  Pulling rides in from other head units.
//
//  Garmin and COROS both mirror every ride into Apple Health, including the GPS
//  route, so HealthKit is the import path: it needs no developer-program
//  approval, no OAuth, no API key, and it covers Wahoo, Peloton and the Watch
//  for free. GPX import is the escape hatch for anything that only exports files.
//

import Foundation
import HealthKit
import CoreLocation
import SwiftData

@MainActor
enum Providers {

    static let store = HKHealthStore()

    static var healthAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    static func requestAuthorization() async throws {
        guard healthAvailable else { return }
        let types: Set = [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
            HKQuantityType(.distanceCycling),
        ]
        try await store.requestAuthorization(toShare: [], read: types as Set<HKObjectType>)
    }

    /// Imports every cycling workout not already stored. Returns how many were new.
    @discardableResult
    static func importRides(into context: ModelContext, limit: Int = 100) async throws -> Int {
        guard healthAvailable else { return 0 }
        try await requestAuthorization()

        let descriptor = HKSampleQueryDescriptor(
            predicates: [HKSamplePredicate.workout(HKQuery.predicateForWorkouts(with: .cycling))],
            sortDescriptors: [SortDescriptor(\HKWorkout.startDate, order: .reverse)],
            limit: limit)
        let workouts: [HKWorkout] = try await descriptor.result(for: store)

        let existing = Set((try? context.fetch(FetchDescriptor<Ride>()))?.map(\.externalID) ?? [])
        var imported = 0

        for workout in workouts {
            let key = workout.uuid.uuidString
            guard !existing.contains(key) else { continue }

            let source = RideSource.from(sourceName: workout.sourceRevision.source.name)
            let ride = Ride(startedAt: workout.startDate,
                            routeName: "\(source.rawValue) ride",
                            source: source)
            ride.externalID = key
            ride.endedAt = workout.endDate
            ride.movingSeconds = workout.duration
            ride.distanceMeters = workout.statistics(for: HKQuantityType(.distanceCycling))?
                .sumQuantity()?.doubleValue(for: .meter()) ?? 0

            let locations = try await locations(for: workout)
            if !locations.isEmpty {
                let t0 = locations[0].timestamp
                ride.trackData = Blob.encode(locations.map {
                    TrackPoint(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude,
                               alt: $0.altitude, t: $0.timestamp.timeIntervalSince(t0),
                               speed: max(0, $0.speed))
                })
                ride.maxSpeed = locations.map { max(0, $0.speed) }.max() ?? 0
                if ride.distanceMeters == 0 {
                    ride.distanceMeters = zip(locations, locations.dropFirst())
                        .reduce(0) { $0 + $1.1.distance(from: $1.0) }
                }
                let climb = Geo.climb(locations.map(\.altitude))
                ride.ascentMeters = climb.up
                ride.descentMeters = climb.down
            }
            // The watch's barometer beats anything derived from GPS altitude.
            if let ascent = workout.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity {
                ride.ascentMeters = ascent.doubleValue(for: .meter())
            }

            context.insert(ride)
            imported += 1
        }
        if imported > 0 { try? context.save() }
        return imported
    }

    /// A workout's GPS trace, stitched back together from its route series.
    private static func locations(for workout: HKWorkout) async throws -> [CLLocation] {
        let routeDescriptor = HKAnchoredObjectQueryDescriptor(
            predicates: [HKSamplePredicate.workoutRoute(HKQuery.predicateForObjects(from: workout))],
            anchor: nil)
        let routes: [HKWorkoutRoute] = try await routeDescriptor.result(for: store).addedSamples

        var all: [CLLocation] = []
        for route in routes {
            all.append(contentsOf: try await locations(in: route))
        }
        return all.sorted { $0.timestamp < $1.timestamp }
    }

    /// HKWorkoutRouteQuery streams a long route in batches and only stops when
    /// it says `done`, so the continuation has to survive several callbacks.
    private static func locations(in route: HKWorkoutRoute) async throws -> [CLLocation] {
        try await withCheckedThrowingContinuation { continuation in
            var collected: [CLLocation] = []
            var finished = false
            let query = HKWorkoutRouteQuery(route: route) { _, batch, done, error in
                guard !finished else { return }
                if let error {
                    finished = true
                    continuation.resume(throwing: error)
                    return
                }
                collected.append(contentsOf: batch ?? [])
                if done {
                    finished = true
                    continuation.resume(returning: collected)
                }
            }
            store.execute(query)
        }
    }
}

// MARK: - GPX / TCX

/// Minimal GPX reader: track points for a recorded ride, route/waypoints for a
/// planned one. Handles the `<trkpt>`, `<rtept>` and `<wpt>` forms every head
/// unit exports.
/// ponytail: XML only. Garmin's raw `.fit` is a binary container and needs a
/// real parser — add one if riders start dropping .fit files in.
final class GPXParser: NSObject, XMLParserDelegate {
    private(set) var points: [TrackPoint] = []
    private(set) var name = ""

    private var element = ""
    private var text = ""
    private var lat = 0.0, lon = 0.0, ele = 0.0
    private var time: Date?
    private var firstTime: Date?
    private var inPoint = false
    private var readingName = false

    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parse(_ url: URL) throws -> GPXParser {
        // Files handed over by the document picker are security-scoped.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let parser = GPXParser()
        let xml = XMLParser(data: try Data(contentsOf: url))
        xml.delegate = parser
        guard xml.parse() else { throw xml.parserError ?? CocoaError(.fileReadCorruptFile) }
        if parser.name.isEmpty { parser.name = url.deletingPathExtension().lastPathComponent }
        return parser
    }

    func parser(_ parser: XMLParser, didStartElement e: String, namespaceURI: String?,
                qualifiedName: String?, attributes attrs: [String: String] = [:]) {
        element = e
        text = ""
        switch e {
        case "trkpt", "rtept", "wpt", "Trackpoint":
            inPoint = true
            lat = Double(attrs["lat"] ?? "") ?? 0
            lon = Double(attrs["lon"] ?? "") ?? 0
            ele = 0
            time = nil
        case "name" where !inPoint && name.isEmpty:
            readingName = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch e {
        case "ele", "AltitudeMeters": ele = Double(value) ?? 0
        case "time", "Time":
            time = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        case "LatitudeDegrees":  lat = Double(value) ?? lat
        case "LongitudeDegrees": lon = Double(value) ?? lon
        case "name" where readingName:
            name = value
            readingName = false
        case "trkpt", "rtept", "wpt", "Trackpoint":
            inPoint = false
            guard lat != 0 || lon != 0 else { return }
            if firstTime == nil { firstTime = time }
            let offset = (time?.timeIntervalSince(firstTime ?? time ?? .now)) ?? Double(points.count)
            points.append(TrackPoint(lat: lat, lon: lon, alt: ele, t: offset, speed: 0))
        default: break
        }
        text = ""
    }

    /// Fills in the speeds GPX leaves out, then builds a Ride.
    func makeRide() -> Ride {
        let ride = Ride(startedAt: firstTime ?? .now, routeName: name, source: .gpx)
        ride.externalID = "gpx:\(name):\(points.first?.t ?? 0):\(points.count)"

        var filled = points
        var distance = 0.0
        for i in 1..<max(points.count, 1) {
            let a = CLLocation(latitude: filled[i - 1].lat, longitude: filled[i - 1].lon)
            let b = CLLocation(latitude: filled[i].lat, longitude: filled[i].lon)
            let d = b.distance(from: a)
            distance += d
            let dt = filled[i].t - filled[i - 1].t
            filled[i].speed = dt > 0 ? d / dt : 0
        }
        let climb = Geo.climb(filled.map(\.alt))
        ride.distanceMeters = distance
        ride.movingSeconds = filled.last?.t ?? 0
        ride.ascentMeters = climb.up
        ride.descentMeters = climb.down
        ride.maxSpeed = filled.map(\.speed).max() ?? 0
        ride.endedAt = ride.startedAt.addingTimeInterval(ride.movingSeconds)
        ride.trackData = Blob.encode(filled)
        return ride
    }

    /// The same file read as a plannable route: thinned to the waypoints the
    /// router actually needs rather than every logged fix.
    func makeWaypoints(max count: Int = 12) -> [Coord] {
        let coords = points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        return Geo.sample(coords, count: Swift.min(count, coords.count)).map { Coord($0) }
    }
}
