//
//  Elevation.swift
//  cyclingskibidi
//
//  Bundled ~100 m elevation grid over Singapore (scripts/elevation/build.py),
//  so every planned or re-planned line gets its climb chart offline.
//

import Foundation
import CoreLocation

enum Elevation {
    // Must match scripts/elevation/build.py.
    static let lat0 = 1.15, lon0 = 103.60, step = 0.0009, rows = 380, cols = 580

    /// Decimetres, row-major from the south-west corner; [] if the file is missing.
    private static let grid: [Int16] = {
        guard let url = Bundle.main.url(forResource: "elevation", withExtension: "bin"),
              let d = try? Data(contentsOf: url), d.count == rows * cols * 2 else { return [] }
        return d.withUnsafeBytes { raw in
            (0..<rows * cols).map { Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) }
        }
    }()

    /// Metres above sea level, bilinear between grid points; nil off the grid.
    static func at(_ c: CLLocationCoordinate2D) -> Double? {
        let y = (c.latitude - lat0) / step, x = (c.longitude - lon0) / step
        guard !grid.isEmpty, y >= 0, x >= 0, y <= Double(rows - 1), x <= Double(cols - 1) else { return nil }
        let r = min(Int(y), rows - 2), col = min(Int(x), cols - 2)
        let fy = y - Double(r), fx = x - Double(col)
        func v(_ r: Int, _ c: Int) -> Double { Double(grid[r * cols + c]) / 10 }
        return (v(r, col) * (1 - fx) + v(r, col + 1) * fx) * (1 - fy)
             + (v(r + 1, col) * (1 - fx) + v(r + 1, col + 1) * fx) * fy
    }

    /// Profile along a line, `samples` points evenly spaced; [] if any point is off the grid.
    static func profile(along poly: [CLLocationCoordinate2D], samples: Int = 300) -> [Double] {
        let points = Geo.sample(poly, count: min(samples, max(poly.count, 2)))
        guard points.count >= 2 else { return [] }
        let out = points.compactMap { at($0) }
        return out.count == points.count ? out : []
    }

    static func selfCheck() {
        let hill = at(.init(latitude: 1.3546, longitude: 103.7764)) ?? 0
        let bay = at(.init(latitude: 1.2834, longitude: 103.8607)) ?? .infinity
        assert(hill > 100, "Bukit Timah should read as a hill: \(hill) m — is elevation.bin bundled?")
        assert(bay < 20, "Marina Bay should be near sea level: \(bay) m")
        assert(at(.init(latitude: 51.5, longitude: 0)) == nil, "off the grid must be nil")
        let climb = profile(along: [.init(latitude: 1.3400, longitude: 103.7764), .init(latitude: 1.3546, longitude: 103.7764)])
        assert(climb.count >= 2 && Geo.climb(climb).up > 50, "a line up Bukit Timah must climb: \(Geo.climb(climb))")
    }
}
