//
//  KitLearning.swift
//  cyclingskibidi
//
//  Kit learns from what the rider does: "Stop here" / "Skip" on a pick, and real
//  stops found in the track at the end of a ride. Each nudges that category's
//  weight by a small step, clamped so nothing is ever hidden for good.
//

import Foundation
import CoreLocation

enum KitLearning {
    static let step = 0.25
    static let limit = 2.0

    static func record(_ category: String, stopped: Bool, in profile: inout RiderProfile) {
        let now = Kit.weight(category, profile) + (stopped ? step : -step)
        profile.weights[category] = min(limit, max(-limit, now))
    }

    /// Picks the rider stood beside: a run of fixes all within `radius` of the pick
    /// spanning at least `minSeconds`. Only picks count, so a stop elsewhere teaches nothing.
    static func detectedStops(track: [TrackPoint], picks: [Sight], minSeconds: Double = 180, radius: Double = 50) -> [Sight] {
        picks.filter { pick in
            var runStart: Double?
            for p in track {
                guard Geo.distance(p.cl, pick.coordinate) <= radius else { runStart = nil; continue }
                if let start = runStart { if p.t - start >= minSeconds { return true } } else { runStart = p.t }
            }
            return false
        }
    }

    /// "More bridges and hawker centres, fewer cafés next time", or nil when nothing moved.
    static func summary(before: RiderProfile, after: RiderProfile) -> String? {
        let categories = Set(before.weights.keys).union(after.weights.keys)
        func change(_ c: String) -> Double { Kit.weight(c, after) - Kit.weight(c, before) }
        func names(_ cs: [String]) -> String {
            let words = cs.map(plural).sorted()
            return words.count == 1 ? words[0] : words.dropLast().joined(separator: ", ") + " and " + words.last!
        }
        let up = categories.filter { change($0) > 0 }, down = categories.filter { change($0) < 0 }
        var parts: [String] = []
        if !up.isEmpty { parts.append("more " + names(Array(up))) }
        if !down.isEmpty { parts.append("fewer " + names(Array(down))) }
        guard !parts.isEmpty else { return nil }
        let text = parts.joined(separator: ", ") + " next time"
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private static func plural(_ category: String) -> String {
        let label = Discovery.icon(for: category).label.lowercased()
        switch label {
        case "place of worship": return "places of worship"
        case "river or canal": return "rivers and canals"
        case "public art", "heritage": return label
        default: return label + "s"
        }
    }
}

extension KitLearning {
    static func selfCheck() {
        var p = RiderProfile()
        record("hawker", stopped: true, in: &p)
        assert(p.weights["hawker"] == 0.25, "Stop adds a step")
        record("cafe", stopped: false, in: &p)
        assert(p.weights["cafe"] == -0.25, "Skip takes a step")
        for _ in 0..<20 { record("cafe", stopped: false, in: &p) }
        assert(p.weights["cafe"] == -2.0, "clamped at -2: \(p.weights["cafe"] ?? 0)")

        // Real stops: still for a while beside a pick.
        var pick = Sight(name: "Bridge", category: "bridge", lat: 1.30, lon: 103.80)
        pick.osmID = "b"
        func still(_ lat: Double, _ lon: Double, seconds: Double) -> [TrackPoint] {
            stride(from: 0.0, through: seconds, by: 10).map { TrackPoint(lat: lat, lon: lon, alt: 0, t: 100 + $0, speed: 0) }
        }
        let thirty = 30.0 / 111_000   // degrees of latitude for ~30 m
        assert(detectedStops(track: still(1.30 + thirty, 103.80, seconds: 200), picks: [pick]).map(\.name) == ["Bridge"], "200 s within 30 m is a stop")
        assert(detectedStops(track: still(1.30 + thirty, 103.80, seconds: 120), picks: [pick]).isEmpty, "120 s is not")
        assert(detectedStops(track: still(1.30 + 80 / 111_000, 103.80, seconds: 200), picks: [pick]).isEmpty, "80 m away is not")
        assert(detectedStops(track: still(1.31, 103.81, seconds: 200), picks: [pick]).isEmpty, "beside a non-pick: nothing")
        // A gap in fixes while standing still still counts: arrive at t=0, next fix at t=200.
        let gap = [TrackPoint(lat: 1.30, lon: 103.80, alt: 0, t: 0, speed: 0), TrackPoint(lat: 1.30, lon: 103.80, alt: 0, t: 200, speed: 0)]
        assert(detectedStops(track: gap, picks: [pick]).count == 1, "sparse fixes while still")

        // What Kit learned, in words.
        let before = RiderProfile(weights: ["cafe": 0.5])
        let after = RiderProfile(weights: ["cafe": 0.25, "hawker": 0.25, "bridge": 0.5])
        assert(summary(before: before, after: after) == "More bridges and hawker centres, fewer cafés next time", "\(summary(before: before, after: after) ?? "nil")")
        assert(summary(before: before, after: RiderProfile(weights: ["cafe": 0.75])) == "More cafés next time", "only up")
        assert(summary(before: before, after: RiderProfile(weights: ["cafe": 0])) == "Fewer cafés next time", "only down")
        assert(summary(before: before, after: before) == nil, "no change, no line")
    }
}
