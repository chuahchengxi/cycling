//
//  NoBikeAlarm.swift
//  cyclingskibidi
//
//  The full-screen expressway alarm (Figma v3 · 12) for an off-route rider closing on
//  a no-bike entrance, plus the two banners plan 2b adds: walk your bike (v3 · 16)
//  and a reroute that was refused (v3 · 14).
//

import SwiftUI
import AudioToolbox

struct NoBikeAlarm: View {
    let entrance: NoBikeEntrance
    let distance: Double
    let onWayRound: () -> Void
    let onShowMap: () -> Void
    let onNotThere: () -> Void

    private var expressway: Bool { entrance.kind == "expressway" }

    var body: some View {
        ScrollView {   // large accessibility text on a small phone must still reach the buttons
        VStack(alignment: .leading, spacing: 20) {
            RoadLabel(kind: expressway ? .expressway : .noBikes)
            // Distance and what it is first (spec section 7), Kit smaller.
            Text("STOP IN \(Int(distance.rounded())) m")
                .font(.system(size: 56, weight: .black, design: .monospaced))
                .minimumScaleFactor(0.6).lineLimit(1)
                .contentTransition(.numericText())
                .accessibilityLabel("Stop in \(Int(distance.rounded())) metres")
            Text(expressway ? "Expressway ahead: bikes not allowed" : "No bikes ahead")
                .font(.title2.bold())
            Text(entrance.name.isEmpty
                 ? (expressway ? "This slip road joins an expressway." : "Bikes aren't allowed on this way.")
                 : "This is the way onto \(entrance.name).")
                .font(.body)
            VStack(spacing: 12) {
                button("Take the way round", filled: true, action: onWayRound)
                button("Show me on the map", filled: false, action: onShowMap)
                button("It's not there", filled: false, action: onNotThere)
            }
        }
        .padding(24)
        .padding(.top, 40)
        }
        .foregroundStyle(KitColor.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(KitColor.terracotta.ignoresSafeArea())
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

#Preview("Alarm") {
    NoBikeAlarm(entrance: NoBikeEntrance(kind: "expressway", name: "Ayer Rajah Expressway", lat: 1.29, lon: 103.78),
                distance: 42, onWayRound: {}, onShowMap: {}, onNotThere: {})
}
