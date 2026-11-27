//
//  KitAlarm.swift
//  cyclingskibidi
//
//  One full-screen alarm for everything the rider must not ride into: a marked
//  hazard (ochre), a closure the route still touches, a walk-your-bike stretch and
//  a no-bike entrance (terracotta). Plus the two banners plan 2b added: walk your
//  bike (Figma v3 · 16) and a refused reroute (v3 · 14).
//

import SwiftUI
import AudioToolbox

nonisolated struct KitAlarm: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case hazard(ObstacleKind), closure, walk, noBikes(expressway: Bool) }
    enum Tone: Sendable { case obstacle, noAccess }

    let key: String
    let kind: Kind
    let title: String
    let detail: String
    var distance: Double
    let coordinate: Coord
    /// The no-go radius to route round ("Find a way round" on a walk stretch).
    var radius: Double = 0

    var tone: Tone { if case .hazard = kind { return .obstacle } else { return .noAccess } }

    /// Kit's two buttons; every kind also has "It's not there".
    var buttons: (primary: String, secondary: String) {
        switch kind {
        case .hazard, .closure: return ("Take the detour", "I see it, carry on")
        case .walk: return ("I'll walk my bike", "Find a way round")
        case .noBikes: return ("Take the way round", "Show me on the map")
        }
    }
}

/// A closure or walk-your-bike stretch the line touches, as one alarm per closure.
nonisolated struct AlarmZone: Sendable {
    let key: String
    let walk: Bool
    let name: String
    let note: String
    let circles: [NoGoCircle]
}

/// The full-screen Kit alarm (Figma v3 · 07, 08, 11, 12): hazard tape top and bottom,
/// the label chip, distance and what it is first, Kit alarmed in rippling rings, then
/// Kit's buttons. Dark mode fills the screen with the alarm colour; light mode puts it
/// on a card over paper (v3 · 11).
struct KitAlarmView: View {
    let alarm: KitAlarm
    let onPrimary: () -> Void
    let onSecondary: () -> Void
    let onNotThere: () -> Void

    @AppStorage(AlertScheme.storageKey) private var scheme: AlertScheme = .kit
    @Environment(\.colorScheme) private var colorScheme
    private var light: Bool { colorScheme == .light }
    private var fill: UInt32 { alarm.tone == .obstacle ? scheme.fills.obstacle : scheme.fills.noAccess }
    private var text: Color { Color(hex: AlertScheme.text(on: fill)) }
    private var metres: Int { Int(alarm.distance.rounded()) }

    private var label: (icon: String, text: String) {
        switch alarm.kind {
        case .hazard: ("kit-icon-hazard", "KIT · OBSTACLE AHEAD")
        case .noBikes: ("kit-icon-expressway", "KIT · NO BIKES")
        case .closure: ("kit-icon-closed", "KIT · PATH CLOSED")
        case .walk: ("kit-icon-closed", "KIT · NO CYCLING")
        }
    }
    private var icons: (primary: String, secondary: String) {
        switch alarm.kind {
        case .hazard, .closure: ("kit-icon-chevron", "kit-icon-check")
        case .walk, .noBikes: ("kit-icon-flag", "kit-icon-chevron")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            KitHazardTape()
            GeometryReader { geo in
                ScrollView {   // large accessibility text on a small phone must still reach the buttons
                    VStack(spacing: 0) {
                        message
                        Spacer(minLength: 16)
                        KitAlarmedFigure(ring: light ? KitColor.ink : KitColor.paper)
                        Spacer(minLength: 16)
                        actions.padding(.horizontal, 24)
                    }
                    .padding(.top, 14)
                    .padding(.bottom, 28)
                    .frame(minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            KitHazardTape()
        }
        // Kit's ink, paper and sage are the same in both themes here; `light` only picks the layout.
        .environment(\.colorScheme, .light)
        .background((light ? KitColor.paper : Color(hex: fill)).ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onAppear {
            UIAccessibility.post(notification: .screenChanged, argument: nil)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            AudioServicesPlayAlertSound(SystemSoundID(1005))   // short alert tone
        }
    }

    /// Label chip, distance, what it is, Kit's line (v3 · 07 "Message").
    private var message: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(label.icon).renderingMode(.template).resizable().frame(width: 16, height: 16).accessibilityHidden(true)
                Text(label.text).font(.caption.bold()).tracking(0.96)
            }
            .foregroundStyle(KitColor.ink)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(light ? Color(hex: fill) : KitColor.paper)
            .overlay(Rectangle().stroke(KitColor.ink, lineWidth: 2))

            Text(alarm.tone == .noAccess ? "STOP IN \(metres) m" : "\(metres) m")
                .font(.system(size: alarm.tone == .noAccess ? 72 : 104, weight: .black, design: .monospaced))
                .minimumScaleFactor(0.4).lineLimit(1)
                .contentTransition(.numericText())
                .accessibilityLabel(alarm.tone == .noAccess ? "Stop in \(metres) metres" : "\(metres) metres ahead")
            Text(alarm.title).font(.title.bold())
            Text(alarm.detail).font(.body)
        }
        .foregroundStyle(text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(light ? 14 : 0)
        .background(light ? Color(hex: fill) : .clear)
        .overlay { if light { Rectangle().stroke(KitColor.ink, lineWidth: 2) } }
        .padding(.horizontal, light ? 16 : 24)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            KitButton(title: alarm.buttons.primary, icon: icons.primary, style: .primary, action: onPrimary)
            KitButton(title: alarm.buttons.secondary, icon: icons.secondary, style: .secondary, action: onSecondary)
            KitButton(title: "It's not there", icon: "kit-icon-close", style: .tertiary, action: onNotThere)
        }
    }
}

/// Kit/hazard-tape (225:2110): ochre and ink tape scrolling sideways; still with Reduce Motion.
struct KitHazardTape: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Stripes in an overlay so their 1380 pt width never widens the layout.
        KitColor.gold
            .frame(height: 28)
            .overlay(alignment: .leading) {
                TimelineView(.animation(paused: reduceMotion)) { context in
                    // One stripe period (28 pt) every 0.5 s, so the loop is seamless.
                    let shift = reduceMotion ? 0 : -28 * context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.5) / 0.5
                    HStack(spacing: 0) {
                        ForEach(0..<3, id: \.self) { _ in Image("kit-hazard-stripes").resizable().frame(width: 460, height: 28) }
                    }
                    .offset(x: shift)
                }
            }
            .clipped()
            .overlay(Rectangle().strokeBorder(KitColor.ink, lineWidth: 3))
        .accessibilityHidden(true)
    }
}

/// Kit/alarm-pulse behind Kit/alarmed (225:2063, 225:2135): square rings ripple out while
/// Kit wobbles with a pixel "!". Still with Reduce Motion.
struct KitAlarmedFigure: View {
    let ring: Color
    /// 1 = the 200 pt pulse of v3 · 07; the fall check uses 1.2, the HELP screen 0.9.
    var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = reduceMotion ? 0.45 : context.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .topLeading) {
                // Four rings a quarter-cycle apart, 1.8 s per ripple (0.45 s per Figma step).
                ForEach(0..<4, id: \.self) { i in
                    let p = (t / 1.8 + Double(i) / 4).truncatingRemainder(dividingBy: 1)
                    let side = 33.3 + (200 - 33.3) * p
                    Rectangle().stroke(ring, lineWidth: 5)
                        .frame(width: side, height: side)
                        .opacity(p < 1.0 / 3 ? p * 3 : (1 - p) * 1.5)
                        .position(x: 100, y: 100)
                }
                // Kit: a sage tile with a 4.65 pt ink border, tilted 7° (wobbling ±4°).
                let wobble = reduceMotion ? 7 : 7 + 4 * (Int(t / 0.16) % 2 == 0 ? 1.0 : -1.0)
                ZStack(alignment: .topLeading) {
                    KitColor.sage
                    Image("kit-alarmed").resizable().frame(width: 83.7, height: 83.7).offset(y: 2.32)
                }
                .frame(width: 93, height: 93)
                .clipped()
                .overlay(Rectangle().strokeBorder(KitColor.ink, lineWidth: 4.65))
                .rotationEffect(.degrees(wobble))
                .position(x: 38 + 62, y: 44 + 77.5)
                Image("kit-alarm-bang").renderingMode(.template).resizable()
                    .foregroundStyle(ring)
                    .frame(width: 12.4, height: 31)
                    .position(x: 38 + 102.3 + 6.2, y: 44 + 15.5)
            }
            .frame(width: 200, height: 200)
        }
        .frame(width: 200, height: 200)
        .scaleEffect(scale)
        .frame(width: 200 * scale, height: 200 * scale)
        .accessibilityHidden(true)
    }
}

#Preview("Expressway") {
    KitAlarmView(alarm: KitAlarm(key: "x", kind: .noBikes(expressway: true), title: "Expressway ahead: bikes not allowed",
                                 detail: "This is the way onto Ayer Rajah Expressway.", distance: 42, coordinate: Coord(lat: 1.29, lon: 103.78)),
                 onPrimary: {}, onSecondary: {}, onNotThere: {})
}

#Preview("Hazard") {
    KitAlarmView(alarm: KitAlarm(key: "h", kind: .hazard(.pothole), title: "Pothole", detail: "Deep, on the left.",
                                 distance: 80, coordinate: Coord(lat: 1.29, lon: 103.78)),
                 onPrimary: {}, onSecondary: {}, onNotThere: {})
}
