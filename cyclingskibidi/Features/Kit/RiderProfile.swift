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

nonisolated struct RiderProfile: Codable, Equatable, Sendable {
    var likes: Set<Interest> = []
    var today: Set<RideContext> = []
    var level: RiderLevel = .regular
    var weights: [String: Double] = [:]   // learned, per category (Kit learning)

    static let storageKey = "riderProfile"

    static func decode(_ raw: String) -> RiderProfile? {
        try? JSONDecoder().decode(RiderProfile.self, from: Data(raw.utf8))
    }

    var encoded: String {
        String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self)
    }
}

extension RiderProfile {
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
    }
}
