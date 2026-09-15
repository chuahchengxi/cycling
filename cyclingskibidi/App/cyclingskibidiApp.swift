//
//  cyclingskibidiApp.swift
//  cyclingskibidi
//
//  Created by cheng xi on 23/5/26.
//

import SwiftUI
import SwiftData

@main
struct cyclingskibidiApp: App {
    let container: ModelContainer = {
        do {
            return try ModelContainer(for: Route.self, Obstacle.self, Ride.self)
        } catch {
            // A schema the store cannot open is a bug, not a runtime condition.
            fatalError("Could not open the local store: \(error)")
        }
    }()

    init() {
        #if DEBUG
        Geo.selfCheck()
        GeoJSON.selfCheck()
        PCNGraph.selfCheck()
        PCNGraph.selfCheckAStar()
        BRouter.selfCheck()
        Task { await PCNDataset.selfCheck() }
        Task { await PCNRouting.selfCheck() }
        RideMode.selfCheck()
        Routing.selfCheck()
        RideRecorder.selfCheck()
        RideRecorder.selfCheckState()
        FlowLayout.selfCheck()
        Discovery.selfCheck()
        CreateRouteFlow.selfCheck()
        Obstacle.selfCheck()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}
