//
//  PixelIcon.swift
//  cyclingskibidi
//
//  12×12 pixel pictograms for the road labels. Each '#' is one filled cell on a
//  24 pt grid (2 pt per cell). All cells go into a single Path, so adjacent
//  cells share an edge and the fill has no antialiasing seams.
//

import SwiftUI

nonisolated enum PixelArt {
    static let noBikes: [String] = [
        "#...........",
        ".#..........",
        "..#.....###.",
        "...#....#...",
        "....#.###...",
        "...#.#.##...",
        ".####.#.###.",
        "#...#..#.#.#",
        "#.####..#..#",
        "#...#..#.#.#",
        ".###....#.#.",
        "...........#",
    ]

    static let expressway: [String] = [
        "....#..#....",
        "....####....",
        "...#.##.#...",
        "...#....#...",
        "...#....#...",
        "..#..##..#..",
        "..#..##..#..",
        "..#......#..",
        ".#........#.",
        ".#...##...#.",
        "#....##....#",
        "#..........#",
    ]

    static let walkBike: [String] = [
        ".##.........",
        ".##.........",
        "..#.........",
        "..########..",
        "..#......#..",
        "..#..###.#..",
        "..#...#..#..",
        ".#.#..####..",
        ".#.#..#..#..",
        "#...###.###.",
        "#...#.#.#.#.",
        "....###.###.",
    ]

    static let closed: [String] = [
        "....####....",
        "..##....##..",
        ".#........#.",
        ".#........#.",
        "#..........#",
        "#.########.#",
        "#.########.#",
        "#..........#",
        ".#........#.",
        ".#........#.",
        "..##....##..",
        "....####....",
    ]
}

extension PixelArt {
    static func selfCheck() {
        let bitmaps: [String: [String]] = [
            "noBikes": noBikes,
            "expressway": expressway,
            "walkBike": walkBike,
            "closed": closed,
        ]
        for (name, rows) in bitmaps {
            assert(rows.count == 12, "\(name) has 12 rows, got \(rows.count)")
            for (r, row) in rows.enumerated() {
                assert(row.count == 12, "\(name) row \(r) has 12 characters: \(row)")
                assert(row.allSatisfy { $0 == "#" || $0 == "." }, "\(name) row \(r) uses only # and .")
            }
        }

        // The expressway glyph reads the same from either side.
        assert(expressway.allSatisfy { String($0.reversed()) == $0 }, "expressway is left–right symmetric")
        // The barred diagonal of the no-bikes glyph.
        for r in 0..<12 {
            assert(Array(noBikes[r])[r] == "#", "noBikes diagonal at row \(r)")
        }

        for kind in RoadLabelKind.allCases {
            assert(kind.text == kind.text.uppercased(), "\(kind.rawValue) text is uppercase")
            let expectedTone: RoadLabelTone = kind == .walkYourBike ? .caution : .noAccess
            assert(kind.tone == expectedTone, "\(kind.rawValue) has the right tone")
            let expectedArt: [String]
            switch kind {
            case .noBikes: expectedArt = noBikes
            case .expressway: expectedArt = expressway
            case .closed: expectedArt = closed
            case .walkYourBike: expectedArt = walkBike
            }
            assert(kind.art == expectedArt, "\(kind.rawValue) uses the right bitmap")
        }
    }
}

/// Draws a 12×12 bitmap in the current foreground style. Row 0 is the top.
struct PixelIcon: View {
    let rows: [String]
    var size: CGFloat = 16

    var body: some View {
        Canvas { context, canvasSize in
            let cell = min(canvasSize.width, canvasSize.height) / 12
            var path = Path()
            for (r, row) in rows.prefix(12).enumerated() {
                for (c, character) in row.enumerated() where character == "#" {
                    path.addRect(CGRect(x: CGFloat(c) * cell,
                                        y: CGFloat(r) * cell,
                                        width: cell,
                                        height: cell))
                }
            }
            context.fill(path, with: .foreground)
        }
        .frame(width: size, height: size)
    }
}
