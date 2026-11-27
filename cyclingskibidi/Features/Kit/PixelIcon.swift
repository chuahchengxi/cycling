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

    // MARK: Place icons (map pins and Along the way rows)

    static let food: [String] = [
        ".......#..#.", "......#..#..", ".....#..#...", "....#..#....",
        "............", "############", "#..........#", ".#........#.",
        ".#........#.", "..#......#..", "...######...", "....####....",
    ]
    static let photo: [String] = [
        "............", "....####....", "...#....#...", "############",
        "#..........#", "#...####...#", "#..#....#..#", "#..#....#..#",
        "#...####...#", "#..........#", "############", "............",
    ]
    static let water: [String] = [
        ".....##.....", ".....##.....", "....####....", "....####....",
        "...######...", "..########..", "..#.######..", ".##.#######.",
        ".##..######.", ".###..#####.", "..########..", "...######...",
    ]
    static let rest: [String] = [
        "............", "............", "############", "############",
        "............", "############", "############", ".#........#.",
        ".#........#.", ".#........#.", ".#........#.", "............",
    ]
    static let heritage: [String] = [
        "############", "#..........#", ".##########.", ".#........#.",
        ".#.######.#.", ".#........#.", ".#.######.#.", ".#........#.",
        ".#.####...#.", ".##########.", "#..........#", "############",
    ]
    static let architecture: [String] = [
        ".....##.....", "...######...", ".##########.", "############",
        "............", ".#..#..#..#.", ".#..#..#..#.", ".#..#..#..#.",
        ".#..#..#..#.", ".#..#..#..#.", "############", "############",
    ]
    static let wildlife: [String] = [
        "..##....##..", "..##....##..", "............", "##........##",
        "##..####..##", "...######...", "..########..", "..########..",
        "..########..", "...##..##...", "............", "............",
    ]
    static let art: [String] = [
        "...######...", ".##......##.", "#..##......#", "#..##..##..#",
        "#......##..#", "#.##.......#", "#.##...###.#", "#......#.#.#",
        ".#.....###.#", "..##......#.", "....#....#..", ".....####...",
    ]
    static let cafe: [String] = [
        "...#..#.....", "..#..#......", "...#..#.....", "............",
        "#########...", "#.......####", "#.......#..#", "#.......#..#",
        "#.......####", ".#.....#....", "..#####.....", "############",
    ]
    static let kids: [String] = [
        ".....##.....", ".....##.....", "......#.....", "..########..",
        "......#.....", "......#.....", ".....#.#....", "....#...#...",
        "...#.....#..", "............", "############", "#..........#",
    ]
    static let tourist: [String] = [
        ".....##.....", ".....##.....", "....####....", "############",
        ".##########.", "..########..", "...######...", "...######...",
        "..###..###..", "..##....##..", ".##......##.", "............",
    ]
    static let quiet: [String] = [
        ".....##.....", "...######...", "..########..", ".##########.",
        ".##########.", "############", ".##########.", "..########..",
        "....####....", ".....##.....", ".....##.....", "...######...",
    ]
    static let bridge: [String] = [
        "............", "............", "....####....", "..##....##..",
        ".#........#.", "############", "#..#....#..#", "#..#....#..#",
        "#..........#", "#..........#", "############", "............",
    ]

    /// places.json category → icon. Anything unknown falls back to `photo`.
    static let byCategory: [String: [String]] = [
        "park": quiet, "nationalPark": wildlife, "beach": quiet, "museum": architecture,
        "aquarium": wildlife, "zoo": wildlife, "amusementPark": kids, "cafe": cafe,
        "marina": photo, "stadium": architecture, "library": architecture, "attraction": tourist,
        "viewpoint": photo, "hawker": food, "restaurant": food, "worship": heritage,
        "bridge": bridge, "waterway": photo, "reservoir": quiet, "heritage": heritage,
        "artwork": art, "playground": kids, "drinkingWater": water, "toilets": rest,
        "shelter": rest, "bikeParking": rest, "repair": rest,
    ]

    static func forCategory(_ category: String) -> [String] { byCategory[category] ?? photo }
}

extension PixelArt {
    static func selfCheck() {
        let bitmaps: [String: [String]] = [
            "noBikes": noBikes,
            "expressway": expressway,
            "walkBike": walkBike,
            "closed": closed,
            "food": food, "photo": photo, "water": water, "rest": rest, "heritage": heritage,
            "architecture": architecture, "wildlife": wildlife, "art": art, "cafe": cafe,
            "kids": kids, "tourist": tourist, "quiet": quiet, "bridge": bridge,
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

        // Every place a pin or row can show has its own icon, not the fallback.
        for category in Discovery.leisureCategories.union(RestStops.amenityCategories) {
            assert(byCategory[category] != nil, "\(category) has no pixel icon")
        }
        assert(forCategory("hawker") == food && forCategory("nope") == photo, "forCategory maps and falls back")

        assert(HoldButton.progress(held: 1.5, of: 3) == 0.5, "hold progress is held / seconds")
        assert(HoldButton.progress(held: 5, of: 3) == 1 && HoldButton.progress(held: -1, of: 3) == 0, "hold progress clamps")
    }
}

/// A place's pixel icon on a Kit tile, for map pins. Says what the place is to VoiceOver.
struct PlacePin: View {
    let category: String
    let name: String

    var body: some View {
        // Figma v3 · 02 pins: a square pixel tile, 2 pt ink border; food terracotta,
        // rest stops paper, everything else sage. Light scheme so the ink stays dark on the map.
        PixelIcon(rows: PixelArt.forCategory(category), size: 16)
            .foregroundStyle(KitColor.ink)
            .padding(5)
            .background(["hawker", "restaurant", "cafe"].contains(category) ? KitColor.terracotta
                        : RestStops.amenityCategories.contains(category) ? KitColor.paper : KitColor.sage)
            .overlay(Rectangle().strokeBorder(KitColor.ink, lineWidth: 2))
            .environment(\.colorScheme, .light)
            .accessibilityElement()
            .accessibilityLabel("\(Discovery.icon(for: category).label): \(name)")
    }
}

/// Press and hold to act, as a Kit button: a darker fill sweeps across while held and an
/// optional pixel bar fills below; letting go early cancels. VoiceOver users get the
/// action directly (double-tap is deliberate).
struct HoldButton: View {
    let title: String
    var icon: String? = "kit-icon-stop"
    var style: KitButton.Style = .tertiary
    let seconds: Double
    /// Pixel progress under the button (on, off), as on the HELP screen.
    var bar: (on: Color, off: Color)? = nil
    let action: () -> Void

    @State private var pressedAt: Date?

    nonisolated static func progress(held: Double, of seconds: Double) -> Double {
        min(1, max(0, held / seconds))
    }

    var body: some View {
        TimelineView(.animation(paused: pressedAt == nil)) { context in
            let fill = pressedAt.map { Self.progress(held: context.date.timeIntervalSince($0), of: seconds) } ?? 0
            VStack(spacing: 16) {
                KitButtonLabel(title: title, icon: icon, style: style)
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in Color.black.opacity(0.18).frame(width: geo.size.width * fill) }
                            .allowsHitTesting(false)
                    }
                if let bar { KitSegmentBar(progress: fill, segments: 12, on: bar.on, off: bar.off, height: 6).accessibilityHidden(true) }
            }
        }
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: seconds, perform: {
            pressedAt = nil
            action()
        }, onPressingChanged: { pressing in pressedAt = pressing ? .now : nil })
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(title)
        .accessibilityHint("Press and hold for \(seconds.formatted()) seconds")
        .accessibilityAction { action() }
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
