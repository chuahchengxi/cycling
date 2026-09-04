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

enum BRouter {

    /// `…/brouter?lonlats=lon,lat|lon,lat&profile=…&format=geojson`. Built via
    /// URLComponents so the pipe/comma separators are encoded correctly.
    static func url(lonlats: [Coord], profile: String) -> URL? {
        guard lonlats.count >= 2 else { return nil }
        let pairs = lonlats.map { "\($0.lon),\($0.lat)" }.joined(separator: "|")
        var comps = URLComponents(string: BRouterConfig.baseURL)
        comps?.queryItems = [
            .init(name: "lonlats", value: pairs),
            .init(name: "profile", value: profile),
            .init(name: "alternativeidx", value: "0"),
            .init(name: "format", value: "geojson"),
        ]
        return comps?.url
    }

    /// BRouter returns a GeoJSON FeatureCollection with a single LineString —
    /// the same shape the dataset uses, so the shared decoder handles it.
    static func decode(_ data: Data) -> [Coord] { GeoJSON.polylines(data).first ?? [] }

    /// Route the waypoints via BRouter; fall back to MapKit .walking on any
    /// failure so a connective segment always resolves.
    static func route(_ waypoints: [Coord], profile: String) async -> [Coord] {
        guard let url = url(lonlats: waypoints, profile: profile) else { return [] }
        if let (data, resp) = try? await URLSession.shared.data(from: url),
           (resp as? HTTPURLResponse)?.statusCode == 200 {
            let coords = decode(data)
            if coords.count >= 2 { return coords }
        }
        // Fallback: stitch MapKit .walking leg by leg.
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
