//
//  OnboardingView.swift
//  cyclingskibidi
//
//  First launch: who Kit is, the safety net, and fall detection, then the interests
//  sheet. Replayable from Settings.
//

import SwiftUI

struct OnboardingView: View {
    @AppStorage(AppSettings.onboarded) private var onboarded = false
    @AppStorage(RiderProfile.storageKey) private var profileRaw = ""
    @State private var page = 0
    @State private var sensitivity: FallSensitivity = .normal

    private let lastPage = 2

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip") { finish() }.frame(minWidth: 52, minHeight: 52)
            }
            .padding(.horizontal, 12)

            TabView(selection: $page) {
                welcome.tag(0)
                safety.tag(1)
                falls.tag(2)
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                if page < lastPage { withAnimation { page += 1 } } else { finish() }
            } label: {
                Text(page < lastPage ? "Next" : "Pick what you like")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .padding(20)
        }
        .onAppear { sensitivity = (RiderProfile.decode(profileRaw) ?? RiderProfile()).fallSensitivity }
    }

    private var welcome: some View {
        pageView(symbol: "cat.fill", title: "Hi, I'm Kit",
                 text: "I plan bike rides on Singapore's park connectors and pick stops you'll like along the way: hawker centres, views, heritage, cafés.\n\nEverything works with no signal. The maps, routes and places are all on your phone.")
    }

    private var safety: some View {
        pageView(symbol: nil, title: "I keep you off roads bikes can't use",
                 text: "If you're heading for an expressway, a closed path or a walk-your-bike stretch, or a hazard other riders marked, I warn you early and then fill the screen.\n\nIf I'm wrong, tap \"It's not there\" and I'll stay quiet about that spot for the ride.") {
            HStack(spacing: 8) {
                RoadLabel(kind: .expressway)
                RoadLabel(kind: .closed)
                RoadLabel(kind: .walkYourBike)
            }
        }
    }

    private var falls: some View {
        pageView(symbol: "figure.fall", title: "If you fall",
                 text: "While you ride, I notice a hard fall followed by lying still. I ask if you're OK, and after 30 seconds I ring a loud alarm with a big Call 995 button for anyone nearby. I never call or message anyone by myself.\n\niOS will ask for location and motion access when you start your first ride.") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Fall detection", selection: $sensitivity) {
                    ForEach(FallSensitivity.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("You can change this in Settings.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func pageView<Extra: View>(symbol: String?, title: String, text: String,
                                       @ViewBuilder extra: () -> Extra = { EmptyView() }) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 56)).foregroundStyle(.tint).accessibilityHidden(true)
                }
                Text(title).font(.largeTitle.bold())
                Text(text).font(.body)
                extra()
            }
            .padding(24)
            .padding(.bottom, 40)   // clear the page dots
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Saved at once, so it holds even if the interests sheet is swiped away.
    private func finish() {
        var p = RiderProfile.decode(profileRaw) ?? RiderProfile()
        p.fallSensitivity = sensitivity
        profileRaw = p.encoded
        onboarded = true
    }
}

#Preview { OnboardingView() }
