//
//  PresetLoops.swift
//  cyclingskibidi
//
//  Ready-made park connector circuits for the route builder: hand-picked pins
//  on the bundled PCN graph, so a rider can start a leisure loop with one tap.
//

import Foundation
import CoreLocation

/// A ready-made circuit. `waypoints` starts and ends at the same connector
/// node; `blurb` is the rider-facing reason to ride it.
nonisolated struct PresetLoop: Identifiable, Sendable {
    let id: String
    let name: String
    let blurb: String
    let waypoints: [Coord]
}

nonisolated enum PresetLoops {
    /// Pins are real PCN vertices (within 30 m of a graph node, asserted in
    /// `selfCheck`) in one connected component, so the whole circuit is rideable.
    static let all: [PresetLoop] = [
        PresetLoop(
            id: "ecp-gbte", name: "East Coast Park ↔ Gardens by the Bay East",
            blurb: "Ride the park connector from Gardens by the Bay East along Tanjong Rhu to East Coast Park and back; Marine Parade hawker centre is a short walk inland.",
            waypoints: [
                Coord(lat: 1.283557, lon: 103.872392),
                Coord(lat: 1.294083, lon: 103.866502),
                Coord(lat: 1.298618, lon: 103.908390),
                Coord(lat: 1.294083, lon: 103.866502),
                Coord(lat: 1.283557, lon: 103.872392),
            ]),
        PresetLoop(
            id: "marina-bay", name: "Marina Bay loop",
            blurb: "Circle Marina Bay on the park connector from Esplanade past The Float and Marina Bay Sands, round Gardens by the Bay and the Marina Barrage out to Bay East, then back the same way; Makansutra Gluttons Bay hawker centre is a short walk from The Float.",
            waypoints: [
                Coord(lat: 1.288967, lon: 103.854085),
                Coord(lat: 1.288820, lon: 103.857679),
                Coord(lat: 1.284151, lon: 103.866662),
                Coord(lat: 1.281507, lon: 103.870710),
                Coord(lat: 1.294083, lon: 103.866502),
                Coord(lat: 1.288967, lon: 103.854085),
            ]),
        PresetLoop(
            id: "punggol-coney", name: "Punggol Waterway and Promenade",
            blurb: "Follow the park connector along Punggol Waterway and the Promenade, with One Punggol hawker centre just off the line.",
            waypoints: [
                Coord(lat: 1.390461, lon: 103.915675),
                Coord(lat: 1.404576, lon: 103.921352),
                Coord(lat: 1.408018, lon: 103.908106),
                Coord(lat: 1.411318, lon: 103.902100),
                Coord(lat: 1.390461, lon: 103.915675),
            ]),
    ]

    /// How close the last pin must be to count as "return the bike here".
    static let returnRadius: Double = 30

    /// Categories that mean "leaving from / coming back to a bike".
    static func isBikePlace(_ sight: Sight) -> Bool {
        sight.category == "bikeRental" || sight.category == "bikeParking"
    }

    /// The bike parking or rental place within 30 m of the route's last pin,
    /// nearest first when several racks share the spot.
    static func returnPoint(for last: Coord, in places: [Sight]) -> Sight? {
        var best: Sight?
        var bestDistance = Double.infinity
        for place in places where isBikePlace(place) {
            let d = Geo.distance(last.cl, place.coordinate)
            guard d <= returnRadius, d < bestDistance else { continue }
            best = place
            bestDistance = d
        }
        return best
    }

    /// The sheet's end-of-ride line, or nil when the route doesn't end at a bike place.
    static func returnLine(for last: Coord, in places: [Sight]) -> String? {
        guard let point = returnPoint(for: last, in: places) else { return nil }
        return "Return the bike here: \(point.name)"
    }
}

// MARK: - Self check

extension PresetLoops {
    static func selfCheck() async {
        let graph = await PCNDataset.graph()
        assert(all.count == 3, "three preset loops expected, got \(all.count)")
        for loop in all {
            assert((3...6).contains(loop.waypoints.count), "\(loop.name): 3–6 pins, got \(loop.waypoints.count)")
            assert(loop.waypoints.first == loop.waypoints.last, "\(loop.name): first pin must equal the last")
            for pin in loop.waypoints {
                guard let node = graph.nearest(to: pin).flatMap({ graph.coord(of: $0) }) else {
                    assertionFailure("\(loop.name): no PCN node for \(pin)"); continue
                }
                assert(Geo.distance(pin.cl, node.cl) <= 30,
                       "\(loop.name): pin \(pin) is \(Int(Geo.distance(pin.cl, node.cl))) m from the PCN")
            }
            guard let plan = try? await Routing.plan(through: loop.waypoints, mode: .leisure) else {
                assertionFailure("\(loop.name): leisure plan failed"); continue
            }
            assert(plan.distance >= 8000 && plan.distance <= 30_000,
                   "\(loop.name): planned \(Int(plan.distance)) m, expected 8–30 km")
            print("Preset loop \(loop.name): \(Int(plan.distance)) m, \(loop.waypoints.count) pins")
        }

        // A toy active closure on the marina circuit's line must be ridden round.
        guard let marina = all.first(where: { $0.id == "marina-bay" }),
              marina.waypoints.count >= 3,
              let open = try? await Routing.plan(through: marina.waypoints, mode: .leisure) else {
            assertionFailure("marina loop or its plan missing"); return
        }
        let line = open.polyline.coordinates, cum = Geo.cumulative(line)
        let junction = marina.waypoints[1]
        let i0 = line.indices.min { Geo.distance(line[$0], junction.cl) < Geo.distance(line[$1], junction.cl) } ?? 0
        let centres = stride(from: cum[i0] + 1200, through: cum[i0] + 2000, by: 200)
            .compactMap { Geo.point(at: $0, on: line, cumulative: cum) }
        assert(centres.count == 5, "toy closure needs five circles, got \(centres.count)")
        let toy = Closure(id: "preset-loop-toy", name: "Toy closure",
                          circles: centres.map { Closure.Circle(lat: $0.latitude, lon: $0.longitude,
                                                                radiusM: 120, coordSource: "test") },
                          starts: nil, validUntil: nil, note: "self-check", sourceUrl: "", kind: .closure)
        assert(Closures.hits(open.polyline, in: [toy], on: .now).active.count == 1,
               "the toy closure must sit on the open line")
        let detour = try? await Routing.plan(through: marina.waypoints, mode: .leisure, closures: toy.noGoCircles)
        assert(detour.map { Closures.hits($0.polyline, in: [toy], on: .now).active.isEmpty } == true,
               "the reroute still rides the toy closure")

        // Sheet line: only a bike place at the last pin earns the return line.
        let rack = Sight(name: "Bike parking", category: "bikeParking", lat: 1.30, lon: 103.80)
        let last = Coord(lat: rack.lat, lon: rack.lon)
        assert(returnPoint(for: last, in: [rack])?.name == "Bike parking", "parking place not found")
        assert(returnLine(for: last, in: [rack]) == "Return the bike here: Bike parking", "sheet line wrong")
        let away = Sight(name: "Far rack", category: "bikeParking", lat: rack.lat + 0.001, lon: rack.lon)
        assert(returnPoint(for: last, in: [away]) == nil, "a place 100 m away must not count")
        let rental = Sight(name: "Bike rental", category: "bikeRental", lat: rack.lat, lon: rack.lon)
        let stall = Sight(name: "Stall", category: "hawker", lat: rack.lat, lon: rack.lon)
        assert(returnPoint(for: last, in: [stall]) == nil, "only bike places count")
        assert(returnLine(for: last, in: [rental]) == "Return the bike here: Bike rental", "rental place not found")
        assert(all.allSatisfy { $0.blurb.contains("park connector") }, "rider copy must spell out park connector")
        assert(all.allSatisfy { $0.blurb.contains("hawker centre") }, "rider copy must spell out hawker centre")
    }
}
