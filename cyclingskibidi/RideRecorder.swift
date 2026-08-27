//
//  RideRecorder.swift
//  cyclingskibidi
//
//  Live navigation: consumes the location stream, runs it through Geo's snapper,
//  drives the turn banner, speaks the guidance, records the track, and hands
//  back a finished Ride at the end.
//

import Foundation
import CoreLocation
import AVFoundation
import Observation

@Observable
@MainActor
final class RideRecorder {

    enum Phase { case idle, running, paused, finished }

    // Ride state
    private(set) var phase: Phase = .idle
    private(set) var distance: Double = 0
    private(set) var movingSeconds: Double = 0
    private(set) var speed: Double = 0
    private(set) var maxSpeed: Double = 0
    private(set) var track: [TrackPoint] = []
    private(set) var location: CLLocationCoordinate2D?
    /// The fix pulled onto the route line. Show this, not the raw fix.
    private(set) var snapped: CLLocationCoordinate2D?
    private(set) var course: Double = 0
    private(set) var authorizationDenied = false

    // Navigation state
    private(set) var steps: [StoredStep] = []
    private(set) var stepIndex: Int = 0
    private(set) var distanceToManeuver: Double = 0
    private(set) var distanceAlong: Double = 0
    private(set) var offRoute = false
    private(set) var rerouting = false

    var voiceEnabled = true

    var currentStep: StoredStep? { steps[safe: stepIndex] }
    var upcomingSteps: [StoredStep] { Array(steps.dropFirst(stepIndex)) }
    var routeLength: Double { cumulative.last ?? 0 }
    var remainingDistance: Double { max(0, routeLength - distanceAlong) }

    /// Remaining time from the rider's own rolling speed once they have one,
    /// falling back to the routing engine's estimate at the start.
    var remainingSeconds: Double {
        let pace = rollingSpeed > 1 ? rollingSpeed : (plannedDuration > 0 && routeLength > 0 ? routeLength / plannedDuration : 4.5)
        return remainingDistance / max(pace, 1)
    }

    var progress: Double { routeLength > 0 ? min(1, distanceAlong / routeLength) : 0 }

    // Route being followed
    private var polyline: [CLLocationCoordinate2D] = []
    private var cumulative: [Double] = []
    private var plannedDuration: Double = 0
    private var routeName = ""
    private var destination: Coord?

    // Internals
    private var task: Task<Void, Never>?
    private var startedAt = Date.now
    private var lastFixAt: Date?
    private var lastRecorded: CLLocation?
    private var searchIndex = 0
    private var offRouteStreak = 0
    private var rollingSpeed: Double = 0
    private var announced: Set<String> = []
    private let speaker = AVSpeechSynthesizer()

    /// Called when the rider has left the route and a new line is needed.
    var onReroute: ((RoutePlan) -> Void)?

    // MARK: - Lifecycle

    func load(route: Route) {
        polyline = route.polyline.coordinates
        cumulative = Geo.cumulative(polyline)
        steps = route.steps
        plannedDuration = route.expectedSeconds
        routeName = route.name
        destination = route.waypoints.last ?? route.polyline.last
        stepIndex = 0
        searchIndex = 0
        distanceAlong = 0
        announced.removeAll()
    }

    func start() {
        guard phase != .running else { return }
        if phase == .idle {
            startedAt = .now
            track = []
            distance = 0
            movingSeconds = 0
            maxSpeed = 0
        }
        phase = .running
        lastFixAt = nil
        listen()
        announce("Starting ride. \(currentStep?.instruction ?? "Follow the route.")")
    }

    func pause() {
        guard phase == .running else { return }
        phase = .paused
        lastFixAt = nil
    }

    func resume() { if phase == .paused { start() } }

    /// Stops the stream and returns the ride, ready to be inserted.
    func finish() -> Ride {
        task?.cancel(); task = nil
        phase = .finished
        speaker.stopSpeaking(at: .immediate)

        let ride = Ride(startedAt: startedAt, routeName: routeName, source: .app)
        ride.endedAt = .now
        ride.distanceMeters = distance
        ride.movingSeconds = movingSeconds
        ride.maxSpeed = maxSpeed
        let climb = Geo.climb(track.map(\.alt))
        ride.ascentMeters = climb.up
        ride.descentMeters = climb.down
        ride.trackData = Blob.encode(track)
        return ride
    }

    func reset() {
        task?.cancel(); task = nil
        phase = .idle
        track = []; distance = 0; movingSeconds = 0; speed = 0; maxSpeed = 0
        stepIndex = 0; distanceAlong = 0; offRoute = false; announced.removeAll()
    }

    // MARK: - Location stream

    private func listen() {
        guard task == nil else { return }
        task = Task { [weak self] in
            do {
                // .fitness tunes Core Location for a human moving under their own
                // power, and liveUpdates handles the permission prompt itself.
                for try await update in CLLocationUpdate.liveUpdates(.fitness) {
                    guard let self else { return }
                    if update.authorizationDenied || update.authorizationDeniedGlobally {
                        self.authorizationDenied = true
                        return
                    }
                    guard let loc = update.location else { continue }
                    self.consume(loc)
                    if Task.isCancelled { return }
                }
            } catch {
                self?.task = nil
            }
        }
    }

    private func consume(_ loc: CLLocation) {
        location = loc.coordinate
        // A fix with a 100 m error circle will fabricate distance if trusted.
        guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 50 else { return }

        let now = loc.timestamp
        let dt = lastFixAt.map { now.timeIntervalSince($0) } ?? 0
        lastFixAt = now

        let raw = max(0, loc.speed)
        speed = raw
        maxSpeed = max(maxSpeed, raw)
        // Exponential average, so the ETA does not lurch at every traffic light.
        rollingSpeed = rollingSpeed == 0 ? raw : rollingSpeed * 0.8 + raw * 0.2

        guard phase == .running else { return }

        if let prev = lastRecorded {
            let step = loc.distance(from: prev)
            // Stationary GPS jitter, not travel.
            if step > 2 { distance += step; lastRecorded = loc }
        } else {
            lastRecorded = loc
        }

        // Time stopped at a junction is not riding time.
        if raw > 0.5, dt > 0, dt < 30 { movingSeconds += dt }

        track.append(TrackPoint(lat: loc.coordinate.latitude,
                                lon: loc.coordinate.longitude,
                                alt: loc.altitude,
                                t: now.timeIntervalSince(startedAt),
                                speed: raw))

        follow(loc.coordinate)
    }

    // MARK: - The navigation loop

    private func follow(_ fix: CLLocationCoordinate2D) {
        guard polyline.count >= 2 else { return }

        // Search forward from where the rider was last matched. A couple of
        // segments of slack behind covers a fix arriving out of order.
        var snap = Geo.snap(fix, to: polyline, cumulative: cumulative,
                            from: max(0, searchIndex - 2), window: 80)

        // Far off the local window: the rider may have skipped ahead, doubled
        // back, or restarted mid-route. Rescan the whole line before deciding
        // they are lost.
        if snap == nil || snap!.lateral > 60 {
            if let full = Geo.snap(fix, to: polyline, cumulative: cumulative),
               full.lateral < (snap?.lateral ?? .greatestFiniteMagnitude) {
                snap = full
            }
        }
        guard let s = snap else { return }

        searchIndex = s.index
        distanceAlong = s.along
        snapped = s.lateral < 40 ? s.coordinate : fix
        course = s.course

        advanceSteps(to: s.along)

        // One bad fix should never trigger a reroute; a run of them should.
        if s.lateral > 40 {
            offRouteStreak += 1
            if offRouteStreak >= 3 && !offRoute { markOffRoute(from: fix) }
        } else {
            offRouteStreak = 0
            if offRoute { offRoute = false }
        }
    }

    /// The banner always shows the turn the rider is riding towards, so the
    /// current step is whichever maneuver they have not reached yet. Deriving it
    /// from the distance rather than latching an index means a fix that arrives
    /// late, or a rider who doubles back, self-corrects instead of sticking.
    private func advanceSteps(to along: Double) {
        guard !steps.isEmpty else { return }
        stepIndex = steps.upcomingIndex(at: along)
        guard let step = currentStep else { return }
        distanceToManeuver = max(0, step.maneuverOffset - along)
        speakGuidance(for: step)
    }

    /// Three tiers, the way every turn-by-turn app does it: a heads-up, a
    /// get-ready, and the turn itself.
    private func speakGuidance(for step: StoredStep) {
        let tiers: [(Double, String)] = [(400, "In 400 metres, "), (150, "In 150 metres, "), (40, "")]
        for (range, prefix) in tiers where distanceToManeuver <= range {
            let key = "\(stepIndex)-\(Int(range))"
            guard !announced.contains(key) else { continue }
            announced.insert(key)
            announce(prefix + step.instruction)
            return
        }
    }

    private func markOffRoute(from fix: CLLocationCoordinate2D) {
        offRoute = true
        announce("Off route. Recalculating.")
        guard let destination, !rerouting else { return }
        rerouting = true
        Task { [weak self] in
            defer { self?.rerouting = false }
            guard let plan = try? await Routing.plan(through: [Coord(fix), destination], fetchElevation: false),
                  !plan.polyline.isEmpty, let self else { return }
            self.polyline = plan.polyline.coordinates
            self.cumulative = Geo.cumulative(self.polyline)
            self.steps = plan.steps
            self.stepIndex = 0
            self.searchIndex = 0
            self.distanceAlong = 0
            self.offRoute = false
            self.offRouteStreak = 0
            self.announced.removeAll()
            self.onReroute?(plan)
            self.announce("Route updated. \(plan.steps.first?.instruction ?? "")")
        }
    }

    private func announce(_ text: String) {
        guard voiceEnabled, !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speaker.speak(utterance)
    }
}
