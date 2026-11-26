//
//  RestStops.swift
//  cyclingskibidi
//
//  Where to rest on a long ride: water, toilets and shade clustered into one
//  stop per spot, then one stop per spacing window for the rider's level.
//

import Foundation
import CoreLocation

/// One place to rest on a route: a cluster of amenities at the same spot.
/// `amenities` are places.json categories, best first (see `RestStops.rank`).
nonisolated struct RestStop: Codable, Identifiable, Sendable, Equatable {
    var id = UUID()
    var name: String
    var lat: Double
    var lon: Double
    var offsetAlong: Double
    var amenities: [String]
    var warning: String? = nil

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

nonisolated enum RestStops {
    /// The places.json categories that make a rest stop.
    static let amenityCategories: Set<String> = [
        "drinkingWater", "toilets", "shelter", "hawker", "cafe", "bikeParking", "repair",
    ]

    /// How far apart rest stops should be for this rider, in metres.
    static func spacing(_ level: RiderLevel) -> ClosedRange<Double> {
        switch level {
        case .beginner: return 5000...7000
        case .regular:  return 10_000...15_000
        case .strong:   return 15_000...20_000
        }
    }

    /// How much a single amenity is worth at a stop. Water is the scarce one in
    /// Singapore; food counts once whether it is a hawker centre or a café.
    static func rank(_ category: String) -> Double {
        switch category {
        case "drinkingWater":       return 16
        case "toilets":             return 8
        case "shelter":             return 4
        case "hawker", "cafe":      return 2
        case "bikeParking":         return 1
        case "repair":              return 0.5
        default:                    return 0
        }
    }

    /// Amenities in route order; one joins the current stop when within `radius`
    /// of its first member, so a hawker centre's taps, toilets and parking are
    /// one place to rest rather than four.
    // ponytail: anchors on the group's first member in route order, so two amenities at one spot with interleaved offsets can split into two stops.
    static func cluster(_ amenities: [Sight], radius: Double = 60) -> [RestStop] {
        var groups: [[Sight]] = []
        for a in amenities.sorted(by: { $0.offsetAlong < $1.offsetAlong }) {
            if let i = groups.indices.last,
               Geo.distance(groups[i][0].coordinate, a.coordinate) <= radius {
                groups[i].append(a)
            } else {
                groups.append([a])
            }
        }
        return groups.map { group in
            let first = group[0]
            let categories = Set(group.map(\.category)).sorted {
                rank($0) == rank($1) ? $0 < $1 : rank($0) > rank($1)
            }
            let named = group.first {
                ["hawker", "cafe", "shelter"].contains($0.category) && realName($0)
            }
            let top = categories.first ?? first.category
            let name = named?.name
                ?? "\(Discovery.icon(for: top).label) · km \(String(format: "%.1f", first.offsetAlong / 1000))"
            return RestStop(name: name, lat: first.lat, lon: first.lon,
                            offsetAlong: first.offsetAlong, amenities: categories)
        }
    }

    /// A stop's worth: the sum of its amenities, with food counted once.
    static func quality(_ s: RestStop) -> Double {
        var q = 0.0, food = false
        for a in Set(s.amenities) {
            if a == "hawker" || a == "cafe" {
                if !food { q += 2; food = true }
            } else {
                q += rank(a)
            }
        }
        return q
    }

    /// One stop per spacing window, the best in each; a window with nothing in it
    /// falls through to the first stop after it. Short rides just show the water
    /// and toilets on the way.
    static func choose(_ stops: [RestStop], length: Double, level: RiderLevel) -> [RestStop] {
        let sorted = stops.sorted { $0.offsetAlong < $1.offsetAlong }
        if length < 20_000 {
            return sorted.filter {
                $0.amenities.contains("drinkingWater") || $0.amenities.contains("toilets")
            }
        }
        let w = spacing(level)
        let end = length - w.lowerBound / 2   // the finish is the last rest
        var chosen: [RestStop] = []
        var last = 0.0
        while length - last > w.upperBound {
            let window = sorted.filter {
                $0.offsetAlong >= last + w.lowerBound && $0.offsetAlong <= last + w.upperBound
                    && $0.offsetAlong <= end
            }
            let best = window.max { a, b in
                (quality(a), -a.offsetAlong) < (quality(b), -b.offsetAlong)   // ties go earlier
            }
            let pick = best ?? sorted.first {
                $0.offsetAlong > last + w.upperBound && $0.offsetAlong <= end
            }
            guard let p = pick else { break }
            chosen.append(p)
            last = p.offsetAlong
        }
        // Warn only when the stop after this one is dry: a water-to-water gap is
        // already covered by the next stop, and the last chosen stop never warns.
        for i in chosen.indices where chosen[i].amenities.contains("drinkingWater") {
            guard i + 1 < chosen.count, !chosen[i + 1].amenities.contains("drinkingWater") else { continue }
            let nextWater = chosen[(i + 1)...].first { $0.amenities.contains("drinkingWater") }
            let gap = (nextWater?.offsetAlong ?? length) - chosen[i].offsetAlong
            if gap >= 5000 {
                chosen[i].warning = "No water for \(Int((gap / 1000).rounded())) km — fill up here"
            }
        }
        return chosen
    }

    /// Rest stops along a line: the amenities Discovery keeps (open, not closed,
    /// not no-cycling), clustered, then spaced for the rider. Fast rides stop for
    /// nothing.
    static func along(_ polyline: [Coord], mode: RideMode, level: RiderLevel, start: Date = .now,
                      places: [Sight] = Discovery.places, facts: [String: PlaceFacts] = Discovery.facts,
                      closed: [NoGoCircle]? = nil, walk: [NoGoCircle]? = nil) -> [RestStop] {
        guard mode != .fast else { return [] }
        let amenities = Discovery.sights(along: polyline, mode: mode, start: start, in: places, facts: facts,
                                         closed: closed, walk: walk, limit: nil,
                                         categories: amenityCategories, mergeByName: false)
        guard let length = Geo.cumulative(polyline.map(\.cl)).last else { return [] }
        return choose(cluster(amenities), length: length, level: level)
    }

    /// True when a place has a name of its own, not the generic label the build
    /// gives nameless amenities ("Toilets", "Shelter"…).
    private static func realName(_ s: Sight) -> Bool {
        !s.name.isEmpty && s.name != Discovery.icon(for: s.category).label
    }
}

extension RestStops {
    static func selfCheck() {
        // Spacing by level, in metres.
        assert(spacing(.beginner) == 5000...7000, "beginner spacing")
        assert(spacing(.regular) == 10_000...15_000, "regular spacing")
        assert(spacing(.strong) == 15_000...20_000, "strong spacing")

        // Clustering: amenities 20 m apart are one stop; a tap 500 m on is another.
        func sight(_ category: String, _ metres: Double) -> Sight {
            var s = Sight(name: Discovery.icon(for: category).label, category: category,
                          lat: 1.30 + metres / 111_195, lon: 103.80)
            s.offsetAlong = metres
            return s
        }
        let clustered = cluster([sight("toilets", 1000), sight("drinkingWater", 1020),
                                 sight("bikeParking", 1040), sight("drinkingWater", 1500)])
        assert(clustered.count == 2, "cluster count: \(clustered.count)")
        assert(clustered[0].amenities == ["drinkingWater", "toilets", "bikeParking"],
               "cluster order: \(clustered[0].amenities)")
        assert(clustered[0].name == "Drinking water · km 1.0", "fallback name: \(clustered[0].name)")

        // Quality.
        func stop(_ km: Double, _ amenities: [String]) -> RestStop {
            RestStop(name: "Stop", lat: 1.30, lon: 103.80, offsetAlong: km * 1000, amenities: amenities)
        }
        assert(quality(stop(0, ["drinkingWater", "toilets"])) == 24, "water+toilet quality")
        assert(quality(stop(0, ["hawker", "shelter", "bikeParking"])) == 7, "food+shade+parking quality")
        assert(quality(stop(0, ["hawker", "cafe"])) == 2, "food counts once")

        // Under 20 km: water and toilets, no spacing.
        let short = choose([stop(3, ["shelter"]), stop(5, ["toilets"]), stop(8, ["drinkingWater"])],
                           length: 12_000, level: .beginner)
        assert(short.map(\.offsetAlong) == [5_000, 8_000], "short route: \(short.map(\.offsetAlong))")

        // Regular 40 km: best in 10-15, then 23-28; the finish is close enough.
        let forty = [stop(4, []), stop(11, ["toilets"]), stop(13, ["drinkingWater", "toilets"]),
                     stop(18, []), stop(26, ["drinkingWater"]), stop(33, ["shelter"]), stop(38, [])]
        let regular = choose(forty, length: 40_000, level: .regular)
        assert(regular.map(\.offsetAlong) == [13_000, 26_000], "regular 40 km: \(regular.map(\.offsetAlong))")
        assert(regular.allSatisfy { $0.warning == nil },
               "water-to-water gap must not warn: \(regular.map { $0.warning ?? "nil" })")
        // The last spacing.lowerBound / 2 of the ride is never a stop.
        let sixty = forty + [stop(57, ["drinkingWater"])]
        let longer = choose(sixty, length: 60_000, level: .regular)
        assert(longer.map(\.offsetAlong) == [13_000, 26_000, 38_000],
               "the last 5 km is never a stop: \(longer.map(\.offsetAlong))")

        // An empty window falls through to the first stop after it.
        let empty = choose([stop(12, ["toilets"]), stop(30, ["drinkingWater"])],
                           length: 40_000, level: .regular)
        assert(empty.map(\.offsetAlong) == [12_000, 30_000], "empty window: \(empty.map(\.offsetAlong))")

        // Warning before a water gap.
        let warned = choose([stop(16, ["drinkingWater"]), stop(33, ["shelter"])],
                            length: 45_000, level: .strong)
        assert(warned.map(\.offsetAlong) == [16_000, 33_000], "strong 45 km: \(warned.map(\.offsetAlong))")
        assert(warned[0].warning == "No water for 29 km — fill up here", "warning: \(warned[0].warning ?? "nil")")
        assert(warned[1].warning == nil, "no water, no warning")

        // The last chosen stop never warns, even if the finish is a dry 14 km away.
        let dryFinish = choose([stop(13, ["toilets"]), stop(26, ["drinkingWater"])],
                               length: 40_000, level: .regular)
        assert(dryFinish.map(\.offsetAlong) == [13_000, 26_000]
               && dryFinish.allSatisfy { $0.warning == nil },
               "last chosen stop warned: \(dryFinish.map { $0.warning ?? "nil" })")

        // Fast gets nothing.
        let line = [Coord(lat: 1.30, lon: 103.80), Coord(lat: 1.30, lon: 103.90)]
        assert(along(line, mode: .fast, level: .regular, places: [], facts: [:], closed: [], walk: []).isEmpty,
               "fast: no stops")

        // A toilet inside a closure is never a stop. The empty 10–15 km window
        // falls through to the open toilet at ~16.7 km, so it is the one expected.
        let inside = Sight(name: "Shut toilet", category: "toilets", lat: 1.30, lon: 103.80)
        let open = Sight(name: "Open toilet", category: "toilets", lat: 1.30, lon: 103.85)
        let route = [Coord(lat: 1.30, lon: 103.70), Coord(lat: 1.30, lon: 103.9246)]
        let circle = [NoGoCircle(coord: Coord(lat: 1.30, lon: 103.80), radiusMeters: 100)]
        let closedStops = along(route, mode: .leisure, level: .regular,
                                places: [inside, open], facts: [:], closed: circle, walk: [])
        assert(!closedStops.contains { Geo.distance($0.coordinate, inside.coordinate) < 100 },
               "closed toilet chosen: \(closedStops.map(\.name))")
        assert(closedStops.contains { Geo.distance($0.coordinate, open.coordinate) < 100 },
               "open toilet missing: \(closedStops.map(\.name))")
    }
}

extension RestStops {
    /// Real data: a ~30 km Leisure ride along the east coast gets spaced stops with facilities.
    static func selfCheckReal() async {
        guard let plan = try? await Routing.plan(through: [Coord(lat: 1.2806, lon: 103.8711), Coord(lat: 1.3907, lon: 103.9915)], mode: .leisure),
              plan.distance > 20_000 else { return assertionFailure("the east-coast test ride didn't plan") }
        let stops = await Task.detached { along(plan.polyline, mode: .leisure, level: .regular) }.value
        let gaps = zip([0] + stops.map(\.offsetAlong), stops.map(\.offsetAlong)).map { $1 - $0 }
        let beginner = await Task.detached { along(plan.polyline, mode: .leisure, level: .beginner) }.value
        assert(beginner.count >= 3, "a beginner on 22 km needs a stop every 5–7 km: \(beginner.map(\.offsetAlong))")
        assert(stops.contains { $0.amenities.contains("drinkingWater") } && gaps.allSatisfy { $0 <= 25_000 } && stops.allSatisfy { !$0.amenities.isEmpty },
               "east coast rest stops: \(stops.map { "\(Int($0.offsetAlong)) \($0.amenities)" }) over \(Int(plan.distance)) m")
        print("RestStops real:", Int(plan.distance), stops.map { "\(Int($0.offsetAlong / 100) / 10)km \($0.name) \($0.amenities) \($0.warning ?? "")" })
    }
}
