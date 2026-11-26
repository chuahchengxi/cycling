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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label {
                        Text("Pick a few. I'll choose stops along your routes and learn from where you actually stop.")
                    } icon: {
                        Image(systemName: "cat.fill")
                    }
                    .font(.subheadline)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 12))

                    section("What I like", "Picks the places Kit suggests") {
                        ForEach(Interest.allCases, id: \.self) { i in
                            chip(i.label, i.symbol, on: profile.likes.contains(i)) { profile.likes.formSymmetricDifference([i]) }
                        }
                    }
                    section("How I'm riding today", "Shapes the route itself") {
                        ForEach(RideContext.allCases, id: \.self) { c in
                            chip(c.label, c.symbol, on: profile.today.contains(c)) { profile.today.formSymmetricDifference([c]) }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("How long can you ride between stops?").font(.headline)
                        Picker("Rider level", selection: $profile.level) {
                            ForEach(RiderLevel.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Text(profile.level.detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .navigationTitle("What do you ride for?")
            .safeAreaInset(edge: .bottom) {
                Button {
                    raw = profile.encoded
                    dismiss()
                } label: {
                    Label("Continue", systemImage: "chevron.right")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .padding(20)
                .background(.bar)
            }
        }
        .onAppear { profile = RiderProfile.decode(raw) ?? RiderProfile() }
    }

    private func section<Chips: View>(_ title: String, _ subtitle: String, @ViewBuilder chips: () -> Chips) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            FlowLayout(spacing: 8) { chips() }
        }
    }

    private func chip(_ title: String, _ symbol: String, on: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .frame(minHeight: 52)
                .foregroundStyle(on ? .white : .primary)
                .background(on ? Color.accentColor : Color(.secondarySystemFill), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

#Preview { InterestsSheet() }
