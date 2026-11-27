//
//  SettingsView.swift
//  cyclingskibidi
//
//  Everything a rider may want to change after the first launch: what Kit picks for,
//  how alarms look and sound, fall detection, and resets. Values live in AppStorage.
//

import SwiftUI

/// AppStorage keys outside the rider profile.
nonisolated enum AppSettings {
    static let onboarded = "onboarded"
    static let voice = "voiceGuidance"        // spoken directions at the start of a ride
    static let warnBeep = "alarmWarnBeep"     // beep + buzz at 250 m, before an alarm takes over

    /// Read outside a view (the recorder's warn callback). Missing = on.
    static func flag(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}

/// Colours for the full-screen alarms. Presets only, so every one is checked for WCAG AA:
/// a free colour picker could make the alarm text unreadable.
nonisolated enum AlertScheme: String, CaseIterable, Identifiable {
    case kit, highVisibility, colourBlind

    static let storageKey = "alertScheme"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .kit: "Kit (ochre and terracotta)"
        case .highVisibility: "High visibility (yellow and red)"
        case .colourBlind: "Colour-blind safe (orange and blue)"
        }
    }

    /// Fills for hazard alarms and for no-access alarms (expressway, closure, walk).
    var fills: (obstacle: UInt32, noAccess: UInt32) {
        switch self {
        case .kit: (0xC5AF76, 0xB78773)
        case .highVisibility: (0xFFD60A, 0xC8102E)
        case .colourBlind: (0xE69F00, 0x005A9C)
        }
    }

    static let ink: UInt32 = 0x2B2A27, white: UInt32 = 0xFFFFFF

    /// Ink or white, whichever reads better on `fill`.
    static func text(on fill: UInt32) -> UInt32 {
        KitColor.contrast(ink, fill) >= KitColor.contrast(white, fill) ? ink : white
    }

    static var current: AlertScheme {
        AlertScheme(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .kit
    }

    static func selfCheck() {
        for s in allCases {
            for fill in [s.fills.obstacle, s.fills.noAccess] {
                assert(KitColor.contrast(text(on: fill), fill) >= 4.5, "\(s) alarm text fails WCAG AA on \(String(fill, radix: 16))")
                // Button outlines use the text colour; the filled button is ink, outlined so it reads on dark fills.
                assert(KitColor.contrast(text(on: fill), fill) >= 3, "\(s) button outlines fail non-text contrast")
            }
            assert(s.fills.obstacle != s.fills.noAccess, "\(s): hazard and no-access alarms must differ")
        }
        assert(text(on: 0xC5AF76) == ink && text(on: 0xC8102E) == white, "text colour follows the fill")
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(RiderProfile.storageKey) private var profileRaw = ""
    @AppStorage(AlertScheme.storageKey) private var scheme: AlertScheme = .kit
    @AppStorage(AppSettings.voice) private var voice = true
    @AppStorage(AppSettings.warnBeep) private var warnBeep = true
    @AppStorage(AppSettings.onboarded) private var onboarded = true

    @State private var showInterests = false
    @State private var showMarks = false
    @State private var showCredits = false
    @State private var confirmForget = false
    @State private var replayWelcome = false

    private var profile: Binding<RiderProfile> {
        Binding(get: { RiderProfile.decode(profileRaw) ?? RiderProfile() }, set: { profileRaw = $0.encoded })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Your riding") {
                    Button { showInterests = true } label: {
                        LabeledContent {
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        } label: {
                            Text("Interests and rider level").foregroundStyle(.primary)
                            Text(ridingSummary).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Picker("Alarm colours", selection: $scheme) {
                        ForEach(AlertScheme.allCases) { s in
                            HStack(spacing: 10) {
                                swatch(s.fills.obstacle)
                                swatch(s.fills.noAccess)
                                Text(s.label)
                            }
                            .tag(s)
                        }
                    }
                    .pickerStyle(.inline)
                } header: {
                    Text("Alarm colours")
                } footer: {
                    Text("The first colour is for hazards riders marked, the second for expressways, closures and walk-your-bike stretches.")
                }

                Section {
                    Toggle("Beep and buzz before an alarm", isOn: $warnBeep)
                    Toggle("Spoken directions", isOn: $voice)
                } header: {
                    Text("Sounds")
                } footer: {
                    Text("The help alarm always rings, even on silent and through the loudspeaker. Other alarms flash, vibrate and speak their warning even with spoken directions off; that speech follows the silent switch.")
                }

                Section {
                    Picker("Fall detection", selection: profile.fallSensitivity) {
                        ForEach(FallSensitivity.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("Safety")
                } footer: {
                    Text("If you fall hard and lie still, you get 30 seconds to say you're OK before a loud alarm rings with a button to call 995. Nothing is ever sent or called without a tap. High notices softer falls; Low only the hardest.")
                }

                Section {
                    Button("Forget what Kit has learned", role: .destructive) { confirmForget = true }
                } header: {
                    Text("Kit")
                } footer: {
                    Text("Kit learns from where you stop and skip. Your interests stay.")
                }

                Section {
                    Button("Your marks") { showMarks = true }
                    Button("Credits and data sources") { showCredits = true }
                    Button("Show the welcome again") { replayWelcome = true; dismiss() }
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                }
            }
            .kitScreen()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showInterests) { InterestsSheet() }
            .sheet(isPresented: $showMarks) { MarksView() }
            .sheet(isPresented: $showCredits) { CreditsView() }
            .confirmationDialog("Forget what Kit has learned?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget", role: .destructive) { profile.wrappedValue.weights = [:] }
            } message: {
                Text("Kit's picks go back to your interests alone.")
            }
        }
        // Only once this sheet has gone, so the welcome cover isn't stacked on it.
        .onDisappear { if replayWelcome { onboarded = false } }
    }

    private var ridingSummary: String {
        let p = profile.wrappedValue
        let likes = p.likes.isEmpty ? "No interests picked" : Interest.allCases.filter(p.likes.contains).map(\.label).joined(separator: ", ")
        return "\(likes) · \(p.level.label)"
    }

    private func swatch(_ hex: UInt32) -> some View {
        Rectangle().fill(Color(hex: hex)).frame(width: 22, height: 22)
            .overlay(Rectangle().strokeBorder(KitColor.ink, lineWidth: 2))
            .accessibilityHidden(true)
    }
}

#Preview { SettingsView() }
