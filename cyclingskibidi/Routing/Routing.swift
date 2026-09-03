//
//  Routing.swift
//  cyclingskibidi
//
//  Road-snapped routing through the rider's waypoints, plus the elevation
//  profile that feeds the climb figures and the graph on the route sheet.
//

import Foundation
import MapKit

struct RoutePlan: Sendable {
    var polyline: [Coord] = []
    var steps: [StoredStep] = []
    var distance: Double = 0
    var expected: Double = 0
    var elevations: [Double] = []

    var ascent: Double { Geo.climb(elevations).up }
    var descent: Double { Geo.climb(elevations).down }
}

enum Routing {

    /// MapKit has no cycling transport type, so routes come back from the
    /// walking engine: it keeps park connectors and shared paths, which a bike
    /// wants and the driving engine throws away.
    /// ponytail: swap in a cycling-aware engine (BRouter, Valhalla, GraphHopper)
    /// if riders start complaining about stairs or pavements.
    static let transport: MKDirectionsTransportType = .walking

    /// Metres per second, ~18 km/h: an unhurried urban ride once lights and
    /// junctions are averaged in. The walking engine's own expectedTravelTime is
    /// a walking time and would triple every estimate.
    /// ponytail: one number for every rider. Learn it per rider from their own
    /// finished rides once there are enough of them.
    static let cruisingSpeed: Double = 5.0

    /// Snap a list of tapped points onto real roads.
    ///
    /// MKDirections routes one pair at a time, so a multi-waypoint route is one
    /// request per leg, stitched together with the step offsets carried forward.
    // ponytail: mode is captured but unused here — the Phase 2 PCN engine swaps in
    // behind this signature. See specs/2026-09-04-create-route-experience-design.md §G.
    static func plan(through waypoints: [Coord],
                     mode: RideMode = .moderate,
                     fetchElevation: Bool = true) async throws -> RoutePlan {
        guard waypoints.count >= 2 else { return RoutePlan() }

        var plan = RoutePlan()
        var poly: [CLLocationCoordinate2D] = []

        for i in 0..<(waypoints.count - 1) {
            let req = MKDirections.Request()
            req.source = MKMapItem(location: waypoints[i].cl.location, address: nil)
            req.destination = MKMapItem(location: waypoints[i + 1].cl.location, address: nil)
            req.transportType = transport
            req.requestsAlternateRoutes = false

            let response = try await MKDirections(request: req).calculate()
            guard let leg = response.routes.first else { continue }

            var legCoords = leg.polyline.coordinates
            // The previous leg already ended on this point.
            if !poly.isEmpty, !legCoords.isEmpty { legCoords.removeFirst() }
            let offsetBefore = plan.distance

            plan.steps.append(contentsOf: flatten(leg, startingAt: offsetBefore,
                                                  isFirstLeg: i == 0,
                                                  isLastLeg: i == waypoints.count - 2))
            plan.distance += leg.distance
            plan.expected += leg.expectedTravelTime
            poly.append(contentsOf: legCoords)
        }

        // Recompute the tail step's offset off the real line rather than the sum
        // of the legs, so the turn list and the snapper agree to the metre.
        let cum = Geo.cumulative(poly)
        if let total = cum.last, total > 0 { plan.distance = total }

        if fetchElevation {
            plan.elevations = await elevations(along: poly)
        }

        // Climbing costs time: 10 m of ascent rides like an extra 100 m of flat.
        plan.expected = (plan.distance + plan.ascent * 10) / cruisingSpeed
        plan.polyline = zip(poly, plan.elevations.isEmpty ? [] : resample(plan.elevations, to: poly.count))
            .map { Coord($0.0, alt: $0.1) }
        if plan.polyline.isEmpty { plan.polyline = poly.map { Coord($0) } }
        return plan
    }

    /// Turn a leg's MKRouteSteps into StoredSteps.
    ///
    /// Each instruction is pinned to where its step's line begins, and the
    /// maneuver arrow comes from the angle between the previous step's exit
    /// heading and this step's entry heading — MKRouteStep gives the sentence
    /// but never the turn type.
    private static func flatten(_ route: MKRoute, startingAt offset: Double,
                                isFirstLeg: Bool, isLastLeg: Bool) -> [StoredStep] {
        var out: [StoredStep] = []
        var running = offset

        let entry: [Double?] = route.steps.map { Geo.entryBearing($0.polyline.coordinates) }
        let exit: [Double?] = route.steps.map { Geo.exitBearing($0.polyline.coordinates) }

        for (i, step) in route.steps.enumerated() {
            let here = running
            running += step.distance

            let isLastStep = i == route.steps.count - 1
            // Every leg ends with a zero-length arrival step. Only the final
            // one is a real arrival; the rest are just waypoints being passed.
            let zeroLength = step.distance == 0
            if zeroLength && !(isFirstLeg && i == 0) && !(isLastLeg && isLastStep) { continue }

            let angle: Double? = {
                guard let incoming = (exit[safe: i - 1] ?? nil), let outgoing = entry[i] else { return nil }
                return Geo.turn(from: incoming, to: outgoing)
            }()

            let maneuver: Maneuver
            if isFirstLeg && i == 0 {
                maneuver = .depart
            } else if isLastLeg && isLastStep {
                maneuver = .arrive
            } else if let spoken = Maneuver.read(step.instructions) {
                maneuver = spoken
            } else if let angle {
                maneuver = Maneuver.classify(turn: angle)
            } else {
                maneuver = .straight
            }

            let at = step.polyline.coordinates.first
            out.append(StoredStep(
                instruction: step.instructions.isEmpty
                    ? (maneuver == .arrive ? "Arrive" : "Continue")
                    : step.instructions,
                road: step.polyline.title ?? "",
                distance: step.distance,
                maneuverOffset: here,
                maneuverRaw: maneuver.rawValue,
                lat: at?.latitude ?? 0,
                lon: at?.longitude ?? 0))
        }
        return out
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
