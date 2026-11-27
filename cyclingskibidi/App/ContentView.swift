//
//  ContentView.swift
//  cyclingskibidi
//
//  Created by cheng xi on 23/5/26.
//

import SwiftUI
import SwiftData

@Observable
@MainActor
final class Trip {
    var route: Route?
    var finished: Ride?

    let recorder = RideRecorder()

    func begin(_ route: Route) {
        recorder.reset()
        recorder.load(route: route)
        self.route = route
    }

    func clear() {
        recorder.reset()
        route = nil
        finished = nil
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @State private var trip = Trip()
    @State private var path = NavigationPath()
    @Query private var obstacles: [Obstacle]
    @AppStorage(RiderProfile.storageKey) private var profileRaw = ""
    @State private var askInterests = false
    /// No profile at launch: after the welcome (which saves the fall setting), ask for interests.
    @State private var firstRun = false
    @AppStorage(AppSettings.onboarded) private var onboarded = false
    private var showWelcome: Bool {
        #if DEBUG
        if Demo.screen != nil { return false }   // demo screenshots skip onboarding
        #endif
        return !onboarded
    }

    var body: some View {
        NavigationStack(path: $path) {
            RouteListView()
        }
        // The welcome, then (first run only) the interests sheet.
        .fullScreenCover(isPresented: Binding(get: { showWelcome }, set: { _ in }),
                         onDismiss: { if firstRun { askInterests = true; firstRun = false } }) { OnboardingView() }
        .environment(trip)
        .fullScreenCover(item: $trip.route, onDismiss: { trip.clear(); path = NavigationPath() }) { route in   // ride over: back to Routes
            NavigateView(route: route)
                .environment(trip)
        }
        // First launch: ask once. Continue always writes the profile, so it never shows again.
        .sheet(isPresented: $askInterests) { InterestsSheet() }
        .onAppear {
            firstRun = profileRaw.isEmpty
            askInterests = profileRaw.isEmpty && onboarded
            #if DEBUG
            if Demo.screen != nil { askInterests = false }   // demo screenshots skip onboarding
            #endif
        }
        .task { _ = await PCNDataset.graph() }
        .task { _ = await RoadNetwork.graph() }
        // Every plan, re-plan and reroute avoids the rider's "Path closed" marks.
        .onChange(of: obstacles, initial: true) { Closures.marked = obstacles.compactMap(\.asClosure) }
        #if DEBUG
        .task { await openDemoScreen() }
        .overlay { if let a = Demo.alarm { KitAlarmView(alarm: a, onPrimary: {}, onSecondary: {}, onNotThere: {}) } }
        .overlay {
            switch Demo.screen {
            case "onboarding": OnboardingView()
            case "newroute": CreateRouteFlow()
            case "sight": SightSheet(sight: Discovery.places.first { Discovery.facts[$0.osmID ?? ""]?.note?.stalls?.isEmpty == false } ?? Discovery.places[0])
            case "sight-plain": SightSheet(sight: Discovery.places.first { $0.name == "Neighbourhood Park" } ?? Discovery.places[0])
            case "builder", "builder-route": RouteBuilderView(mode: .leisure)
            case "interests": InterestsSheet()
            case "mark": ObstacleReportView(coordinate: nil)
            case "stats": NavigationStack { StatsView() }
            case "settings": SettingsView()
            case "fall": AreYouOKView(deadline: .now.addingTimeInterval(24), onOK: {}, onRingNow: {})
            case "help": HelpAlarmView(since: .now, place: "Punggol Promenade", kmAlong: 14.2,
                                       coordinate: .init(latitude: 1.41235, longitude: 103.91012), onStop: {})
            default: EmptyView()
            }
        }
        #endif
    }

    #if DEBUG
    private func openDemoScreen() async {
        guard let screen = Demo.screen, let route = await Demo.seed(context) else { return }
        switch screen {
        case "detail", "detail-full", "detail-tap":   path.append(route)
        case "navigate": trip.begin(route)
        case "navigate-kit":   // a pass-by in the banner (v3 · 04)
            trip.begin(route)
            try? await Task.sleep(for: .seconds(3))
            var s = Sight(name: "Lorong Halus red bridge", category: "bridge", lat: 1.30, lon: 103.79)
            s.note = "Golden hour in 7 min, a good 2-minute photo stop"
            trip.recorder.passingSight = s
        case "finished":
            trip.begin(route)
            let plan = RoutePlan(polyline: route.polyline, steps: route.steps,
                                 distance: route.distanceMeters, expected: route.currentExpectedSeconds,
                                 elevations: route.elevations)
            trip.finished = Demo.finishedRide(along: plan)
        default: break
        }
    }
    #endif
}

#Preview {
    ContentView()
        .modelContainer(for: [Route.self, Obstacle.self, Ride.self], inMemory: true)
}
