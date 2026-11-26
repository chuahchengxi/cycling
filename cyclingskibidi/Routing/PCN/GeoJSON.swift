//
//  GeoJSON.swift
//  cyclingskibidi
//
//  Turning the bundled PCN GeoJSON FeatureCollection into connector polylines.
//  GeoJSON positions are [longitude, latitude, (elevation)] — never lat first.
//

import Foundation

nonisolated enum GeoJSON {

    /// Every LineString/MultiLineString in a FeatureCollection, as [lat,lon]
    /// Coord polylines. Returns [] on any parse failure — a bad dataset must
    /// flatten to "no connectors," never a crash.
    static func polylines(_ data: Data) -> [[Coord]] { named(data).map(\.line) }

    /// Each polyline with the connector's spoken name (see `spokenName`).
    static func named(_ data: Data) -> [(name: String?, line: [Coord])] {
        guard let fc = try? JSONDecoder().decode(FeatureCollection.self, from: data) else { return [] }
        var out: [(name: String?, line: [Coord])] = []
        for feature in fc.features {
            guard let geom = feature.geometry else { continue }
            let name = spokenName(park: feature.properties?.PARK, loop: feature.properties?.PCN_LOOP)
            switch geom.kind {
            case .line(let line):    out.append((name, coords(line)))
            case .multiLine(let ml): out += ml.map { (name, coords($0)) }
            case .other:             break
            }
        }
        return out.filter { $0.line.count >= 2 }
    }

    /// NParks' PARK field tidied for speech: first line only, no "(btwn ...)" notes,
    /// "PC" spelled out, no trailing section number. Falls back to the PCN loop name
    /// when PARK is a works label ("Interim RIR - ...") or a from-to stretch.
    static func spokenName(park: String?, loop: String?) -> String? {
        var s = park?.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        s = s.replacingOccurrences(of: #"\s*\(.*?(\)|$)"#, with: "", options: .regularExpression)
        for (from, to) in [(#"\bPC\b"#, "Park Connector"), (#"\bSg\b"#, "Sungei"), (#"\bRes\b"#, "Reservoir"), (#"\s+\d+$"#, "")] {
            s = s.replacingOccurrences(of: from, with: to, options: .regularExpression)
        }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s.contains("RIR") || s.contains(" to ") { s = loop?.trimmingCharacters(in: .whitespaces) ?? "" }
        return s.isEmpty ? nil : s
    }

    /// One position ring [[lon,lat,(ele)]] -> [Coord].
    private static func coords(_ ring: [[Double]]) -> [Coord] {
        ring.compactMap { p in
            guard p.count >= 2 else { return nil }
            return Coord(lat: p[1], lon: p[0], alt: p.count >= 3 ? p[2] : 0)
        }
    }

    // MARK: Decodable shapes

    private struct FeatureCollection: Decodable { let features: [Feature] }
    private struct Feature: Decodable { let geometry: Geometry?; let properties: Properties? }
    private struct Properties: Decodable { let PARK: String?; let PCN_LOOP: String? }

    /// GeoJSON geometry is variant: `coordinates` is [[Double]] for a LineString
    /// and [[[Double]]] for a MultiLineString. Decode `type` first, then the
    /// matching shape; everything else (points, polygons) is ignored.
    private struct Geometry: Decodable {
        enum Kind { case line([[Double]]); case multiLine([[[Double]]]); case other }
        let kind: Kind

        enum CodingKeys: String, CodingKey { case type, coordinates }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .type) {
            case "LineString":      kind = .line(try c.decode([[Double]].self, forKey: .coordinates))
            case "MultiLineString": kind = .multiLine(try c.decode([[[Double]]].self, forKey: .coordinates))
            default:                kind = .other
            }
        }
    }
}

// MARK: - Self check

extension GeoJSON {
    static func selfCheck() {
        // A LineString and a MultiLineString, both [lon,lat] with SG coordinates.
        // Also a degenerate LineString (1 point) to exercise the count >= 2 filter.
        let json = """
        {"type":"FeatureCollection","features":[
          {"type":"Feature","geometry":{"type":"LineString",
            "coordinates":[[103.800,1.300],[103.802,1.300]]}},
          {"type":"Feature","geometry":{"type":"MultiLineString",
            "coordinates":[[[103.802,1.300],[103.802,1.302]]]}},
          {"type":"Feature","geometry":{"type":"LineString",
            "coordinates":[[103.801,1.301]]}},
          {"type":"Feature","geometry":{"type":"Point","coordinates":[103.8,1.3]}}
        ]}
        """
        let lines = polylines(Data(json.utf8))
        assert(lines.count == 2, "expected 2 polylines, got \(lines.count)")
        // lon/lat not swapped: SG latitude is ~1.3, longitude ~103.8.
        assert(abs(lines[0][0].lat - 1.300) < 1e-9 && abs(lines[0][0].lon - 103.800) < 1e-9,
               "lon/lat swapped")
        // The point and degenerate-LineString features were ignored, short rings dropped.
        assert(lines.allSatisfy { $0.count == 2 })
        // Names tidied for speech.
        assert(spokenName(park: "Bukit Timah PC (btwn King Albert Park - Adam Rd)", loop: nil) == "Bukit Timah Park Connector")
        assert(spokenName(park: "Choa Chu Kang PC (KJE to Brickland Rd)\r\nChoa Chu K", loop: nil) == "Choa Chu Kang Park Connector")
        assert(spokenName(park: "Lower Seletar Res Park 3", loop: nil) == "Lower Seletar Reservoir Park")
        assert(spokenName(park: "Interim RIR - Jalan Kayu/Sengkang West Wat to Seng", loop: "Northern Explorer Loop") == "Northern Explorer Loop")
        assert(spokenName(park: nil, loop: nil) == nil)
    }
}
