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
    /// Set when a manual reroute (e.g. around a marked closure) can't find a
    /// route; the current route is kept as-is. Cleared by `dismissRerouteFailure()`.
    private(set) var rerouteFailure: String?

    // Sights along this route, and the one to surface right now as the rider
    // reaches it. The view binds a card to `passingSight` and clears it on close.
    private(set) var sights: [Sight] = []
    var passingSight: Sight?

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
    private var mode: RideMode = .moderate

    // Internals
    private var task: Task<Void, Never>?
    private var startedAt = Date.now
    private var lastFixAt: Date?
    private var lastRecorded: CLLocation?
    private var searchIndex = 0
    private var offRouteStreak = 0
    /// True once the rider has snapped onto the line at least once. Until then
    /// there is no route to be "off" — so no recalculating at the start.
    private var joinedRoute = false
    private var rollingSpeed: Double = 0
    private var announced: Set<String> = []
    private var passedSights: Set<UUID> = []
    private let speaker = AVSpeechSynthesizer()

    /// Called when the rider has left the route and a new line is needed.
    var onReroute: ((RoutePlan) -> Void)?

    // MARK: - Lifecycle

    func load(route: Route) {
        polyline = route.polyline.coordinates
        cumulative = Geo.cumulative(polyline)
        steps = route.steps
        plannedDuration = route.currentExpectedSeconds
        routeName = route.name
        destination = route.waypoints.last ?? route.polyline.last
        mode = route.mode
        stepIndex = 0
        searchIndex = 0
        distanceAlong = 0
        joinedRoute = false
        announced.removeAll()
        sights = route.sights
        passedSights.removeAll()
        passingSight = nil
        rerouteFailure = nil
    }

    func start() {
        guard phase != .running else { return }
        let fresh = phase == .idle
        if fresh {
            startedAt = .now
            track = []
            distance = 0
            movingSeconds = 0
            maxSpeed = 0
        }
        phase = .running
        lastFixAt = nil
        listen()
        // Only the departure direction, and only on a real start — the tiered
        // guidance handles every turn after, and resume shouldn't re-announce.
        if fresh { announce(steps.first?.instruction ?? "Follow the route.") }
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
        stepIndex = 0; distanceAlong = 0; offRoute = false; joinedRoute = false; announced.removeAll()
        sights = []; passedSights.removeAll(); passingSight = nil
        rerouteFailure = nil
        // A ride cannot inherit the previous ride's pace or distance.
        rollingSpeed = 0; lastRecorded = nil; offRouteStreak = 0
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
        checkSights(at: s.along)

        // One bad fix should never trigger a reroute; a run of them should —
        // but only once the rider has actually joined the line. At the start
        // they sit a few metres off it, and that is not a wrong turn.
        if s.lateral > 40 {
            if joinedRoute {
                offRouteStreak += 1
                if offRouteStreak >= 3 && !offRoute { markOffRoute(from: fix) }
            }
        } else {
            joinedRoute = true
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

    /// Trigger points, far to near: a heads-up, a get-ready, and the turn
    /// itself. They only decide *when* to speak — the distance spoken is the
    /// rider's actual distance to the maneuver, not the trigger.
    static let guidanceTiers: [Double] = [400, 150, 40]

    /// The tightest tier the rider is inside of, or nil while still beyond the
    /// first. The *tightest*, not the farthest un-said one — so a step that
    /// opens already inside a tier (turns close together, a GPS jump, or the
    /// very first step) is announced against the distance it is really at.
    nonisolated static func band(at distance: Double) -> Int? {
        guidanceTiers.lastIndex { distance <= $0 }
    }

    private func speakGuidance(for step: StoredStep) {
        guard let band = Self.band(at: distanceToManeuver) else { return }
        let key = "\(stepIndex)-\(band)"
        guard !announced.contains(key) else { return }
        // Retire this band and every farther one: a heads-up the rider is
        // already inside of is stale, and must not fire on a later fix.
        for i in 0...band { announced.insert("\(stepIndex)-\(i)") }
        // Nearest tier is the turn itself; the rest lead with the actual
        // distance rounded to a spoken-friendly 10 m, matching the banner.
        let metres = Int((distanceToManeuver / 10).rounded()) * 10
        let prefix = band == Self.guidanceTiers.count - 1 ? "" : "In \(metres) metres, "
        announce(prefix + step.instruction)
    }

    /// Surface a sight as the rider reaches its closest approach — once each,
    /// within a 200 m window past it so one already well behind at the start
    /// doesn't pop, and never stacking a second over one still on screen.
    private func checkSights(at along: Double) {
        guard passingSight == nil else { return }
        for sight in sights where !passedSights.contains(sight.id)
            && along >= sight.offsetAlong && along <= sight.offsetAlong + 200 {
            passedSights.insert(sight.id)
            passingSight = sight
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
            guard let plan = try? await Routing.plan(through: [Coord(fix), destination], mode: self?.mode ?? .moderate, fetchElevation: false),
                  !plan.polyline.isEmpty, let self else { return }
            self.applyReroute(plan)
        }
    }

    /// Reroute around a coordinate the rider just marked closed, from
    /// whichever start is best trusted right now — the snapped position, then
    /// the raw fix, then the route's own start if neither has arrived yet —
    /// to the existing destination. Keeps the current route on failure.
    func rerouteAround(closed coordinate: CLLocationCoordinate2D) {
        guard let destination, let start = snapped ?? location ?? polyline.first, !rerouting else { return }
        rerouteFailure = nil
        rerouting = true
        let nogo = NoGoCircle(coord: Coord(coordinate), radiusMeters: 40)
        Task { [weak self] in
            defer { self?.rerouting = false }
            guard let plan = try? await Routing.plan(through: [Coord(start), destination], mode: self?.mode ?? .moderate,
                                                      fetchElevation: false, closures: [nogo]),
                  !plan.polyline.isEmpty, let self else {
                self?.rerouteFailure = "Couldn't find a way around that closure."
                return
            }
            self.applyReroute(plan)
        }
    }

    func dismissRerouteFailure() { rerouteFailure = nil }

    /// Swap in a freshly planned route, resetting the navigation state that
    /// tracked the old line. Shared by every reroute path so they never drift
    /// on which fields get reset.
    private func applyReroute(_ plan: RoutePlan) {
        polyline = plan.polyline.coordinates
        cumulative = Geo.cumulative(polyline)
        steps = plan.steps
        plannedDuration = plan.expected
        stepIndex = 0
        searchIndex = 0
        distanceAlong = 0
        offRoute = false
        offRouteStreak = 0
        joinedRoute = false
        announced.removeAll()
        // The stored sights' offsets are along the old line; drop them
        // rather than fire them at the wrong spot on the new one.
        sights = []
        passedSights.removeAll()
        passingSight = nil
        onReroute?(plan)
        announce("Route updated. \(plan.steps.first?.instruction ?? "")")
    }

    private func announce(_ text: String) {
        guard voiceEnabled, !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speaker.speak(utterance)
    }

    #if DEBUG
    nonisolated static func selfCheck() {
        assert(band(at: 500) == nil, "beyond the first tier, say nothing")
        assert(band(at: 380) == 0, "heads-up")
        // The bug this guards: a step that opens 120 m out must say "In 150
        // metres" — matching the banner — not the farther "In 400 metres" tier.
        assert(band(at: 120) == 1, "spoke a farther tier than the rider is in")
        assert(band(at: 30) == 2, "the turn itself")
    }

    /// The bugs this guards: a reroute mid-ride kept the old route's ETA, and
    /// a reset between rides kept the old ride's rolling pace and last GPS
    /// fix — so a new ride could inherit a prior ride's pace or distance.
    static func selfCheckState() {
        let r = RideRecorder()
        r.voiceEnabled = false

        r.rollingSpeed = 8
        r.lastRecorded = CLLocation(latitude: 1.3, longitude: 103.8)
        r.offRouteStreak = 2
        r.reset()
        assert(r.rollingSpeed == 0, "reset() left a stale rolling speed for the next ride")
        assert(r.lastRecorded == nil, "reset() left a stale GPS fix for the next ride")
        assert(r.offRouteStreak == 0, "reset() left a stale off-route streak for the next ride")

        r.plannedDuration = 1000
        var plan = RoutePlan()
        plan.polyline = [Coord(lat: 1.3, lon: 103.8), Coord(lat: 1.31, lon: 103.8)]
        plan.expected = 42
        r.applyReroute(plan)
        assert(r.plannedDuration == 42, "applyReroute() did not refresh plannedDuration from the new plan")
    }
    #endif
}
