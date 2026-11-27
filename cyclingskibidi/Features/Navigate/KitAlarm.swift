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

struct KitAlarmView: View {
    let alarm: KitAlarm
    let onPrimary: () -> Void
    let onSecondary: () -> Void
    let onNotThere: () -> Void

    @AppStorage(AlertScheme.storageKey) private var scheme: AlertScheme = .kit
    private var fill: UInt32 { alarm.tone == .obstacle ? scheme.fills.obstacle : scheme.fills.noAccess }
    private var text: Color { Color(hex: AlertScheme.text(on: fill)) }

    private var metres: Int { Int(alarm.distance.rounded()) }
    private var label: RoadLabelKind? {
        switch alarm.kind {
        case .noBikes(let expressway): return expressway ? .expressway : .noBikes
        case .closure: return .closed
        case .walk: return .walkYourBike
        case .hazard: return nil
        }
    }

    var body: some View {
        ScrollView {   // large accessibility text on a small phone must still reach the buttons
            VStack(alignment: .leading, spacing: 20) {
                if let label { RoadLabel(kind: label) }
                // Distance and what it is first (spec section 7), Kit smaller.
                Text(alarm.tone == .noAccess ? "STOP IN \(metres) m" : "\(metres) m")
                    .font(.system(size: 56, weight: .black, design: .monospaced))
                    .minimumScaleFactor(0.6).lineLimit(1)
                    .contentTransition(.numericText())
                    .accessibilityLabel(alarm.tone == .noAccess ? "Stop in \(metres) metres" : "\(metres) metres ahead")
                Text(alarm.title).font(.title2.bold())
                Label {
                    Text(alarm.detail).font(.body)
                } icon: {
                    Image(systemName: "cat.fill").accessibilityLabel("Kit")
                }
                VStack(spacing: 12) {
                    button(alarm.buttons.primary, filled: true, action: onPrimary)
                    button(alarm.buttons.secondary, filled: false, action: onSecondary)
                    button("It's not there", filled: false, action: onNotThere)
                }
            }
            .padding(24)
            .padding(.top, 40)
        }
        .foregroundStyle(text)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color(hex: fill).ignoresSafeArea())
        .overlay(alignment: .top) {   // walk stretches carry a band of the hazard colour on the no-access fill
            if alarm.kind == .walk { Color(hex: scheme.fills.obstacle).frame(height: 10).ignoresSafeArea() }
        }
        .kitSurface()
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onAppear {
            UIAccessibility.post(notification: .screenChanged, argument: nil)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            AudioServicesPlayAlertSound(SystemSoundID(1005))   // short alert tone
        }
    }

    private func button(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.headline)
                .frame(maxWidth: .infinity, minHeight: 52)   // 52 pt touch targets (spec 7)
                .foregroundStyle(filled ? KitColor.paper : KitColor.ink)
                .background(filled ? KitColor.ink : KitColor.paper)
                .overlay(Rectangle().stroke(KitColor.ink, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}

/// Gold "Walk your bike" banner while the rider is in a no-cycling zone (v3 · 16).
struct WalkBikeBanner: View {
    let zone: String

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                RoadLabel(kind: .walkYourBike)
                Text("\(zone) · moving time paused").font(.subheadline)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(KitColor.ink)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KitColor.gold)
        .overlay(Rectangle().stroke(KitColor.ink, lineWidth: 2))
        .kitSurface()
        .accessibilityElement(children: .combine)
    }
}

/// A reroute that would have needed a no-bike way was refused (v3 · 14).
struct RerouteBlockedBanner: View {
    let reason: String

    var body: some View {
        HStack(spacing: 12) {
            PixelIcon(rows: PixelArt.noBikes, size: 24)
            Text(reason).font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(KitColor.ink)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KitColor.terracotta)
        .overlay(Rectangle().stroke(KitColor.ink, lineWidth: 2))
        .kitSurface()
        .accessibilityElement(children: .combine)
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
