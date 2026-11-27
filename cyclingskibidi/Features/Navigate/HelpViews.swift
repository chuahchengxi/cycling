//
//  HelpViews.swift
//  cyclingskibidi
//
//  The two fall takeovers: a 30 s "Are you OK?" countdown, then the full-screen
//  HELP alarm with the rider's place, route position and a call to 995.
//

import SwiftUI
import CoreLocation
import AudioToolbox

/// "Are you OK?" (Figma v3 · 09). The digits come from the timeline so they keep
/// ticking even while idle; every second gets a haptic and every fifth second a
/// VoiceOver announcement.
struct AreYouOKView: View {
    let deadline: Date
    let onOK: () -> Void
    let onRingNow: () -> Void

    private let ink = Color(hex: 0x2B2A27), paper = Color(hex: 0xF4F1EA), gold = Color(hex: 0xC5AF76)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let left = max(0, deadline.timeIntervalSince(context.date))
            let seconds = Int(left.rounded(.up))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    KitAlarmedFigure(ring: paper, scale: 1.2)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 12)
                    KitChip(text: "Kit · fall detected", icon: "kit-icon-hazard", fill: gold)
                    Text("Are you OK?")
                        .font(.kitNumber(.largeTitle)).foregroundStyle(paper)
                    Text("Alarm in \(seconds) s")
                        .font(.system(size: 56, weight: .heavy, design: .monospaced))
                        .minimumScaleFactor(0.5).lineLimit(1)
                        .foregroundStyle(gold)
                        .contentTransition(.numericText(value: Double(seconds)))
                        .accessibilityLabel("Alarm in \(seconds) seconds")
                    KitSegmentBar(progress: left / RideRecorder.askSeconds, segments: 20,
                                  on: gold, off: .white.opacity(0.15), height: 14)
                    Text("Kit felt a hard hit and then no movement. If you don't answer, your phone rings a loud alarm, even on silent.")
                        .font(.body).foregroundStyle(paper)
                    VStack(spacing: 20) {
                        KitButton(title: "I'm OK", icon: "kit-icon-check", style: .primary, action: onOK)
                        KitButton(title: "Ring the alarm now", icon: "kit-icon-sound", style: .destructive, action: onRingNow)
                    }
                    .padding(.top, 24)
                }
                .padding(24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: seconds, initial: true) { _, n in
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                if n > 0, n % 5 == 0 {
                    UIAccessibility.post(notification: .announcement, argument: "Ringing for help in \(n) seconds")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ink.ignoresSafeArea())
        .environment(\.colorScheme, .light)   // Kit's fills keep their light values on the ink screen
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onAppear { UIAccessibility.post(notification: .screenChanged, argument: "Are you OK?") }
    }
}

/// The HELP alarm (Figma v3 · 10): flashes red and ink at 2 Hz (steady red with Reduce
/// Motion), where the rider is, and the two bystander actions. No automatic call: iOS needs a tap.
struct HelpAlarmView: View {
    let since: Date
    let place: String
    let kmAlong: Double
    let coordinate: CLLocationCoordinate2D?
    let onStop: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let ink = Color(hex: 0x2B2A27), paper = Color(hex: 0xF4F1EA)
    /// Kit/alarm-flash red: paper text on it passes WCAG AA.
    static let red: UInt32 = 0xB2211C

    var body: some View {
        TimelineView(.periodic(from: since, by: 0.25)) { context in
            let flashing = context.date.timeIntervalSince(since).truncatingRemainder(dividingBy: 0.5) >= 0.25
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    KitChip(text: "Alarm · max volume", icon: "kit-icon-sound")
                    Text("HELP!")
                        .font(.system(size: 96, weight: .heavy, design: .monospaced))
                        .minimumScaleFactor(0.5).lineLimit(1)
                        .accessibilityLabel("Help!")
                    Text("求救 · Tolong · உதவி").font(.title2.bold())
                    Text("This rider may have fallen. Call 995. Don't move them.")
                        .font(.title.bold())
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(place) · km \(kmAlong.formatted(.number.precision(.fractionLength(1))))").font(.headline)
                        Text("\(coordinate.map { String(format: "%.5f, %.5f", $0.latitude, $0.longitude) } ?? "Location unavailable") · \(since.formatted(date: .omitted, time: .shortened))")
                            .font(.subheadline.monospacedDigit())
                        Text("Medical ID is on this phone's lock screen").font(.subheadline)
                    }
                    .foregroundStyle(KitColor.ink)
                    .kitCard(shadow: true)
                    KitAlarmedFigure(ring: paper, scale: 0.9)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    VStack(spacing: 16) {
                        if let url = URL(string: "tel://995") {
                            Link(destination: url) { KitButtonLabel(title: "Call 995", icon: "kit-icon-phone", style: .primary) }
                                .accessibilityLabel("Call 995")
                        }
                        HoldButton(title: "Hold 3 s to stop alarm", icon: "kit-icon-stop", seconds: 3, bar: (paper, .white.opacity(0.25)), action: onStop)
                    }
                }
                .foregroundStyle(paper)
                .padding(24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background((reduceMotion || flashing ? Color(hex: Self.red) : ink).ignoresSafeArea())
        }
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onAppear {
            UIAccessibility.post(notification: .screenChanged, argument: "HELP alarm. Call 995. Don't move them.")
            AudioServicesPlayAlertSound(SystemSoundID(1005))
        }
    }
}

#Preview("Are you OK?") {
    AreYouOKView(deadline: .now.addingTimeInterval(30), onOK: {}, onRingNow: {})
}

#Preview("HELP") {
    HelpAlarmView(since: .now, place: "Park connector", kmAlong: 3.42,
                  coordinate: .init(latitude: 1.29234, longitude: 103.85412), onStop: {})
}
