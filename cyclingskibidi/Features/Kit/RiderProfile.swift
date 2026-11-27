//
//  RiderProfile.swift
//  cyclingskibidi
//
//  What the rider likes, how they're riding today, how fit they are, and what Kit
//  has learned. One small JSON value in AppStorage (spec section 2).
//

import Foundation

/// "What I like". Persona tags match the overlay's `persona`; categories match places.json.
nonisolated enum Interest: String, Codable, CaseIterable, Sendable {
    case nature, food, architecture, heritage, wildlife, art, cafes

    var label: String {
        switch self {
        case .nature: "Nature & photos"
        case .food: "Food"
        case .architecture: "Architecture"
        case .heritage: "Heritage"
        case .wildlife: "Wildlife & birds"
        case .art: "Art & murals"
        case .cafes: "Cafés"
        }
    }

    var symbol: String {
        switch self {
        case .nature: "camera"
        case .food: "fork.knife"
        case .architecture: "building.2"
        case .heritage: "building.columns"
        case .wildlife: "bird"
        case .art: "photo.artframe"
        case .cafes: "cup.and.saucer"
        }
    }

    var personaTags: Set<String> {
        switch self {
        case .nature, .food, .architecture, .heritage, .wildlife: [rawValue]
        case .art, .cafes: []
        }
    }

    var categories: Set<String> {
        switch self {
        case .nature: ["park", "nationalPark", "beach", "reservoir", "waterway", "bridge", "viewpoint"]
        case .food: ["hawker"]
        case .architecture: []   // hand-curated in the overlay only
        case .heritage: ["heritage", "museum", "worship"]
        case .wildlife: ["nationalPark", "zoo", "aquarium"]
        case .art: ["artwork"]
        case .cafes: ["cafe"]
        }
    }
}

/// "How I'm riding today": shapes the route itself.
nonisolated enum RideContext: String, Codable, CaseIterable, Sendable {
    case kids, visiting, quiet

    var label: String {
        switch self {
        case .kids: "With kids"
        case .visiting: "Visiting Singapore"
        case .quiet: "Keep it quiet"
        }
    }

    var symbol: String {
        switch self {
        case .kids: "figure.2.and.child.holdinghands"
        case .visiting: "mappin.and.ellipse"
        case .quiet: "moon"
        }
    }
}

nonisolated enum RiderLevel: String, Codable, CaseIterable, Sendable {
    case beginner, regular, strong

    var label: String { rawValue.capitalized }

    /// The line under the level picker (Figma v3 · 01).
    var detail: String {
        let km = switch self {
        case .beginner: "5–7"
        case .regular: "10–15"
        case .strong: "15–20"
        }
        return "\(label): a rest stop every \(km) km. After 5 rides I'll tune this from your real pace."
    }
}

extension RiderLevel {
    /// Pace from the last five real rides, both arrays newest first. A ride
    /// with no distance or no moving time is a paused/failed recording: skip
    /// it rather than let it skew the mean or divide by zero.
    nonisolated static func estimated(distances: [Double], movingSeconds: [Double]) -> RiderLevel? {
        let usable = zip(distances, movingSeconds).filter { distance, seconds in
            distance > 0 && seconds > 0
        }
        guard usable.count >= 5 else { return nil }
        let recent = usable.prefix(5)
        let d = recent.reduce(0) { $0 + $1.0 / 1000 } / 5                  // km per ride
        let v = recent.reduce(0) { $0 + ($1.0 / 1000) / ($1.1 / 3600) } / 5 // km/h per ride
        // ponytail: 30 km / 22 km/h for strong and 12 km / 15 km/h for beginner
        // are calibration constants for casual city rides, not a fitness model;
        // swap them if the estimate ever feels wrong for a real rider.
        if d >= 30 || v >= 22 { return .strong }
        if d < 12 && v < 15 { return .beginner }
        return .regular
    }

    /// The level Kit plans with: the rider's own pace once five finished rides
    /// exist, otherwise the level they picked in the profile.
    static func effective(profile: RiderProfile, rides: [Ride]) -> RiderLevel {
        let newestFirst = rides.sorted { $0.startedAt > $1.startedAt }
        return estimated(distances: newestFirst.map(\.distanceMeters),
                         movingSeconds: newestFirst.map(\.movingSeconds)) ?? profile.level
    }
}

nonisolated struct RiderProfile: Codable, Equatable, Sendable {
    var likes: Set<Interest> = []
    var today: Set<RideContext> = []
    var level: RiderLevel = .regular
    var weights: [String: Double] = [:]   // learned, per category (Kit learning)
    var fallSensitivity: FallSensitivity = .normal

    static let storageKey = "riderProfile"

    static func decode(_ raw: String) -> RiderProfile? {
        try? JSONDecoder().decode(RiderProfile.self, from: Data(raw.utf8))
    }

    var encoded: String {
        String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self)
    }
}

extension RiderProfile {
    /// Old profiles have no fall sensitivity: decode it with a default rather
    /// than failing the whole profile.
    enum CodingKeys: String, CodingKey {
        case likes, today, level, weights, fallSensitivity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        likes = try c.decodeIfPresent(Set<Interest>.self, forKey: .likes) ?? []
        today = try c.decodeIfPresent(Set<RideContext>.self, forKey: .today) ?? []
        level = try c.decodeIfPresent(RiderLevel.self, forKey: .level) ?? .regular
        weights = try c.decodeIfPresent([String: Double].self, forKey: .weights) ?? [:]
        fallSensitivity = try c.decodeIfPresent(FallSensitivity.self, forKey: .fallSensitivity) ?? .normal
    }

    static func selfCheck() {
        let p = RiderProfile(likes: [.food, .nature], today: [.kids], level: .strong, weights: ["hawker": 0.5])
        assert(decode(p.encoded) == p, "profile round-trips through its JSON")
        assert(decode("") == nil && decode("garbage") == nil, "bad JSON gives nil")
        assert(Interest.food.personaTags == ["food"] && Interest.food.categories == ["hawker"], "food maps to hawker")
        let named = Interest.allCases.reduce(into: Set<String>()) { $0.formUnion($1.categories) }
        assert(named.isSubset(of: Discovery.leisureCategories), "every interest category is a leisure category")
        for tag in ["nature", "food", "architecture", "heritage", "wildlife"] {
            assert(Interest.allCases.filter { $0.personaTags.contains(tag) }.count == 1, "\(tag) maps from one interest")
        }

        // Level from real rides: five usable rides re-estimate the chosen level.
        func sample(_ km: Double, _ kmh: Double, count: Int) -> ([Double], [Double]) {
            let seconds = km * 1000 * 3.6 / kmh
            return (Array(repeating: km * 1000, count: count),
                    Array(repeating: seconds, count: count))
        }
        let four = sample(8, 12, count: 4)
        assert(RiderLevel.estimated(distances: four.0, movingSeconds: four.1) == nil,
               "fewer than five rides keeps the chosen level")
        let beginner = sample(8, 12, count: 5)
        assert(RiderLevel.estimated(distances: beginner.0, movingSeconds: beginner.1) == .beginner,
               "five short, slow rides estimate beginner")
        let strong = sample(35, 18, count: 5)
        assert(RiderLevel.estimated(distances: strong.0, movingSeconds: strong.1) == .strong,
               "five long rides estimate strong even at a moderate speed")
        let regular = sample(15, 18, count: 5)
        assert(RiderLevel.estimated(distances: regular.0, movingSeconds: regular.1) == .regular,
               "five mid-distance, mid-pace rides estimate regular")
        let paused = RiderLevel.estimated(distances: [8_000] + beginner.0,
                                          movingSeconds: [0] + beginner.1)
        assert(paused == .beginner, "a ride with zero moving seconds is skipped, not divided by")
    }
}
