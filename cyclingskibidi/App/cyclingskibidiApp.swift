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
        // Only on request (the test script passes -selfcheck): on a phone they hold up launch.
        if ProcessInfo.processInfo.arguments.contains("-selfcheck") { Self.runSelfChecks() }
        if ProcessInfo.processInfo.arguments.contains("-kiteval") { Task.detached { await KitEval.run() } }
        Self.watchMainThread()
        #endif
    }

    #if DEBUG
    /// Prints whenever the main thread stalls for over half a second, so a freeze on a phone shows in Xcode's console.
    private static func watchMainThread() {
        Thread.detachNewThread {
            while true {
                let pinged = Date.now, done = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { done.signal() }
                if done.wait(timeout: .now() + 0.5) == .timedOut {
                    done.wait()
                    print("MAIN THREAD BLOCKED \(Int(Date.now.timeIntervalSince(pinged) * 1000)) ms")
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
    }

    private static func runSelfChecks() {
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
        RideRecorder.speechOff = true
        RideRecorder.selfCheck()
        RideRecorder.selfCheckState()
        RideRecorder.selfCheckNoBike()
        RideRecorder.selfCheckAlarms()
        RideRecorder.selfCheckFall()
        RideRecorder.speechOff = false
        FlowLayout.selfCheck()
        Discovery.selfCheck()
        CreateRouteFlow.selfCheck()
        Obstacle.selfCheck()
        FallDetector.selfCheck()
        AlarmSound.selfCheck()
        RiderProfile.selfCheck()
        Kit.selfCheck()
        Task { await KitModel.selfCheck() }
        KitLearning.selfCheck()
        RestStops.selfCheck()
        HeatHint.selfCheck()
        PixelArt.selfCheck()
        RouteDetailView.selfCheck()
        KitColor.selfCheck()
        AlertScheme.selfCheck()
        BannerMessage.selfCheck()
        KitChart.selfCheck()
        KitFont.selfCheck()
        NoBike.selfCheck()
        Task { await Routing.selfCheckNoBike() }
        Task { await RestStops.selfCheckReal() }
        Task { await Routing.selfCheckScenic() }
        Task { await PresetLoops.selfCheck() }
        print("SELFCHECK sync done")
    }
    #endif

    var body: some Scene {
        WindowGroup {
        ContentView()
        }
        .modelContainer(container)
    }
}
