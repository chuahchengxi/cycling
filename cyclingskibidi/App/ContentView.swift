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

    var body: some View {
        NavigationStack(path: $path) {
            RouteListView()
        }
        .environment(trip)
        .fullScreenCover(item: $trip.route) { route in
            NavigateView(route: route)
                .environment(trip)
        }
        .task { _ = PCNDataset.graph() }
        #if DEBUG
        .task { await openDemoScreen() }
        #endif
    }

    #if DEBUG
    private func openDemoScreen() async {
        guard let screen = Demo.screen, let route = await Demo.seed(context) else { return }
        switch screen {
        case "detail":   path.append(route)
        case "navigate": trip.begin(route)
        case "finished":
            trip.begin(route)
            let plan = RoutePlan(polyline: route.polyline, steps: route.steps,
                                 distance: route.distanceMeters, expected: route.expectedSeconds,
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
