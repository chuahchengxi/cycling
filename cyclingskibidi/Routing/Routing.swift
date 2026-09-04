//
//  Routing.swift
//  cyclingskibidi
//
//  PCN-graph + BRouter routing through the rider's waypoints, with a MapKit
//  walking fallback, plus the elevation profile that feeds the climb figures
//  and the graph on the route sheet.
//

import Foundation
import MapKit

struct RoutePlan: Sendable {
    var polyline: [Coord] = []
    var steps: [StoredStep] = []
    var distance: Double = 0
    var expected: Double = 0
    var elevations: [Double] = []
    /// Sub-polylines that leave the PCN onto roads/paths (build-time only, not
    /// persisted). Drawn distinctly so the rider can reject or redirect them.
    var offConnectorSegments: [[Coord]] = []
    /// Total off-connector distance, for the "1.2 km off-connector" summary.
    var offConnectorMeters: Double = 0

    var ascent: Double { Geo.climb(elevations).up }
    var descent: Double { Geo.climb(elevations).down }
}

enum Routing {

    /// Metres per second, ~18 km/h: an unhurried urban ride once lights and
    /// junctions are averaged in. The walking engine's own expectedTravelTime is
    /// a walking time and would triple every estimate.
    /// ponytail: one number for every rider. Learn it per rider from their own
    /// finished rides once there are enough of them.
    static let cruisingSpeed: Double = 5.0

    /// Assemble a ride through the rider's waypoints.
    ///
    /// Fast mode is one BRouter call over the whole line, roads allowed.
    /// Moderate/leisure stitch the on-PCN A* stretches with BRouter-routed
    /// gaps at the start/end/holes — see `PCNRouting.stitched`.
    static func plan(through waypoints: [Coord],
                     mode: RideMode = .moderate,
                     fetchElevation: Bool = true) async throws -> RoutePlan {
        guard waypoints.count >= 2 else { return RoutePlan() }

        var plan = RoutePlan()
        var poly: [Coord]

        switch mode {
        case .fast:
            // Quickest cycling route, roads allowed — one BRouter call, no PCN.
            poly = await BRouter.route(waypoints, profile: BRouterConfig.fastProfile)
        case .moderate, .leisure:
            let graph = PCNDataset.graph()
            let result = await PCNRouting.stitched(
                waypoints: waypoints, graph: graph,
                gap: { await BRouter.route([$0, $1], profile: BRouterConfig.gapProfile) })
            poly = result.poly
            plan.offConnectorSegments = result.offSegments
            plan.offConnectorMeters = result.offMeters
        }

        // Nothing came back (offline, empty graph): last-resort MapKit walking so a
        // route still appears.
        if poly.count < 2 {
            poly = await BRouter.route(waypoints, profile: BRouterConfig.gapProfile)
            plan.offConnectorSegments = poly.isEmpty ? [] : [poly]
            plan.offConnectorMeters = Geo.cumulative(poly.coordinates).last ?? 0
        }
        guard poly.count >= 2 else { return plan }

        let cl = poly.coordinates
        let cum = Geo.cumulative(cl)
        plan.distance = cum.last ?? 0
        plan.steps = PCNRouting.steps(from: poly)

        if fetchElevation {
            plan.elevations = await elevations(along: cl)
        }
        plan.expected = (plan.distance + plan.ascent * 10) / cruisingSpeed
        plan.polyline = zip(cl, plan.elevations.isEmpty ? [] : resample(plan.elevations, to: cl.count))
            .map { Coord($0.0, alt: $0.1) }
        if plan.polyline.isEmpty { plan.polyline = poly }
        return plan
    }

    // MARK: - Elevation

    /// Open-Meteo's elevation endpoint: no key, no billing, 100 points a call.
    /// Returns [] on any failure — a missing profile flattens the graph, it does
    /// not break the ride.
    static func elevations(along poly: [CLLocationCoordinate2D], samples: Int = 300) async -> [Double] {
        let points = Geo.sample(poly, count: min(samples, max(poly.count, 2)))
        guard points.count >= 2 else { return [] }

        var out: [Double] = []
        for chunk in points.chunked(into: 100) {
            let lats = chunk.map { String(format: "%.5f", $0.latitude) }.joined(separator: ",")
            let lons = chunk.map { String(format: "%.5f", $0.longitude) }.joined(separator: ",")
            guard let url = URL(string: "https://api.open-meteo.com/v1/elevation?latitude=\(lats)&longitude=\(lons)") else { return [] }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let decoded = try JSONDecoder().decode(ElevationResponse.self, from: data)
                out.append(contentsOf: decoded.elevation)
            } catch {
                return []
            }
        }
        return out
    }

    private struct ElevationResponse: Decodable { let elevation: [Double] }

    /// Stretch a short profile back over every vertex, linearly.
    static func resample(_ values: [Double], to count: Int) -> [Double] {
        guard values.count > 1, count > 1 else { return Array(repeating: values.first ?? 0, count: count) }
        return (0..<count).map { i in
            let x = Double(i) * Double(values.count - 1) / Double(count - 1)
            let lo = Int(x.rounded(.down)), hi = min(lo + 1, values.count - 1)
            return values[lo] + (values[hi] - values[lo]) * (x - Double(lo))
        }
    }
}

// MARK: - Small helpers

extension CLLocationCoordinate2D {
    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
}

extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var out = [CLLocationCoordinate2D](repeating: .init(), count: pointCount)
        getCoordinates(&out, range: NSRange(location: 0, length: pointCount))
        return out
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }

    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

extension Route {
    /// Build a saved-ready Route from a plan. Shared by the map builder and the
    /// import paths so the two never drift on which fields get written.
    static func make(name: String, mode: RideMode, waypoints: [Coord], plan: RoutePlan) -> Route {
        let route = Route(name: name)
        route.mode = mode
        route.waypointData = Blob.encode(waypoints)
        route.polylineData = Blob.encode(plan.polyline)
        route.stepData = Blob.encode(plan.steps)
        route.elevationData = Blob.encode(plan.elevations)
        route.distanceMeters = plan.distance
        route.expectedSeconds = plan.expected
        route.ascentMeters = plan.ascent
        route.descentMeters = plan.descent
        route.difficulty = .rated(distanceMeters: plan.distance, ascentMeters: plan.ascent)
        return route
    }
}
