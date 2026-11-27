//
//  RoadLabel.swift
//  cyclingskibidi
//
//  The small square road-condition labels used in route detail and ride banners.
//  Colours come from the Kit "UI" palette; text, border and pixels are ink.
//

import SwiftUI

nonisolated enum KitColor {
    static let paper = Color(uiColor: UIColor { traits in
        rgb(traits.userInterfaceStyle == .dark ? 0x26242E : 0xF4F1EA)
    })
    static let ink = Color(uiColor: UIColor { traits in
        rgb(traits.userInterfaceStyle == .dark ? 0xEFE8D8 : 0x2B2A27)
    })
    static let terracotta = Color(uiColor: UIColor { traits in
        rgb(traits.userInterfaceStyle == .dark ? 0xA8604B : 0xB78773)
    })
    /// Kit's one primary colour (Kit/button primary) and its hard shadow.
    static let sage = Color(.sRGB, red: 0xA8 / 255.0, green: 0xB6 / 255.0, blue: 0x9A / 255.0)
    static let shadow = Color(.sRGB, red: 0x3B / 255.0, green: 0x33 / 255.0, blue: 0x55 / 255.0)
    static let gold = Color(uiColor: UIColor { traits in
        rgb(traits.userInterfaceStyle == .dark ? 0xA88A40 : 0xC5AF76)
    })

    /// WCAG contrast ratio of two sRGB colours.
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func lum(_ h: UInt32) -> Double {
            [(h >> 16) & 0xFF, (h >> 8) & 0xFF, h & 0xFF].map { v -> Double in
                let c = Double(v) / 255
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }.enumerated().reduce(0) { $0 + $1.element * [0.2126, 0.7152, 0.0722][$1.offset] }
        }
        let (x, y) = (lum(a), lum(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    static func selfCheck() {
        // Kit's filled surfaces render in their light values (see kitSurface): ink on them must pass AA.
        assert(contrast(0x2B2A27, 0xB78773) >= 4.5, "ink on terracotta fails WCAG AA")
        assert(contrast(0x2B2A27, 0xC5AF76) >= 4.5, "ink on gold fails WCAG AA")
        assert(contrast(0xF4F1EA, 0x2B2A27) >= 4.5, "paper on ink fails WCAG AA")
        assert(contrast(0xFFFFFF, 0xB80A0A) >= 4.5, "white on the HELP red fails WCAG AA")
        // Why kitSurface exists: the Figma dark values fail with either ink.
        assert(contrast(0xEFE8D8, 0xA8604B) < 4.5 && contrast(0x2B2A27, 0xA8604B) < 4.5)
    }

    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }
}

nonisolated enum RoadLabelTone: Equatable {
    case noAccess
    case caution

    var fill: Color {
        switch self {
        case .noAccess: return KitColor.terracotta
        case .caution: return KitColor.gold
        }
    }
}

nonisolated enum RoadLabelKind: String, CaseIterable {
    case noBikes
    case expressway
    case closed
    case walkYourBike

    var text: String {
        switch self {
        case .noBikes: return "NO BIKES"
        case .expressway: return "EXPRESSWAY · NO BIKES"
        case .closed: return "CLOSED"
        case .walkYourBike: return "WALK YOUR BIKE"
        }
    }

    var tone: RoadLabelTone {
        self == .walkYourBike ? .caution : .noAccess
    }

    var art: [String] {
        switch self {
        case .noBikes: return PixelArt.noBikes
        case .expressway: return PixelArt.expressway
        case .closed: return PixelArt.closed
        case .walkYourBike: return PixelArt.walkBike
        }
    }

    /// VoiceOver reads the label in sentence case, not all caps.
    var spoken: String {
        text.prefix(1).uppercased() + text.dropFirst().lowercased()
    }
}

struct RoadLabel: View {
    let kind: RoadLabelKind

    var body: some View {
        HStack(spacing: 6) {
            PixelIcon(rows: kind.art)
            Text(kind.text)
                .font(.system(size: 12, weight: .bold))
                .tracking(12 * 0.08)
        }
        .foregroundStyle(KitColor.ink)
        .padding(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
        .background(kind.tone.fill)
        .border(KitColor.ink, width: 2)
        .kitSurface()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind.spoken)
    }
}

#Preview("Road labels · light") {
    VStack(alignment: .leading, spacing: 12) {
        ForEach(RoadLabelKind.allCases, id: \.rawValue) { RoadLabel(kind: $0) }
    }
    .padding(20)
    .background(KitColor.paper)
    .preferredColorScheme(.light)
}

#Preview("Road labels · dark") {
    VStack(alignment: .leading, spacing: 12) {
        ForEach(RoadLabelKind.allCases, id: \.rawValue) { RoadLabel(kind: $0) }
    }
    .padding(20)
    .background(KitColor.paper)
    .preferredColorScheme(.dark)
}

extension View {
    /// Kit's terracotta and gold surfaces always use their light values with dark ink:
    /// the Figma dark-mode fills (#A8604B, #A88A40) fail WCAG AA with either ink.
    func kitSurface() -> some View { environment(\.colorScheme, .light) }
}
