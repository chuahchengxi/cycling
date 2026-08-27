//
//  DemoSeed.swift
//  cyclingskibidi
//
//  Debug-only. You cannot ride a bike from behind Xcode, so this seeds a real
//  route and a finished ride and can jump straight to any screen:
//
//      -demo:list | -demo:detail | -demo:navigate | -demo:finished
//
//  Pair it with `xcrun simctl location <udid> start --speed 6 ride.gpx` to feed
//  the navigation engine a moving rider.
//

#if DEBUG
import Foundation
import SwiftData
import CoreLocation

enum Demo {

    static var screen: String? {
        ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix("-demo:") }?
            .replacingOccurrences(of: "-demo:", with: "")
    }

    private static let waypoints = [
        Coord(lat: 1.29926, lon: 103.78776),
        Coord(lat: 1.30180, lon: 103.79180),
        Coord(lat: 1.29760, lon: 103.79420),
        Coord(lat: 1.29380, lon: 103.78620),
    ]

    static func seed(_ context: ModelContext) async -> Route? {
        if let existing = try? context.fetch(FetchDescriptor<Route>()), let first = existing.first {
            return first
        }

        let plan = (try? await Routing.plan(through: waypoints)) ?? straightLine()
        let route = Route(name: "One-North Loop")
        route.waypointData = Blob.encode(waypoints)
        route.polylineData = Blob.encode(plan.polyline)
        route.stepData = Blob.encode(plan.steps)
        route.elevationData = Blob.encode(plan.elevations)
        route.distanceMeters = plan.distance
        route.expectedSeconds = plan.expected
        route.ascentMeters = plan.ascent
        route.descentMeters = plan.descent
        route.difficulty = .rated(distanceMeters: plan.distance, ascentMeters: plan.ascent)
        context.insert(route)
        context.insert(finishedRide(along: plan))
        try? context.save()
        return route
    }

    static func finishedRide(along plan: RoutePlan) -> Ride {
        let ride = Ride(startedAt: .now.addingTimeInterval(-3720), routeName: "One-North Loop")
        var track: [TrackPoint] = []
        var elapsed = 0.0
        let points = Geo.sample(plan.polyline.coordinates, count: 400)
        let elevations = Routing.resample(plan.elevations.isEmpty ? [12, 18, 9, 15] : plan.elevations,
                                          to: max(points.count, 2))
        for (i, c) in points.enumerated() {
            let speed = 6.1 + sin(Double(i) / 9) * 1.6
            if i > 0 { elapsed += Geo.distance(points[i - 1], c) / speed }
            track.append(TrackPoint(lat: c.latitude, lon: c.longitude,
                                    alt: elevations[i], t: elapsed, speed: speed))
        }
        let climb = Geo.climb(track.map(\.alt))
        ride.trackData = Blob.encode(track)
        ride.distanceMeters = plan.distance
        ride.movingSeconds = elapsed
        ride.endedAt = ride.startedAt.addingTimeInterval(elapsed)
        ride.maxSpeed = track.map(\.speed).max() ?? 0
        ride.ascentMeters = climb.up
        ride.descentMeters = climb.down
        return ride
    }

    private static func straightLine() -> RoutePlan {
        var plan = RoutePlan()
        plan.polyline = waypoints
        let coords = waypoints.coordinates
        plan.distance = Geo.cumulative(coords).last ?? 0
        plan.expected = plan.distance / 5.5
        plan.elevations = [14, 22, 11, 17]
        plan.steps = zip(waypoints.indices, Geo.cumulative(coords)).map { i, offset in
            StoredStep(instruction: i == 0 ? "Head north" : i == waypoints.count - 1 ? "Arrive" : "Continue",
                       distance: offset, maneuverOffset: offset,
                       maneuverRaw: (i == 0 ? Maneuver.depart : i == waypoints.count - 1 ? .arrive : .right).rawValue,
                       lat: waypoints[i].lat, lon: waypoints[i].lon)
        }
        return plan
    }
}
#endif
