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
        // 1.7 MB of no-bike ways: decode it off the main actor before the first plan needs it.
        Task.detached { _ = NoBike.lines }
        #if DEBUG
        Geo.selfCheck()
        GeoJSON.selfCheck()
        PCNGraph.selfCheck()
        PCNGraph.selfCheckAStar()
        Elevation.selfCheck()
        Closures.selfCheck()
        Task { await PCNDataset.selfCheck() }
        Task { await PCNRouting.selfCheck() }
        Task { await RoadNetwork.selfCheck() }
        TilePack.selfCheck()
        RideMode.selfCheck()
        Routing.selfCheck()
        RideRecorder.selfCheck()
        RideRecorder.selfCheckState()
        RideRecorder.selfCheckNoBike()
        FlowLayout.selfCheck()
        Discovery.selfCheck()
        CreateRouteFlow.selfCheck()
        Obstacle.selfCheck()
        RiderProfile.selfCheck()
        Kit.selfCheck()
        Task { await KitModel.selfCheck() }
        KitLearning.selfCheck()
        PixelArt.selfCheck()
        NoBike.selfCheck()
        Task { await Routing.selfCheckNoBike() }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}
