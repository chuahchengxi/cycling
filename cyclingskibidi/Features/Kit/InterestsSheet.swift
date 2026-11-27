//
//  InterestsSheet.swift
//  cyclingskibidi
//
//  "What do you ride for?" (Figma v3 · 01). Shown once on first launch, then from
//  the routes list and the builder. Continue saves, even with nothing chosen.
//

import SwiftUI

struct InterestsSheet: View {
    @AppStorage(RiderProfile.storageKey) private var raw = ""
    @Environment(\.dismiss) private var dismiss
    @State private var profile = RiderProfile()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("What do you ride for?")
                    .font(.largeTitle.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)

                KitBubble(label: "Kit",
                          text: "Pick a few. I'll choose stops along your routes and learn from where you actually stop.")

                section("What I like", "Picks the places Kit suggests") {
                    ForEach(Interest.allCases, id: \.self) { i in
                        chip(i.label, i.kitIcon, on: profile.likes.contains(i)) {
                            profile.likes.formSymmetricDifference([i])
                        }
                    }
                }
                section("How I'm riding today", "Shapes the route itself") {
                    ForEach(RideContext.allCases, id: \.self) { c in
                        chip(c.label, c.kitIcon, on: profile.today.contains(c)) {
                            profile.today.formSymmetricDifference([c])
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("How long can you ride between stops?").font(.headline)
                    Text("Sets the gaps between rest stops").font(.footnote).foregroundStyle(KitColor.muted)
                    Picker("Rider level", selection: $profile.level) {
                        ForEach(RiderLevel.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(profile.level.detail).font(.footnote).foregroundStyle(KitColor.muted)
                }
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            KitButton(title: "Continue", icon: "kit-icon-chevron", style: .primary) {
                raw = profile.encoded
                dismiss()
            }
            .padding(20)
            .background(KitColor.paper)
        }
        .kitScreen()
        .onAppear { profile = RiderProfile.decode(raw) ?? RiderProfile() }
    }

    private func section<Chips: View>(_ title: String, _ subtitle: String, @ViewBuilder chips: () -> Chips) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(subtitle).font(.footnote).foregroundStyle(KitColor.muted)
            FlowLayout(spacing: 8) { chips() }
        }
    }

    /// Native capsule chips, as in Figma. The prominent style lets SwiftUI pick a
    /// label colour that contrasts with the tint in both themes; a fixed white
    /// label on Kit's light-green dark-mode tint would fail AA.
    @ViewBuilder
    private func chip(_ title: String, _ icon: String, on: Bool, toggle: @escaping () -> Void) -> some View {
        let label = Label {
            Text(title)
        } icon: {
            Image(icon).renderingMode(.template).resizable().frame(width: 16, height: 16)
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 12)

        Group {
            if on {
                Button(action: toggle) { label }
                    .buttonStyle(.borderedProminent)
                    .tint(KitColor.accentStrong)
            } else {
                Button(action: toggle) { label }
                    .buttonStyle(.bordered)
                    .tint(KitColor.muted)
            }
        }
        .buttonBorderShape(.capsule)
        .frame(minHeight: 44)   // keep the tap target without a taller-looking pill
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

extension Interest {
    /// Kit's pixel mark for each "What I like" chip (Figma v3 · 01).
    var kitIcon: String {
        switch self {
        case .nature: "kit-icon-photo"
        case .food: "kit-icon-food"
        case .architecture: "kit-icon-architecture"
        case .heritage: "kit-icon-heritage"
        case .wildlife: "kit-icon-wildlife"
        case .art: "kit-icon-art"
        case .cafes: "kit-icon-cafe"
        }
    }
}

extension RideContext {
    /// Kit's pixel mark for each "How I'm riding today" chip.
    var kitIcon: String {
        switch self {
        case .kids: "kit-icon-kids"
        case .visiting: "kit-icon-tourist"
        case .quiet: "kit-icon-quiet"
        }
    }
}

#Preview { InterestsSheet() }
