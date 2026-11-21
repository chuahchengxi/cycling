//
//  BRouter.swift
//  cyclingskibidi
//
//  BRouter is a free, open-source, cycling-tuned OSM router. We use it only for
//  the connective bits — start/end to the nearest connector, interior gaps, and
//  the whole route in Fast mode. Path-favouring `trekking` prefers footpaths and
//  quiet ways over roads; `fastbike` is the roads-allowed fast profile. If
//  BRouter is unreachable we fall back to MapKit .walking so a route always
//  returns.
//

import Foundation
import MapKit

enum BRouterConfig {
    /// Public instance to start (best-effort, no SLA). Swap to a self-hosted
    /// instance here — one line, no code change — once traffic justifies it.
    /// ponytail: public server; self-host for reliability at scale.
    static var baseURL = "https://brouter.de/brouter"
    /// Gap/leisure links: prefer footpaths & pavements over roads.
    /// ponytail: profile name is a knob — confirm against BRouter's live list on-device.
    static let gapProfile = "trekking"
    /// Fast mode: roads allowed, quickest bike route.
    /// ponytail: profile name is a knob — confirm "fastbike" against BRouter's live profile list on-device.
    static let fastProfile = "fastbike"
}

/// An absolute exclusion circle for BRouter's `nogos` query item — the rider
/// marked this spot closed, so no route may pass within `radiusMeters` of it.
nonisolated struct NoGoCircle: Sendable {
    var coord: Coord
    var radiusMeters: Double
}

enum BRouter {

    /// `…/brouter?lonlats=lon,lat|lon,lat&profile=…&format=geojson`, plus an
    /// optional `nogos=lon,lat,radius|…` when the caller has active closures.
    /// Built via URLComponents so the pipe/comma separators are encoded correctly.
    static func url(lonlats: [Coord], profile: String, nogos: [NoGoCircle] = []) -> URL? {
        guard lonlats.count >= 2 else { return nil }
        let pairs = lonlats.map { "\($0.lon),\($0.lat)" }.joined(separator: "|")
        var comps = URLComponents(string: BRouterConfig.baseURL)
        var items = [
            URLQueryItem(name: "lonlats", value: pairs),
            URLQueryItem(name: "profile", value: profile),
            URLQueryItem(name: "alternativeidx", value: "0"),
            URLQueryItem(name: "format", value: "geojson"),
        ]
        let near = nearby(nogos, lonlats)
        if !near.isEmpty {
            let nogoPairs = near
                .map { "\($0.coord.lon),\($0.coord.lat),\(Int($0.radiusMeters.rounded()))" }
                .joined(separator: "|")
            items.append(.init(name: "nogos", value: nogoPairs))
        }
        comps?.queryItems = items
        return comps?.url
    }

    /// Only no-gos within 2 km of the waypoints' box; the bundled closures cover the island.
    static func nearby(_ nogos: [NoGoCircle], _ pts: [Coord]) -> [NoGoCircle] {
        guard let la0 = pts.map(\.lat).min(), let la1 = pts.map(\.lat).max(),
              let lo0 = pts.map(\.lon).min(), let lo1 = pts.map(\.lon).max() else { return [] }
        let pad = 2000 / PCNGraph.metresPerDegree
        return nogos.filter { (la0 - pad...la1 + pad).contains($0.coord.lat) && (lo0 - pad...lo1 + pad).contains($0.coord.lon) }
    }

    /// BRouter returns a GeoJSON FeatureCollection with a single LineString —
    /// the same shape the dataset uses, so the shared decoder handles it.
    static func decode(_ data: Data) -> [Coord] { GeoJSON.polylines(data).first ?? [] }

    /// Route the waypoints via BRouter; fall back to MapKit .walking on any
    /// failure so a connective segment always resolves. When `nogos` is
    /// non-empty, MapKit can't honor the exclusion, so a failed BRouter
    /// response returns no route instead of silently ignoring the closure.
    static func route(_ waypoints: [Coord], profile: String, nogos: [NoGoCircle] = []) async -> [Coord] {
        // Filter once: a closure 10 km away mustn't block the MapKit fallback below.
        let nogos = nearby(nogos, waypoints)
        guard let url = url(lonlats: waypoints, profile: profile, nogos: nogos) else { return [] }
        if let (data, resp) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 8)),
           (resp as? HTTPURLResponse)?.statusCode == 200 {
            let coords = decode(data)
            if coords.count >= 2 { return coords }
        }
        guard nogos.isEmpty else { return [] }
        // Fallback: stitch MapKit .walking leg by leg.
        // ponytail: if one interior leg can't route (MapKit returns []), that leg is
        // simply skipped, leaving a discontinuity rather than failing the whole route.
        // Only reachable when BRouter is down AND ≥3 waypoints AND a leg is unroutable;
        // upgrade to all-or-nothing (return [] so the caller's last-resort fires) if it bites.
        var out: [Coord] = []
        for i in 0..<(waypoints.count - 1) {
            var leg = await walk(from: waypoints[i], to: waypoints[i + 1])
            if !out.isEmpty, !leg.isEmpty { leg.removeFirst() }
            out.append(contentsOf: leg)
        }
        return out
    }

    /// MapKit walking directions between two points -> Coord line. The mandatory
    /// offline/last-resort path. [] if even MapKit can't route it.
    static func walk(from: Coord, to: Coord) async -> [Coord] {
        let req = MKDirections.Request()
        req.source = MKMapItem(location: from.cl.location, address: nil)
        req.destination = MKMapItem(location: to.cl.location, address: nil)
        req.transportType = .walking
        req.requestsAlternateRoutes = false
        guard let route = try? await MKDirections(request: req).calculate(),
              let leg = route.routes.first else { return [] }
        return leg.polyline.coordinates.map { Coord($0) }
    }
}

// MARK: - Self check

extension BRouter {
    static func selfCheck() {
        // URL is well-formed, lon before lat, profile carried.
        let u = url(lonlats: [Coord(lat: 1.30, lon: 103.80), Coord(lat: 1.31, lon: 103.81)],
                    profile: "trekking")!
        let s = u.absoluteString
        assert(s.contains("103.8,1.3") && s.contains("103.81,1.31"), "lonlats malformed: \(s)")
        assert(s.contains("profile=trekking") && s.contains("format=geojson"), "params missing: \(s)")
        // Fewer than 2 points -> no URL.
        assert(url(lonlats: [Coord(lat: 1.3, lon: 103.8)], profile: "trekking") == nil)
        // No no-gos passed -> the param is omitted entirely, not sent empty.
        assert(!s.contains("nogos"), "nogos should be omitted when none are passed: \(s)")
        // One no-go circle -> absolute lon,lat,radius appended.
        let withNogo = url(lonlats: [Coord(lat: 1.30, lon: 103.80), Coord(lat: 1.31, lon: 103.81)],
                           profile: "trekking",
                           nogos: [NoGoCircle(coord: Coord(lat: 1.305, lon: 103.805), radiusMeters: 25)])!
        assert(withNogo.absoluteString.contains("nogos=103.805,1.305,25"),
               "nogo malformed: \(withNogo.absoluteString)")
        // Two no-go circles -> pipe-joined, same as lonlats.
        let withTwoNogos = url(lonlats: [Coord(lat: 1.30, lon: 103.80), Coord(lat: 1.31, lon: 103.81)],
                               profile: "trekking",
                               nogos: [NoGoCircle(coord: Coord(lat: 1.305, lon: 103.805), radiusMeters: 25),
                                       NoGoCircle(coord: Coord(lat: 1.315, lon: 103.815), radiusMeters: 40)])!
        let nogosValue = URLComponents(url: withTwoNogos, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "nogos" })?.value
        assert(nogosValue == "103.805,1.305,25|103.815,1.315,40",
               "multiple nogos malformed: \(withTwoNogos.absoluteString)")
        // No-gos far from the request are dropped so the URL stays short.
        let farNogo = url(lonlats: [Coord(lat: 1.30, lon: 103.80), Coord(lat: 1.31, lon: 103.81)], profile: "trekking",
                          nogos: [NoGoCircle(coord: Coord(lat: 1.45, lon: 103.80), radiusMeters: 50)])!
        assert(!farNogo.absoluteString.contains("nogos"), "far no-go should be dropped: \(farNogo.absoluteString)")
        // A BRouter-shaped response decodes (lon,lat order preserved).
        let sample = """
        {"type":"FeatureCollection","features":[{"type":"Feature","geometry":
         {"type":"LineString","coordinates":[[103.80,1.30,15],[103.81,1.31,16]]}}]}
        """
        let line = decode(Data(sample.utf8))
        assert(line.count == 2 && abs(line[0].lat - 1.30) < 1e-9 && abs(line[0].alt - 15) < 1e-9,
               "BRouter decode wrong")
    }
}
