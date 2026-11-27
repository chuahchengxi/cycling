//
//  KitStyle.swift
//  cyclingskibidi
//
//  Kit's system from the Figma file: paper background, ink text, square corners,
//  2 pt hard borders, one sage primary button with a hard shadow, monospaced numbers
//  (Jersey 10 in Figma) and 12×12 pixel icons. System chrome (tab bar, sheets,
//  alerts, nav bars) stays native, tinted with Kit's accent.
//

import SwiftUI

extension KitColor {
    /// Chart and inset fill (Figma "board").
    static let board = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? hex(0x1E1C25) : hex(0xE8E5DD) })
    /// Secondary text (Figma "muted").
    static let muted = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? hex(0xB4AFA3) : hex(0x5F6159) })
    /// Empty segments and hairlines (Figma "line").
    static let line = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? hex(0x4A4756) : hex(0xD6D3C9) })
    /// Filled progress segments (Figma "accent-strong").
    static let accentStrong = Color(.sRGB, red: 0x64 / 255.0, green: 0x7A / 255.0, blue: 0x5C / 255.0)

    fileprivate static func hex(_ h: UInt32) -> UIColor {
        UIColor(red: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255, blue: CGFloat(h & 0xFF) / 255, alpha: 1)
    }
}

extension Font {
    /// Kit's numerals (Jersey 10 in Figma). Monospaced heavy until the font is bundled;
    /// swap this one line then. Follows Dynamic Type.
    static func kitNumber(_ style: Font.TextStyle) -> Font { .system(style, design: .monospaced).weight(.heavy) }
    /// Small-caps style label used on Kit chips and bubbles ("KIT · PICKED FOR YOU").
    static let kitLabel = Font.caption2.weight(.bold)
}

extension View {
    /// A Kit card: square, filled, 2 pt ink border, optional 3 pt hard shadow.
    func kitCard(_ fill: Color = KitColor.paper, shadow: Bool = false, padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill)
            .overlay(Rectangle().strokeBorder(KitColor.ink, lineWidth: 2))
            .background(alignment: .topLeading) { if shadow { KitColor.shadow.offset(x: 3, y: 3) } }
    }

    /// Paper behind a whole screen, Kit's ink as the text colour, Kit's accent on native controls.
    func kitScreen() -> some View {
        self.foregroundStyle(KitColor.ink)
            .tint(KitColor.accentStrong)
            .scrollContentBackground(.hidden)
            .background(KitColor.paper.ignoresSafeArea())
    }
}

/// Kit/button (Figma 220:695): square, 2 pt ink border, a 20 pt pixel icon. Primary is sage
/// with a hard shadow, one per screen; secondary paper; tertiary a shorter paper button;
/// destructive terracotta (End ride), never scary red.
struct KitButton: View {
    enum Style { case primary, secondary, tertiary, destructive }
    let title: String
    var icon: String? = nil
    var style: Style = .secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) { KitButtonLabel(title: title, icon: icon, style: style) }
            .buttonStyle(.plain)
    }
}

/// The look of a Kit button, for places that need it without a Button (HoldButton, links).
struct KitButtonLabel: View {
    let title: String
    var icon: String? = nil
    var style: KitButton.Style = .secondary

    var body: some View {
        let filled = style == .primary || style == .destructive
        HStack(spacing: 8) {
            if let icon { Image(icon).renderingMode(.template).resizable().frame(width: 20, height: 20).accessibilityHidden(true) }
            Text(title).font(style == .tertiary ? .subheadline.weight(.semibold) : .headline).multilineTextAlignment(.center)
        }
        .foregroundStyle(KitColor.ink)
        .padding(.horizontal, 20).padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: style == .tertiary ? 52 : 56)
        .background(style == .primary ? KitColor.sage : style == .destructive ? KitColor.terracotta : KitColor.paper)
        .overlay(Rectangle().strokeBorder(KitColor.ink, lineWidth: 2))
        .background(alignment: .topLeading) { if style == .primary { KitColor.shadow.offset(x: 3, y: 3) } }
        .contentShape(Rectangle())
        // Sage and terracotta are light fills: their ink stays dark in both themes (AA).
        .environment(\.colorScheme, filled ? .light : colorScheme)
    }
    @Environment(\.colorScheme) private var colorScheme
}

/// The label chip ("KIT · NO BIKES"): pixel icon, small caps, 2 pt ink border.
struct KitChip: View {
    let text: String
    var icon: String? = nil
    var fill: Color = KitColor.paper

    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(icon).renderingMode(.template).resizable().frame(width: 16, height: 16).accessibilityHidden(true) }
            Text(text.uppercased()).font(.kitLabel).tracking(0.9)
        }
        .foregroundStyle(KitColor.ink)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(fill)
        .overlay(Rectangle().strokeBorder(KitColor.ink, lineWidth: 2))
    }
}

/// Kit/avatar (230:2948): the pixel cat on sage. Happy for tips and picks, alarmed for warnings.
struct KitAvatar: View {
    enum Mood { case happy, alarmed }
    var mood: Mood = .happy
    var size: CGFloat = 40

    var body: some View {
        ZStack(alignment: .topLeading) {
            KitColor.sage
            Image(mood == .happy ? "kit-happy" : "kit-alarmed").resizable()
                .frame(width: size * 0.9, height: size * 0.9).offset(y: size / 40)
        }
        .frame(width: size, height: size)
        .clipped()
        .overlay(Rectangle().strokeBorder(KitColor.ink, lineWidth: max(2, size / 20)))
        .accessibilityHidden(true)
    }
}

/// Kit/bubble (214:58): Kit speaking. Paper, 2 pt ink border, hard shadow, Kit's face,
/// a small label and the line. Marks Kit's voice against native UI.
struct KitBubble<Actions: View>: View {
    let label: String
    let text: String
    var mood: KitAvatar.Mood = .happy
    var fill: Color = KitColor.paper
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                KitAvatar(mood: mood, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(label.uppercased()).font(.kitLabel).tracking(0.9).foregroundStyle(KitColor.muted)
                    Text(text).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                }
            }
            actions()
        }
        .foregroundStyle(KitColor.ink)
        .kitCard(fill, shadow: true, padding: 12)
        .accessibilityElement(children: .combine)
    }
}

extension KitBubble where Actions == EmptyView {
    init(label: String, text: String, mood: KitAvatar.Mood = .happy, fill: Color = KitColor.paper) {
        self.init(label: label, text: text, mood: mood, fill: fill) { EmptyView() }
    }
}

/// Pixel progress: square segments, filled up to `progress`.
struct KitSegmentBar: View {
    let progress: Double
    var segments: Int = 24
    var on: Color = KitColor.accentStrong
    var off: Color = KitColor.line
    var height: CGFloat = 8

    var body: some View {
        let lit = Int((min(max(progress, 0), 1) * Double(segments)).rounded())
        HStack(spacing: 3) {
            ForEach(0..<segments, id: \.self) { i in (i < lit ? on : off).frame(height: height) }
        }
        .accessibilityElement()
        .accessibilityValue("\(Int(min(max(progress, 0), 1) * 100)) percent")
    }
}

/// Kit/icon-button (220:702): a square map control. Caution (gold) is for hazards.
struct KitIconButton: View {
    let icon: String
    let label: String
    var caution = false
    var size: CGFloat = 48
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(icon).renderingMode(.template).resizable().frame(width: 22, height: 22)
                .foregroundStyle(KitColor.ink)
                .frame(width: size, height: size)
                .background(caution ? KitColor.gold : KitColor.paper)
                .overlay(Rectangle().strokeBorder(KitColor.ink, lineWidth: 2))
                .environment(\.colorScheme, caution ? .light : colorScheme)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
    @Environment(\.colorScheme) private var colorScheme
}

/// A big number over a small muted caption (Kit/timer's "9.6 km / to go").
struct KitStat: View {
    let value: String
    let caption: String
    var style: Font.TextStyle = .title2

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.kitNumber(style)).lineLimit(1).minimumScaleFactor(0.6)
            Text(caption).font(.caption).foregroundStyle(KitColor.muted)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Section title in Kit's voice: bold, ink, left aligned.
struct KitHeader: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.title3.bold()).foregroundStyle(KitColor.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}
