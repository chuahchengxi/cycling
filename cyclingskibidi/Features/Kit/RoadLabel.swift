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
    static let gold = Color(uiColor: UIColor { traits in
        rgb(traits.userInterfaceStyle == .dark ? 0xA88A40 : 0xC5AF76)
    })

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
