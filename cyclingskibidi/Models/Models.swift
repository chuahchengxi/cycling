//
//  Models.swift
//  cyclingskibidi
//
//  SwiftData models. Every one of these syncs through CloudKit, so they follow
//  the CloudKit rules: no unique attributes, every stored property has a
//  default, every relationship is optional.
//

import Foundation
import SwiftData
import CoreLocation

// MARK: - Blob value types

/// A single point on a route. Stored inside a blob rather than as its own
/// @Model: a 90 km route is ~5000 points and CloudKit would choke on 5000
/// records per route.
nonisolated struct Coord: Codable, Hashable, Sendable {
    var lat: Double
    var lon: Double
    var alt: Double

    init(lat: Double, lon: Double, alt: Double = 0) {
        self.lat = lat; self.lon = lon; self.alt = alt
    }
    init(_ c: CLLocationCoordinate2D, alt: Double = 0) {
        lat = c.latitude; lon = c.longitude; self.alt = alt
    }
    var cl: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

/// One recorded GPS fix.
struct TrackPoint: Codable, Sendable {
    var lat: Double
    var lon: Double
    var alt: Double
    /// Seconds since the ride started.
    var t: Double
    /// Metres per second.
    var speed: Double

    var cl: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

extension Array where Element == Coord {
    var coordinates: [CLLocationCoordinate2D] { map(\.cl) }
}

/// Codable <-> Data, so blobs are one line at the call site.
enum Blob {
    static func encode<T: Encodable>(_ value: T) -> Data? { try? JSONEncoder().encode(value) }
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Enums

enum Difficulty: String, Codable, CaseIterable, Identifiable, Sendable {
    case easy = "Easy", medium = "Medium", hard = "Hard"
    var id: String { rawValue }

    /// Flat-equivalent effort: 10 m of climbing costs about 1 km of flat road.
    /// ponytail: fixed thresholds, swap for a rider-fitness model if the ratings
    /// ever feel wrong for a real user.
    static func rated(distanceMeters: Double, ascentMeters: Double) -> Difficulty {
        let score = distanceMeters / 1000 + ascentMeters / 10
        if score <= 12 { return .easy }
        if score <= 45 { return .medium }
        return .hard
    }

    var tint: String { self == .easy ? "green" : self == .medium ? "orange" : "red" }
}

enum RideMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case fast = "Fast", moderate = "Moderate", leisure = "Leisure"
    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .fast:     return "Fastest way there — roads allowed, higher risk."
        case .moderate: return "A balance of speed and safety."
        case .leisure:  return "Scenic and relaxed — connectors and sights."
        }
    }
    var symbol: String {
        switch self {
        case .fast:     return "bolt.fill"
        case .moderate: return "bicycle"
        case .leisure:  return "leaf.fill"
        }
    }

    static func selfCheck() {
        // Raw values round-trip (they are persisted in Route.modeRaw).
        for m in RideMode.allCases { assert(RideMode(rawValue: m.rawValue) == m) }
        // Unknown raw value falls back at the call site, never crashes.
        assert(RideMode(rawValue: "Nonsense") == nil)
        assert(RideMode.allCases.count == 3)
    }
}

enum ObstacleKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case pothole = "Pothole"
    case gravel = "Loose gravel"
    case roadworks = "Roadworks"
    case traffic = "Heavy traffic"
    case glass = "Glass / debris"
    case flooding = "Flooding"
    case closed = "Path closed"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .pothole:   return "circle.bottomhalf.filled"
        case .gravel:    return "aqi.medium"
        case .roadworks: return "cone.fill"
        case .traffic:   return "car.fill"
        case .glass:     return "exclamationmark.triangle.fill"
        case .flooding:  return "water.waves"
        case .closed:    return "xmark.octagon.fill"
        }
    }
}

enum RideSource: String, Codable, Sendable {
    case app = "cyclingskibidi"
    case garmin = "Garmin"
    case coros = "COROS"
    case wahoo = "Wahoo"
    case health = "Apple Health"
    case gpx = "GPX file"

    /// HealthKit hands us the writing app's name; map it onto a provider.
    static func from(sourceName: String) -> RideSource {
        let n = sourceName.lowercased()
        if n.contains("garmin") { return .garmin }
        if n.contains("coros")  { return .coros }
        if n.contains("wahoo")  { return .wahoo }
        if n.contains("cycling") { return .app }
        return .health
    }

    var symbol: String {
        switch self {
        case .app:    return "bicycle"
        case .garmin, .coros, .wahoo: return "applewatch.side.right"
        case .health: return "heart.fill"
        case .gpx:    return "doc.text"
        }
    }
}

// MARK: - Models

@Model
final class Route {
    var name: String = "Untitled route"
    var createdAt: Date = Date.now
    var difficultyRaw: String = Difficulty.easy.rawValue
    var modeRaw: String = RideMode.moderate.rawValue
    var distanceMeters: Double = 0
    /// Routing engine's own estimate, in seconds.
    var expectedSeconds: Double = 0
    var ascentMeters: Double = 0
    var descentMeters: Double = 0
    /// The points the rider tapped.
    var waypointData: Data?
    /// The road-snapped line between them.
    var polylineData: Data?
    /// Turn list, as [StoredStep].
    var stepData: Data?
    /// Down-sampled elevation profile, as [Double] metres.
    var elevationData: Data?

    init(name: String = "Untitled route") {
        self.name = name
    }

    var difficulty: Difficulty {
        get { Difficulty(rawValue: difficultyRaw) ?? .easy }
        set { difficultyRaw = newValue.rawValue }
    }
    var mode: RideMode {
        get { RideMode(rawValue: modeRaw) ?? .moderate }
        set { modeRaw = newValue.rawValue }
    }
    var waypoints: [Coord] { Blob.decode([Coord].self, waypointData) ?? [] }
    var polyline: [Coord] { Blob.decode([Coord].self, polylineData) ?? [] }
    var steps: [StoredStep] { Blob.decode([StoredStep].self, stepData) ?? [] }
    var elevations: [Double] { Blob.decode([Double].self, elevationData) ?? [] }

    var distanceKM: Double { distanceMeters / 1000 }
}

@Model
final class Obstacle {
    var kindRaw: String = ObstacleKind.pothole.rawValue
    var latitude: Double = 0
    var longitude: Double = 0
    var note: String = ""
    var reportedAt: Date = Date.now
    /// Bumped when another rider confirms it is still there.
    var confirmations: Int = 0

    init(kind: ObstacleKind, at c: CLLocationCoordinate2D, note: String = "") {
        kindRaw = kind.rawValue
        latitude = c.latitude
        longitude = c.longitude
        self.note = note
    }

    var kind: ObstacleKind { ObstacleKind(rawValue: kindRaw) ?? .pothole }
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

@Model
final class Ride {
    var startedAt: Date = Date.now
    var endedAt: Date = Date.now
    var distanceMeters: Double = 0
    /// Excludes time spent stopped at lights.
    var movingSeconds: Double = 0
    var ascentMeters: Double = 0
    var descentMeters: Double = 0
    var maxSpeed: Double = 0
    var sourceRaw: String = RideSource.app.rawValue
    var routeName: String = ""
    /// Set when this ride came from HealthKit / a file, so re-importing is a no-op.
    var externalID: String = ""
    /// [TrackPoint], JSON. SwiftData promotes anything large to a CKAsset.
    var trackData: Data?

    init(startedAt: Date = .now, routeName: String = "", source: RideSource = .app) {
        self.startedAt = startedAt
        self.routeName = routeName
        self.sourceRaw = source.rawValue
    }

    var source: RideSource { RideSource(rawValue: sourceRaw) ?? .app }
    var track: [TrackPoint] { Blob.decode([TrackPoint].self, trackData) ?? [] }
    var distanceKM: Double { distanceMeters / 1000 }
    /// Metres per second.
    var averageSpeed: Double { movingSeconds > 0 ? distanceMeters / movingSeconds : 0 }
}

// MARK: - Formatting

enum Fmt {
    static func km(_ metres: Double) -> String {
        if metres < 1000 { return "\(Int(metres.rounded())) m" }
        // A decimal matters at 3.2 km and is noise at 90 km.
        return metres < 10_000 ? String(format: "%.1f km", metres / 1000)
                               : "\(Int((metres / 1000).rounded())) km"
    }

    /// "1:05 H" for long rides, "15:00" for short ones — matches the board.
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? String(format: "%d:%02d H", h, m) : String(format: "%d:%02d", m, s % 60)
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// m/s -> km/h.
    static func speed(_ mps: Double) -> String { String(format: "%.1f km/h", mps * 3.6) }

    static func eta(_ seconds: Double) -> String {
        Date.now.addingTimeInterval(seconds).formatted(date: .omitted, time: .shortened)
    }
}
