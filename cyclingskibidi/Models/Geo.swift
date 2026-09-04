//
//  Geo.swift
//  cyclingskibidi
//
//  The navigation maths. This is the "Google Maps algorithm" part: snap the raw
//  GPS fix perpendicularly onto the route line, measure how far along the route
//  that lands, advance the turn list off that distance, and call the rider
//  off-route when the perpendicular offset stays large. Maneuver arrows are
//  classified from the turn angle between consecutive legs, the same way a
//  routing engine derives them, because MKRouteStep does not hand them over.
//
//  Geo.selfCheck() at the bottom is the runnable check for all of it.
//

import Foundation
import CoreLocation

// MARK: - Maneuvers

enum Maneuver: String, Codable, Sendable {
    case depart, arrive, straight
    case slightLeft, left, sharpLeft
    case slightRight, right, sharpRight
    case uTurn

    /// The arrow drawn in the guidance banner.
    var glyph: String {
        switch self {
        case .depart:      return "📍"
        case .arrive:      return "📍"
        case .straight:    return "↑"
        case .slightLeft:  return "↖"
        case .left:        return "↰"
        case .sharpLeft:   return "↙"
        case .slightRight: return "↗"
        case .right:       return "↱"
        case .sharpRight:  return "↘"
        case .uTurn:       return "⤺"
        }
    }

    var symbol: String {
        switch self {
        case .depart:      return "location.fill"
        case .arrive:      return "mappin.circle.fill"
        case .straight:    return "arrow.up"
        case .slightLeft:  return "arrow.up.left"
        case .left:        return "arrow.turn.up.left"
        case .sharpLeft:   return "arrow.down.left"
        case .slightRight: return "arrow.up.right"
        case .right:       return "arrow.turn.up.right"
        case .sharpRight:  return "arrow.down.right"
        case .uTurn:       return "arrow.uturn.left"
        }
    }

    /// MapKit never exposes a maneuver type, only the sentence it generated —
    /// but that sentence *is* the router's maneuver, and it knows things the
    /// geometry cannot (which side of a fork, a signalled junction). So read the
    /// wording first and fall back to the turn angle.
    /// ponytail: Apple's English phrasing only. Any other language falls through
    /// to geometry, which is right about left-vs-right and vague about degree.
    static func read(_ instruction: String) -> Maneuver? {
        let t = instruction.lowercased()
        if t.contains("u-turn") || t.contains("u turn") { return .uTurn }
        if t.contains("sharp left") { return .sharpLeft }
        if t.contains("sharp right") { return .sharpRight }
        for hint in ["slight left", "bear left", "keep left", "slide left", "veer left"] where t.contains(hint) {
            return .slightLeft
        }
        for hint in ["slight right", "bear right", "keep right", "slide right", "veer right"] where t.contains(hint) {
            return .slightRight
        }
        if t.contains("turn left") || t.contains("left onto") || t.contains("left on ") { return .left }
        if t.contains("turn right") || t.contains("right onto") || t.contains("right on ") { return .right }
        if t.contains("continue") || t.contains("straight") { return .straight }
        return nil
    }

    /// Signed turn angle in degrees, positive to the right.
    static func classify(turn deg: Double) -> Maneuver {
        let a = abs(deg)
        if a < 15  { return .straight }
        if a > 170 { return .uTurn }
        if deg > 0 {
            if a < 45  { return .slightRight }
            if a < 135 { return .right }
            return .sharpRight
        } else {
            if a < 45  { return .slightLeft }
            if a < 135 { return .left }
            return .sharpLeft
        }
    }
}

/// One turn, flattened for storage. Offsets are metres from the route start.
struct StoredStep: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var instruction: String = ""
    /// Street the step travels along, when the routing engine names one.
    var road: String = ""
    /// How far the rider travels along this step after performing it.
    var distance: Double = 0
    /// Distance from the route start to where this instruction is carried out.
    ///
    /// A routing engine's step describes the turn that *begins* it — "turn right
    /// onto Portsdown Rd" is performed where that step's line starts, then
    /// followed for `distance`. Anchoring to the end instead announces every
    /// turn one street late.
    var maneuverOffset: Double = 0
    var maneuverRaw: String = Maneuver.straight.rawValue
    var lat: Double = 0
    var lon: Double = 0

    var maneuver: Maneuver { Maneuver(rawValue: maneuverRaw) ?? .straight }
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

extension Array where Element == StoredStep {
    /// Index of the maneuver the rider is riding towards: the first one still
    /// ahead of them, or the arrival once they are past them all.
    ///
    /// Strictly ahead — a turn 1 m away is still the turn being announced, not
    /// one already taken.
    func upcomingIndex(at along: Double) -> Int {
        firstIndex { $0.maneuverOffset > along } ?? Swift.max(count - 1, 0)
    }
}

// MARK: - Geometry

enum Geo {
    static let earthRadius = 6_371_008.8

    nonisolated static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let la1 = a.latitude * .pi / 180, la2 = b.latitude * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(la1) * cos(la2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * atan2(sqrt(h), sqrt(1 - h))
    }

    /// Flat local frame in metres, east/north of `origin`. Good to a centimetre
    /// over the few hundred metres a snap ever spans, and it turns the snap into
    /// plain 2D vector maths.
    static func project(_ c: CLLocationCoordinate2D, origin: CLLocationCoordinate2D) -> (x: Double, y: Double) {
        let lat0 = origin.latitude * .pi / 180
        let x = (c.longitude - origin.longitude) * .pi / 180 * earthRadius * cos(lat0)
        let y = (c.latitude - origin.latitude) * .pi / 180 * earthRadius
        return (x, y)
    }

    /// Compass bearing in degrees, 0 = north, clockwise.
    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let la1 = a.latitude * .pi / 180, la2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(la2)
        let x = cos(la1) * sin(la2) - sin(la1) * cos(la2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return deg < 0 ? deg + 360 : deg
    }

    /// Heading over the first `span` metres of a line.
    ///
    /// Routing polylines carry vertices a metre or two apart, and the bearing
    /// between one such pair is mostly GPS-grid noise. Measuring across a real
    /// baseline is what makes a turn angle mean anything.
    static func entryBearing(_ coords: [CLLocationCoordinate2D], span: Double = 20) -> Double? {
        guard let first = coords.first, coords.count >= 2 else { return nil }
        var travelled = 0.0
        for i in 1..<coords.count {
            travelled += distance(coords[i - 1], coords[i])
            if travelled >= span { return bearing(from: first, to: coords[i]) }
        }
        return bearing(from: first, to: coords[coords.count - 1])
    }

    /// Heading over the last `span` metres of a line.
    static func exitBearing(_ coords: [CLLocationCoordinate2D], span: Double = 20) -> Double? {
        guard let last = coords.last, coords.count >= 2 else { return nil }
        var travelled = 0.0
        for i in stride(from: coords.count - 2, through: 0, by: -1) {
            travelled += distance(coords[i], coords[i + 1])
            if travelled >= span { return bearing(from: coords[i], to: last) }
        }
        return bearing(from: coords[0], to: last)
    }

    /// Difference between two bearings, folded into -180...180. Positive = right.
    static func turn(from a: Double, to b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    /// Running distance to each vertex. `cumulative[i]` is the distance from the
    /// start of the line to `poly[i]`, so `cumulative.last` is the route length.
    static func cumulative(_ poly: [CLLocationCoordinate2D]) -> [Double] {
        guard !poly.isEmpty else { return [] }
        var out = [0.0]
        out.reserveCapacity(poly.count)
        for i in 1..<poly.count { out.append(out[i - 1] + distance(poly[i - 1], poly[i])) }
        return out
    }

    struct Snap: Sendable {
        /// Index of the segment the fix landed on.
        var index: Int
        /// Where along that segment, 0...1.
        var t: Double
        /// The fix pulled onto the line — this is what the map puck should show.
        var coordinate: CLLocationCoordinate2D
        /// Perpendicular offset from the line, in metres. Drives off-route.
        var lateral: Double
        /// Distance from the route start to the snapped point.
        var along: Double
        /// Direction of travel along the route at this point, in degrees.
        var course: Double
    }

    /// Pull `p` onto the polyline.
    ///
    /// Only segments `from ..< from + window` are considered, because a route
    /// that loops back on itself would otherwise snap a rider on lap two onto
    /// lap one. Callers pass the last matched segment as `from`; a full rescan
    /// is the caller's job when the result comes back far off the line.
    static func snap(_ p: CLLocationCoordinate2D,
                     to poly: [CLLocationCoordinate2D],
                     cumulative cum: [Double],
                     from: Int = 0,
                     window: Int = .max) -> Snap? {
        guard poly.count >= 2, cum.count == poly.count else { return nil }
        let lower = Swift.max(0, Swift.min(from, poly.count - 2))
        let upper = window == .max ? poly.count - 1
                                   : Swift.min(poly.count - 1, lower + window)
        guard lower < upper else { return nil }

        var best: Snap?
        for i in lower..<upper {
            let a = poly[i], b = poly[i + 1]
            let ab = project(b, origin: a)
            let ap = project(p, origin: a)
            let len2 = ab.x * ab.x + ab.y * ab.y
            let t = len2 > 0 ? Swift.max(0, Swift.min(1, (ap.x * ab.x + ap.y * ab.y) / len2)) : 0
            let cx = ab.x * t, cy = ab.y * t
            let lateral = ((ap.x - cx) * (ap.x - cx) + (ap.y - cy) * (ap.y - cy)).squareRoot()
            if best == nil || lateral < best!.lateral {
                let segLen = len2.squareRoot()
                let coord = CLLocationCoordinate2D(
                    latitude: a.latitude + (b.latitude - a.latitude) * t,
                    longitude: a.longitude + (b.longitude - a.longitude) * t)
                best = Snap(index: i, t: t, coordinate: coord, lateral: lateral,
                            along: cum[i] + segLen * t, course: bearing(from: a, to: b))
            }
        }
        return best
    }

    /// Coordinate at `metres` along the line, for placing maneuver pins.
    static func point(at metres: Double, on poly: [CLLocationCoordinate2D], cumulative cum: [Double]) -> CLLocationCoordinate2D? {
        guard let last = cum.last, !poly.isEmpty else { return nil }
        if metres <= 0 { return poly.first }
        if metres >= last { return poly.last }
        var i = 0
        while i + 1 < cum.count && cum[i + 1] < metres { i += 1 }
        let span = cum[i + 1] - cum[i]
        let t = span > 0 ? (metres - cum[i]) / span : 0
        return CLLocationCoordinate2D(
            latitude: poly[i].latitude + (poly[i + 1].latitude - poly[i].latitude) * t,
            longitude: poly[i].longitude + (poly[i + 1].longitude - poly[i].longitude) * t)
    }

    /// Ascent and descent from an altitude series.
    ///
    /// The threshold is the whole trick: barometric and GPS altitude both
    /// wander by a metre or two standing still, and summing every wobble
    /// invents hundreds of metres of climbing on a flat ride. Only count a
    /// direction change once it has been sustained.
    /// ponytail: fixed 3 m gate, the same number Strava-style trackers use.
    /// Make it a setting if a user's barometer is noisier than that.
    static func climb(_ altitudes: [Double], threshold: Double = 3) -> (up: Double, down: Double) {
        guard altitudes.count > 1 else { return (0, 0) }
        var up = 0.0, down = 0.0
        var anchor = altitudes[0]
        for alt in altitudes.dropFirst() {
            let d = alt - anchor
            if d >= threshold { up += d; anchor = alt }
            else if d <= -threshold { down -= d; anchor = alt }
        }
        return (up, down)
    }

    /// Evenly spaced sample of a line, for elevation lookups and graphs.
    static func sample(_ poly: [CLLocationCoordinate2D], count: Int) -> [CLLocationCoordinate2D] {
        guard poly.count > count, count > 1 else { return poly }
        let cum = cumulative(poly)
        guard let total = cum.last, total > 0 else { return poly }
        return (0..<count).compactMap { point(at: total * Double($0) / Double(count - 1), on: poly, cumulative: cum) }
    }
}

// MARK: - Self check

extension Geo {
    /// Runnable check for everything above. Called from the app's init in DEBUG.
    static func selfCheck() {
        // Known distance: 1 degree of latitude is ~111.2 km.
        let d = distance(.init(latitude: 1.30, longitude: 103.80),
                         .init(latitude: 1.31, longitude: 103.80))
        assert(abs(d - 1111.9) < 2, "haversine off: \(d)")

        // A due-east line, and a fix 20 m north of its midpoint.
        let a = CLLocationCoordinate2D(latitude: 1.30, longitude: 103.80)
        let b = CLLocationCoordinate2D(latitude: 1.30, longitude: 103.81)
        let poly = [a, b]
        let cum = cumulative(poly)
        let north = CLLocationCoordinate2D(latitude: 1.30 + 20 / 111_195.0, longitude: 103.805)
        guard let s = snap(north, to: poly, cumulative: cum) else { assertionFailure("snap failed"); return }
        assert(abs(s.lateral - 20) < 0.5, "lateral off: \(s.lateral)")
        assert(abs(s.along - cum[1] / 2) < 1, "along off: \(s.along)")
        assert(abs(turn(from: 0, to: s.course) - 90) < 0.5, "east bearing off: \(s.course)")

        // Clamping: a fix past the end of the line snaps to the end, not beyond.
        let past = CLLocationCoordinate2D(latitude: 1.30, longitude: 103.82)
        let sp = snap(past, to: poly, cumulative: cum)!
        assert(abs(sp.t - 1) < 1e-9 && abs(sp.along - cum[1]) < 0.01, "no clamp at end")

        // Bearing over a baseline ignores a jittery first pair. This line
        // wobbles one metre west, then runs 100 m due east.
        let jitter = [
            CLLocationCoordinate2D(latitude: 1.30, longitude: 103.80),
            CLLocationCoordinate2D(latitude: 1.30, longitude: 103.79999),
            CLLocationCoordinate2D(latitude: 1.30, longitude: 103.80090),
        ]
        let entry = entryBearing(jitter, span: 20)!
        assert(abs(turn(from: 90, to: entry)) < 5, "entry bearing followed the jitter: \(entry)")

        // The wording wins where it is unambiguous, geometry covers the rest.
        assert(Maneuver.read("Cross Portsdown Rd and bear left") == .slightLeft)
        assert(Maneuver.read("Turn right onto Ayer Rajah Ave") == .right)
        assert(Maneuver.read("Make a U-turn") == .uTurn)
        assert(Maneuver.read("Slide right") == .slightRight)
        assert(Maneuver.read("Prendre à gauche") == nil, "unknown wording must fall through")

        // Turn folding across north, and the arrow it produces.
        assert(abs(turn(from: 350, to: 10) - 20) < 1e-9, "turn should fold to +20")
        assert(Maneuver.classify(turn: 20) == .slightRight)
        assert(Maneuver.classify(turn: -90) == .left)
        assert(Maneuver.classify(turn: 179) == .uTurn)
        assert(Maneuver.classify(turn: 5) == .straight)

        // Climb ignores noise, counts the real hill.
        assert(climb([10, 11, 10, 11, 10]).up == 0, "noise counted as ascent")
        let hill = climb([0, 20, 5])
        assert(hill.up == 20 && hill.down == 15, "hill wrong: \(hill)")

        // point(at:) is the inverse of the cumulative table.
        let mid = point(at: cum[1] / 2, on: poly, cumulative: cum)!
        assert(abs(mid.longitude - 103.805) < 1e-6, "point(at:) off")

        // Step advancement. Depart at 0, turn at 300, turn at 900, arrive at 1500.
        let steps = [0.0, 300, 900, 1500].map {
            StoredStep(distance: 0, maneuverOffset: $0)
        }
        // Rolling off the line, the first turn is still ahead — never the depart.
        assert(steps.upcomingIndex(at: 0) == 1, "should point at the first turn")
        // Still announcing the turn right up to the junction.
        assert(steps.upcomingIndex(at: 299) == 1, "turn dropped a metre early")
        // And moving on once it is behind them.
        assert(steps.upcomingIndex(at: 301) == 2, "turn not counted as taken")
        assert(steps.upcomingIndex(at: 901) == 3, "should be riding to the arrival")
        // Past the end it sticks on the arrival rather than running off the array.
        assert(steps.upcomingIndex(at: 9999) == 3, "index escaped the step list")
    }
}
