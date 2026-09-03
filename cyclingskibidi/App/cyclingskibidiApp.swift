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
        RideMode.selfCheck()
        FlowLayout.selfCheck()
        Discovery.selfCheck()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}
