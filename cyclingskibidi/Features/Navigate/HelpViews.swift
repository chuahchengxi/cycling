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

/// "Are you OK?" (plan 6 Task 4). The digits come from the timeline so they keep
/// ticking even while the watch/phone is idle; every second gets a haptic and
/// every fifth second a VoiceOver announcement.
struct AreYouOKView: View {
    let deadline: Date
    let onOK: () -> Void
    let onRingNow: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let seconds = max(0, Int((deadline.timeIntervalSince(context.date)).rounded(.up)))
            VStack(spacing: 24) {
                Text("Are you OK?")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)

                Text("\(seconds)")
                    .font(.system(size: 120, weight: .black, design: .monospaced))
                    .minimumScaleFactor(0.4)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(seconds)))
                    .accessibilityLabel("\(seconds) seconds")

                Text("Ringing for help in \(seconds) seconds")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                VStack(spacing: 12) {
                    Button(action: onOK) {
                        Text("I'm OK")
                            .font(.title3.bold())
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(action: onRingNow) {
                        Text("Ring the alarm now")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(24)
            .onChange(of: seconds, initial: true) { _, n in
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                if n > 0, n % 5 == 0 {
                    UIAccessibility.post(notification: .announcement,
                                         argument: "Ringing for help in \(n) seconds")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onAppear {
            UIAccessibility.post(notification: .screenChanged, argument: "Are you OK?")
        }
    }
}

/// The HELP alarm: red/ink flash at 2 Hz (steady red with Reduce Motion), where
/// the rider is, and the two bystander actions. No automatic call — iOS needs a tap.
struct HelpAlarmView: View {
    let since: Date
    let place: String
    let kmAlong: Double
    let coordinate: CLLocationCoordinate2D?
    let onStop: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let ink = Color(.sRGB, red: 0.07, green: 0.07, blue: 0.09)
    /// Deep red: white text on it passes WCAG AA (system red doesn't).
    private let red = Color(.sRGB, red: 0.72, green: 0.04, blue: 0.04)

    var body: some View {
        TimelineView(.periodic(from: since, by: 0.25)) { context in
            let flashing = context.date.timeIntervalSince(since)
                .truncatingRemainder(dividingBy: 0.5) >= 0.25
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("HELP · 救命 · TOLONG · உதவி")
                        .font(.title.bold())
                        .minimumScaleFactor(0.6)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Call 995. Don't move them.")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Near \(place)").font(.title3.bold())
                        Text(String(format: "%.2f km ridden", kmAlong))
                            .font(.subheadline)
                        Text(coordinate.map { String(format: "%.5f, %.5f", $0.latitude, $0.longitude) }
                             ?? "Location unavailable")
                            .font(.subheadline.monospacedDigit())
                        Text(since.formatted(date: .abbreviated, time: .shortened))
                            .font(.footnote)
                    }

                    VStack(spacing: 12) {
                        if let url = URL(string: "tel://995") {
                            Link(destination: url) {
                                Label("Call 995", systemImage: "phone.fill")
                                    .font(.title3.bold())
                                    .frame(maxWidth: .infinity, minHeight: 52)
                                    .foregroundStyle(.white)
                                    .background(Color.black, in: .rect(cornerRadius: 18))
                            }
                        }
                        HoldButton(title: "Hold to stop alarm", seconds: 3, action: onStop)
                    }
                    .padding(16)
                    .background(ink, in: .rect(cornerRadius: 20))
                }
                .padding(24)
                .padding(.top, 40)
                .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(reduceMotion || flashing ? red : ink)
            .ignoresSafeArea()
        }
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
