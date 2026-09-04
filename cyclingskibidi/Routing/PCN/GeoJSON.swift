//
//  GeoJSON.swift
//  cyclingskibidi
//
//  Turning a GeoJSON FeatureCollection into connector polylines. Shared by the
//  bundled PCN dataset and the BRouter response — both hand back the same shape.
//  GeoJSON positions are [longitude, latitude, (elevation)] — never lat first.
//

import Foundation

enum GeoJSON {

    /// Every LineString/MultiLineString in a FeatureCollection, as [lat,lon]
    /// Coord polylines. Returns [] on any parse failure — a bad dataset must
    /// flatten to "no connectors," never a crash.
    static func polylines(_ data: Data) -> [[Coord]] {
        guard let fc = try? JSONDecoder().decode(FeatureCollection.self, from: data) else { return [] }
        var out: [[Coord]] = []
        for feature in fc.features {
            guard let geom = feature.geometry else { continue }
            switch geom.kind {
            case .line(let line):    out.append(coords(line))
            case .multiLine(let ml): out.append(contentsOf: ml.map(coords))
            case .other:             break
            }
        }
        return out.filter { $0.count >= 2 }
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
    private struct Feature: Decodable { let geometry: Geometry? }

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
    }
}
