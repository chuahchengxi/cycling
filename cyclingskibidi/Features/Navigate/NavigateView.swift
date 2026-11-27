//
//  NavigateView.swift
//  cyclingskibidi
//
//  Turn-by-turn. Guidance banner across the top, the route under a
//  heading-locked camera, and a sheet that goes from a single progress line, to
//  the pause / end controls, to the full turn list. Ending the trip swaps this
//  screen for the finished screen — the conditional render on the board.
//

import SwiftUI
import SwiftData
import MapKit
import AudioToolbox
import UserNotifications
import Combine

struct NavigateView: View {
    let route: Route

    @Environment(Trip.self) private var trip
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var obstacles: [Obstacle]

    @State private var focus: MapFocus? = .user(heading: true)
    @State private var detent: PresentationDetent = .height(190)
    @State private var line: [CLLocationCoordinate2D] = []
    @State private var placing = false
    @State private var pending: PendingObstacle?
    @State private var showSheet = true
    /// A sight the rider tapped on the map: its full brief in a Kit card. (Passing one goes in the banner.)
    @State private var tappedSight: Sight?

    private var recorder: RideRecorder { trip.recorder }

    var body: some View {
        Group {
            if let ride = trip.finished {
                FinishedView(ride: ride, kitNote: recorder.kitSummary) {
                    trip.clear()
                    dismiss()
                }
            } else {
                navigating
            }
        }
        .animation(.default, value: trip.finished == nil)
    }

    // MARK: Navigating

    /// Collapsed nav-sheet detent. The side buttons clear this plus the home-
    /// indicator inset the sheet sits on, so the bottom one isn't tucked under it.
    private static let collapsedSheet: CGFloat = 190

    private var navigating: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                map
                GuidanceBanner(step: recorder.currentStep,
                               distance: recorder.distanceToManeuver,
                               offRoute: recorder.offRoute,
                               rerouting: recorder.rerouting,
                               message: bannerMessage,
                               onStop: { if let s = recorder.passingSight { recorder.kitVerdict(s, stopped: true) }; recorder.passingSight = nil },
                               onSkip: { if let s = recorder.passingSight { recorder.kitVerdict(s, stopped: false) }; recorder.passingSight = nil },
                               onDismiss: { recorder.dismissRerouteFailure() },
                               onTimeout: { recorder.passingSight = nil })
                .padding(.horizontal, 12)
            }
            .overlay(alignment: .bottomTrailing) {
                sideButtons.padding(.bottom, geo.safeAreaInsets.bottom + Self.collapsedSheet + 12)
            }
            .overlay { tappedSightCard }
            .overlay { kitAlarm }
            .overlay { fallOverlay }
            .overlay(alignment: .bottom) { if placing { placementBar } }
            .animation(.default, value: recorder.passingSight?.id)
            .animation(.default, value: tappedSight?.id)
            .animation(.default, value: placing)
            .animation(.default, value: recorder.nearHazard == nil)
            .animation(.default, value: recorder.alarm?.key)
            .animation(.default, value: recorder.walkingThrough)
            .animation(.default, value: recorder.fallPhase)
            .ignoresSafeArea(edges: .bottom)
        }
        .onAppear(perform: begin)
        // A ride keeps the screen awake, so the HELP screen is there when someone picks the phone up.
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: recorder.fallPhase) { _, phase in
            guard phase != .none else { return }
            pending = nil; placing = false   // the takeover must not sit under the obstacle form
            if case .ringing = phase { postHelpNotification() }
        }
        // The countdown's deadline lives on the recorder; the view just ticks it.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            recorder.tickFall()
        }
        // Every marked hazard warns on approach, whatever route is being ridden.
        .onChange(of: obstacles, initial: true) { recorder.hazards = obstacles.filter(\.isActive) }
        .sheet(isPresented: Binding(   // a full-screen takeover hides the nav sheet, whoever asks for it back
            get: { showSheet && recorder.alarm == nil && recorder.fallPhase == .none },
            set: { if recorder.alarm == nil && recorder.fallPhase == .none { showSheet = $0 } })) {
            navSheet
                // The 190 pt detent can't grow, so its numbers stop at AX1 and shrink rather than truncate.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .minimumScaleFactor(0.6)
                .presentationDetents([.height(190), .fraction(0.5), .large], selection: $detent)
                .presentationBackgroundInteraction(.enabled)
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
        }
        // Presented from the main nav view, never stacked on the persistent nav
        // sheet — that sheet is hidden while placing, so the two never coexist.
        .sheet(item: $pending, onDismiss: { showSheet = true }) { item in
            ObstacleReportView(coordinate: item.coordinate, onSaveClosed: { recorder.rerouteAround(closed: $0) })
                .presentationDetents([.medium])
        }
        .alert("Location is off", isPresented: .constant(recorder.authorizationDenied)) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("End trip", role: .cancel) { end() }
        } message: {
            Text("Turn-by-turn needs your location while you ride.")
        }
    }

    /// The one Kit message in the guidance banner (Figma v3 · 04, 05, 14, 16).
    private var bannerMessage: BannerMessage? {
        BannerMessage.pick(failure: recorder.rerouteFailure, blocked: recorder.rerouteBlockedReason,
                           walking: recorder.walkingThrough,
                           hazard: recorder.alarm == nil ? recorder.nearHazard : nil,   // the takeover replaces it
                           passing: recorder.passingSight)
    }

    /// A sight tapped on the map: its brief over a dim scrim; tap outside or close to dismiss.
    @ViewBuilder
    private var tappedSightCard: some View {
        if let sight = tappedSight {
            ZStack {
                Color.black.opacity(0.25).ignoresSafeArea()
                    .onTapGesture { tappedSight = nil }
                PassBySightCard(sight: sight) { tappedSight = nil }
                    .padding(.horizontal, 20)
            }
            .transition(.opacity)
        }
    }

    /// Full-screen Kit alarm: a no-bike entrance (Figma v3 · 12), a hazard, a closure or a walk stretch.
    @ViewBuilder
    private var kitAlarm: some View {
        if recorder.fallPhase == .none, let alarm = recorder.alarm {
            KitAlarmView(alarm: alarm,
                         onPrimary: { recorder.alarmPrimary() },
                         onSecondary: {
                             if case .noBikes = alarm.kind {
                                 recorder.dismissAlarm()
                                 focus = .region(MKCoordinateRegion(center: alarm.coordinate.cl, latitudinalMeters: 400, longitudinalMeters: 400))
                             } else { recorder.alarmSecondary() }
                         },
                         onNotThere: { recorder.silenceAlarm() })
                .id(alarm.key)   // a new alarm replays its haptic and tone
                .transition(.opacity)
        }
    }

    /// A confirmed fall takes over the whole screen: first the countdown, then HELP.
    @ViewBuilder
    private var fallOverlay: some View {
        switch recorder.fallPhase {
        case .asking(let deadline):
            AreYouOKView(deadline: deadline,
                         onOK: { recorder.imOK() },
                         onRingNow: { recorder.ringNow() })
                .transition(.opacity)
        case .ringing(let since):
            HelpAlarmView(since: since, place: helpSpot.place, kmAlong: recorder.distance / 1000,
                          coordinate: helpSpot.coordinate, onStop: { recorder.stopHelp() })
                .transition(.opacity)
        case .none:
            EmptyView()
        }
    }

    /// The place named on the HELP screen: the closest sight within 300 m, or a generic
    /// connector. The coordinates are always the rider's own raw fix: that's where help goes.
    private var helpSpot: (place: String, coordinate: CLLocationCoordinate2D?) {
        guard let rider = recorder.location ?? recorder.snapped else { return ("Park connector", nil) }
        let nearest = recorder.sights
            .map { ($0, Geo.distance(rider, $0.coordinate)) }
            .filter { $0.1 <= 300 }
            .min { $0.1 < $1.1 }?.0
        return (nearest?.name ?? "Park connector", rider)
    }

    private var map: some View {
        // Only taps while placing do anything; pan/zoom are untouched.
        OfflineMap(lines: [MapLine(coords: line, color: .systemBlue, width: 7)],
                   pins: mapPins, focus: focus, showsUser: true,
                   onTap: { coord in if placing { place(at: coord) } })
    }

    private var mapPins: [MapPin] {
        var pins: [MapPin] = []
        if let step = recorder.currentStep {
            pins.append(MapPin(id: "step", coordinate: step.coordinate, title: step.instruction,
                               look: .marker(symbol: step.maneuver.symbol, tint: .systemPurple)))
        }
        if let end = line.last {
            pins.append(MapPin(id: "finish", coordinate: end, title: "Finish", look: .marker(symbol: "flag.checkered", tint: .systemRed)))
        }
        pins += obstacles.filter(\.isActive).map { o in
            MapPin(id: o.pinID, coordinate: o.coordinate, title: o.kind.rawValue, look: .view(AnyView(ObstacleBadge(kind: o.kind))))
        }
        if let pending {
            pins.append(MapPin(id: "pending", coordinate: pending.coordinate, title: "New obstacle",
                               look: .marker(symbol: "exclamationmark.triangle.fill", tint: .systemOrange)))
        }
        pins += recorder.sights.map { sight in
            MapPin(id: sight.id.uuidString, coordinate: sight.coordinate, title: sight.name,
                   look: .view(AnyView(SightBadge(sight: sight))), onTap: { tappedSight = sight })
        }
        return pins
    }

    /// Map controls (Kit, Figma 217:340): square icon buttons; hazards are caution gold.
    private var sideButtons: some View {
        VStack(spacing: 10) {
            KitIconButton(icon: "kit-icon-hazard", label: "Mark obstacle", caution: true, size: 52) {
                placing = true
                showSheet = false
            }
            KitIconButton(icon: "kit-icon-sound", label: recorder.voiceEnabled ? "Mute guidance" : "Unmute guidance", size: 52) {
                recorder.voiceEnabled.toggle()
            }
            .overlay { if !recorder.voiceEnabled { Rectangle().fill(KitColor.ink).frame(width: 3, height: 34).rotationEffect(.degrees(45)).allowsHitTesting(false) } }
            KitIconButton(icon: "kit-icon-locate", label: "Recenter map", size: 52) {
                focus = .user(heading: true)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.trailing, 12)
    }

    /// Compact placement prompt shown while the rider is choosing a hazard spot.
    private var placementBar: some View {
        HStack(spacing: 12) {
            Image("kit-icon-hazard").renderingMode(.template).resizable().frame(width: 22, height: 22).accessibilityHidden(true)
            Text("Tap the blue route to place the obstacle")
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 8)
            Button { placing = false; pending = nil; showSheet = true } label: {
                Text("Cancel").font(.subheadline.bold()).frame(minHeight: 52)
            }
        }
        .foregroundStyle(KitColor.ink)
        .kitCard(shadow: true, padding: 12)
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }

    // MARK: Sheet

    private var navSheet: some View {
        VStack(spacing: 0) {
            // Next turn, then km to go, then the (smaller) timer.
            if let step = recorder.currentStep {
                HStack(spacing: 10) {
                    Image(systemName: step.maneuver.symbol).font(.headline).accessibilityHidden(true)
                    Text("\(Fmt.km(recorder.distanceToManeuver)) · \(step.instruction)")
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Next turn: \(step.instruction), in \(Fmt.km(recorder.distanceToManeuver))")
            }
            KitTimer(elapsed: recorder.movingSeconds, toGo: Fmt.km(recorder.remainingDistance),
                     left: Fmt.clock(recorder.remainingSeconds), arrival: Fmt.eta(recorder.remainingSeconds),
                     progress: recorder.progress)
                .padding(.horizontal, 16)
                .padding(.top, recorder.currentStep == nil ? 18 : 8)

            if detent != .height(190) {
                controls.padding(.top, 18)
            }
            if detent == .large {
                Divider().padding(.top, 12)
                turnList
            }
            Spacer(minLength: 0)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 24) {
                KitStat(value: Fmt.km(recorder.distance), caption: "ridden", style: .title3).frame(maxWidth: .infinity)
                KitStat(value: Fmt.speed(recorder.speed), caption: "speed", style: .title3).frame(maxWidth: .infinity)
            }

            HStack(spacing: 12) {
                KitButton(title: recorder.phase == .running ? "Pause" : "Resume",
                          icon: recorder.phase == .running ? "kit-icon-pause" : "kit-icon-play",
                          style: recorder.phase == .running ? .secondary : .primary) {
                    recorder.phase == .running ? recorder.pause() : recorder.resume()
                }
                // A hold, so a bump or a wet glove can't end the ride.
                HoldButton(title: "Hold to end ride", icon: "kit-icon-stop", style: .destructive, seconds: 1.5, action: end)
            }
            #if DEBUG
            KitButton(title: "Simulate fall", icon: "kit-icon-hazard", style: .tertiary) { recorder.fallDetected() }
            #endif
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var turnList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(recorder.upcomingSteps) { step in
                    StepRow(step: step,
                            distanceLabel: Fmt.km(max(0, step.maneuverOffset - recorder.distanceAlong)))
                }
            }
            .padding(20)
        }
    }

    // MARK: Actions

    private func begin() {
        line = route.polyline.coordinates
        recorder.onReroute = { plan in line = plan.polyline.coordinates }
        recorder.voiceEnabled = AppSettings.flag(AppSettings.voice)
        recorder.onAlarmWarn = { _ in   // first warning: a tap on the wrist and a short tone, no takeover yet
            guard AppSettings.flag(AppSettings.warnBeep) else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            AudioServicesPlayAlertSound(SystemSoundID(1005))
        }
        recorder.start()
        UIApplication.shared.isIdleTimerDisabled = true
        var askNotifications = (RiderProfile.decode(UserDefaults.standard.string(forKey: RiderProfile.storageKey) ?? "") ?? RiderProfile()).fallSensitivity != .off
        #if DEBUG
        if Demo.screen != nil { askNotifications = false }   // a permission alert would cover the screenshots
        #endif
        if askNotifications {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// The lock screen shows where the rider is, for whoever finds a locked phone.
    private func postHelpNotification() {
        let content = UNMutableNotificationContent()
        content.title = "HELP · 救命 · TOLONG · உதவி"
        let coords = helpSpot.coordinate.map { String(format: "%.5f, %.5f", $0.latitude, $0.longitude) } ?? "location unavailable"
        content.body = "A cyclist may have fallen near \(helpSpot.place) (\(coords)). Call 995. Don't move them."
        content.sound = .default
        content.interruptionLevel = .active
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "help", content: content, trigger: nil))
    }

    /// Snap the tapped point onto the displayed route and stage it for the form.
    /// No GPS or route-start fallback: a tap that can't snap places nothing.
    private func place(at coord: CLLocationCoordinate2D) {
        guard let snapped = Geo.snap(coord, to: line, cumulative: Geo.cumulative(line))?.coordinate
        else { return }
        placing = false
        pending = PendingObstacle(coordinate: snapped)
    }

    private func end() {
        let ride = recorder.finish()
        context.insert(ride)
        try? context.save()
        trip.finished = ride
    }
}

// MARK: - Sight card

/// A sight's brief, from a tap on its map pin, as a Kit card over the map.
struct PassBySightCard: View {
    let sight: Sight
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                KitAvatar(mood: .happy, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sight.name).font(.title3.bold())
                    if let note = sight.note { Text(note).font(.subheadline).foregroundStyle(KitColor.muted) }
                }
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image("kit-icon-close").renderingMode(.template).resizable().frame(width: 20, height: 20)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Close")
            }
            SightDetail(sight: sight)
        }
        .foregroundStyle(KitColor.ink)
        .kitCard(shadow: true, padding: 16)
    }
}

// MARK: - Banner

/// The Kit message that slides into the guidance banner. One at a time, most urgent first.
nonisolated struct BannerMessage: Equatable {
    enum Kind: Equatable { case failure, blocked, walking, hazard, passing }
    let kind: Kind
    let label: String
    let text: String
    /// Replaces the distance row ("Rerouting", "Walk your bike").
    var headline: String? = nil
    /// Replaces the instruction line.
    var subtitle: String? = nil
    var mood: KitAvatar.Mood { kind == .passing ? .happy : .alarmed }
    /// Pass-bys hide on their own after this long (the pixel bar shows time left); warnings stay.
    static let passingSeconds = 8.0

    static func pick(failure: String?, blocked: String?, walking: String?, hazard: HazardAlert?, passing: Sight?) -> BannerMessage? {
        if let failure { return .init(kind: .failure, label: "Kit · no way round", text: failure) }
        if let blocked {
            return .init(kind: .blocked, label: "Kit · keeping you off the expressway",
                         text: "New routes only use roads and paths where bikes are allowed.",
                         headline: "Rerouting", subtitle: blocked)
        }
        if let walking {
            return .init(kind: .walking, label: "Kit · on foot",
                         text: "No cycling here. Your moving time is paused; I'll buzz when you can ride again.",
                         headline: "Walk your bike", subtitle: walking)
        }
        if let hazard {
            let note = hazard.note.isEmpty ? "Slow down and go carefully." : hazard.note
            return .init(kind: .hazard, label: "Kit · \(hazard.kind.rawValue) in \(Fmt.km(hazard.distance))", text: note)
        }
        if let passing {
            return .init(kind: .passing, label: "Kit · coming up",
                         text: [passing.name, passing.note].compactMap { $0 }.joined(separator: ". "))
        }
        return nil
    }

    static func selfCheck() {
        let hazard = HazardAlert(kind: .pothole, distance: 120, note: "")
        let sight = Sight(name: "Red bridge", category: "bridge", lat: 1.4, lon: 103.9)
        assert(pick(failure: nil, blocked: nil, walking: nil, hazard: nil, passing: nil) == nil, "nothing to say, no box")
        assert(pick(failure: "x", blocked: "y", walking: "z", hazard: hazard, passing: sight)?.kind == .failure, "a failed reroute wins")
        assert(pick(failure: nil, blocked: "y", walking: "z", hazard: hazard, passing: sight)?.kind == .blocked, "then the blocked reroute")
        assert(pick(failure: nil, blocked: nil, walking: "Henderson Waves", hazard: hazard, passing: sight)?.headline == "Walk your bike")
        assert(pick(failure: nil, blocked: nil, walking: nil, hazard: hazard, passing: sight)?.kind == .hazard, "a hazard beats a pass-by")
        assert(pick(failure: nil, blocked: nil, walking: nil, hazard: hazard, passing: nil)?.text == "Slow down and go carefully.")
        let p = pick(failure: nil, blocked: nil, walking: nil, hazard: nil, passing: sight)
        assert(p?.kind == .passing && p?.mood == .happy && p?.text == "Red bridge", "pass-by: happy Kit, the place's name")
    }
}

/// Kit/guidance banner (Figma 229:2405): native material with the turn, the instruction
/// and, when Kit has something to say, Kit's message in the same card.
struct GuidanceBanner: View {
    let step: StoredStep?
    let distance: Double
    let offRoute: Bool
    let rerouting: Bool
    var message: BannerMessage? = nil
    var onStop: () -> Void = {}
    var onSkip: () -> Void = {}
    var onDismiss: () -> Void = {}
    var onTimeout: () -> Void = {}

    private var headline: String {
        if let h = message?.headline { return h }
        if rerouting { return "Recalculating…" }
        if offRoute { return "Off route" }
        return Fmt.km(distance)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                turnIcon.accessibilityHidden(true)
                Text(headline).font(.system(.largeTitle, weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.5)
                Spacer(minLength: 0)
            }
            .foregroundStyle((rerouting || offRoute) && message?.headline == nil ? Color.orange : Color.primary)
            Text(message?.subtitle ?? step?.instruction ?? "Follow the route")
                .font(.body.weight(.medium))
            if let message {
                KitBubble(label: message.label, text: message.text, mood: message.mood) {
                    switch message.kind {
                    case .passing:
                        HStack(spacing: 8) {
                            KitButton(title: "Stop here", icon: "kit-icon-flag", style: .primary, action: onStop)
                            KitButton(title: "Skip", icon: "kit-icon-close", style: .secondary, action: onSkip)
                        }
                    case .failure:
                        KitButton(title: "OK", icon: "kit-icon-check", style: .tertiary, action: onDismiss)
                    default: EmptyView()
                    }
                }
                if message.kind == .passing {
                    PassByCountdown(onTimeout: onTimeout).id(message.text)   // a new place restarts the clock
                }
            }
        }
        .accessibilityElement(children: .contain)
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 28))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
    }

    /// The pixel turn arrow for right and left turns (mirrored); SF Symbols for the rest.
    @ViewBuilder private var turnIcon: some View {
        let m = step?.maneuver
        if message?.kind == .walking || message?.kind == .blocked || rerouting || offRoute {
            Image("kit-icon-turn-right").renderingMode(.template).resizable().frame(width: 32, height: 32)
                .scaleEffect(x: message?.kind == .walking ? 1 : -1)
        } else if m == .right || m == .slightRight || m == .sharpRight {
            Image("kit-icon-turn-right").renderingMode(.template).resizable().frame(width: 32, height: 32)
        } else if m == .left || m == .slightLeft || m == .sharpLeft {
            Image("kit-icon-turn-right").renderingMode(.template).resizable().frame(width: 32, height: 32).scaleEffect(x: -1)
        } else {
            Image(systemName: m?.symbol ?? "arrow.up").font(.system(size: 28, weight: .semibold)).frame(width: 32, height: 32)
        }
    }
}

/// The gold pixel bar under a pass-by: drains over `BannerMessage.passingSeconds`, then hides it.
private struct PassByCountdown: View {
    let onTimeout: () -> Void
    @State private var shownAt = Date.now

    var body: some View {
        TimelineView(.periodic(from: shownAt, by: 0.25)) { context in
            KitSegmentBar(progress: 1 - context.date.timeIntervalSince(shownAt) / BannerMessage.passingSeconds,
                          segments: 24, on: KitColor.gold, off: .gray.opacity(0.3), height: 4)
        }
        .accessibilityHidden(true)
        .task {
            try? await Task.sleep(for: .seconds(BannerMessage.passingSeconds))
            onTimeout()
        }
    }
}

/// Kit/timer (Figma 214:59): ride time, the three numbers and pixel progress, in a Kit card.
struct KitTimer: View {
    let elapsed: Double
    let toGo: String
    let left: String
    let arrival: String
    let progress: Double

    var body: some View {
        VStack(spacing: 10) {
            Text(Fmt.clock(elapsed)).font(.kitNumber(.title)).monospacedDigit()
                .accessibilityLabel("Riding for \(Fmt.clock(elapsed))")
            HStack(spacing: 0) {
                KitStat(value: toGo, caption: "to go").frame(maxWidth: .infinity)
                KitStat(value: left, caption: "left").frame(maxWidth: .infinity)
                KitStat(value: arrival, caption: "arrival").frame(maxWidth: .infinity)
            }
            KitSegmentBar(progress: progress, segments: 24)
        }
        .foregroundStyle(KitColor.ink)
        .kitCard(padding: 14)
    }
}

// MARK: - Bits

// MARK: - Marking an obstacle

/// The snapped spot awaiting the type/note form. Identifiable so it drives the
/// form via `.sheet(item:)` and also the orange preview marker on the map.
private struct PendingObstacle: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
}

/// Mark an obstacle and keep it on this device: it warns on every later ride,
/// and a "Path closed" mark is avoided by every route from now on.
struct ObstacleReportView: View {
    let coordinate: CLLocationCoordinate2D?
    /// Fired after persisting a `.closed` obstacle, so the live ride can
    /// reroute around it. Other kinds only save.
    var onSaveClosed: (CLLocationCoordinate2D) -> Void = { _ in }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var kind: ObstacleKind = .pothole
    @State private var note = ""
    @State private var keep: Keep = .week

    /// How long the mark lasts: through the last day, or until the rider removes it.
    enum Keep: Int, CaseIterable, Identifiable {
        case today = 0, threeDays = 2, week = 7, month = 30, untilRemoved = -1
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .today: return "Today"
            case .threeDays: return "3 days"
            case .week: return "1 week"
            case .month: return "1 month"
            case .untilRemoved: return "Until I remove it"
            }
        }
        var lastDay: Date? {
            self == .untilRemoved ? nil : Closures.sg.date(byAdding: .day, value: rawValue, to: Closures.now)
        }
    }

    private var columns: [GridItem] {
        [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 12) {
                    Text("What's on the path?")
                        .font(.title2.bold())
                    Spacer(minLength: 8)
                    Button { dismiss() } label: {
                        Image("kit-icon-close").renderingMode(.template).resizable()
                            .frame(width: 20, height: 20)
                            .frame(width: 44, height: 44)
                            .background(KitColor.paper)
                            .overlay(Rectangle().strokeBorder(KitColor.ink, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(ObstacleKind.allCases) { k in kindButton(k) }
                }

                TextField("Note (optional): e.g. deep, on the left", text: $note, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .padding(12)
                    .frame(minHeight: 52, alignment: .top)
                    .background(KitColor.paper)
                    .overlay(Rectangle().strokeBorder(KitColor.ink, lineWidth: 2))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Keep it").font(.headline)
                    Picker("Keep it", selection: $keep) {
                        ForEach(Keep.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 52)
                    .background(KitColor.paper)
                    .overlay(Rectangle().strokeBorder(KitColor.ink, lineWidth: 2))
                    Text("Remove it sooner from Your marks once it's cleared.")
                        .font(.footnote).foregroundStyle(KitColor.muted)
                }

                KitButton(title: "Mark it here", icon: "kit-icon-check", style: .primary, action: save)
                    .disabled(coordinate == nil)
                Text("Saved on this phone. It shows on this route's map and brief, so you see it coming next time.")
                    .font(.footnote).foregroundStyle(KitColor.muted)
            }
            .padding(20)
        }
        .kitScreen()
    }

    private func kindButton(_ k: ObstacleKind) -> some View {
        let selected = kind == k
        // A closed path is the one kind that reroutes the live ride (onSaveClosed).
        let icon = k == .closed ? "kit-icon-close" : "kit-icon-hazard"
        return Button { kind = k } label: {
            VStack(spacing: 4) {
                Image(icon).renderingMode(.template).resizable()
                    .frame(width: 16, height: 16)
                Text(k.rawValue).font(.subheadline.weight(.medium)).multilineTextAlignment(.center)
                if k == .closed {
                    Text("Reroutes you").font(.caption2).foregroundStyle(KitColor.muted)
                }
            }
            .foregroundStyle(KitColor.ink)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(8)
            .background(selected ? KitColor.gold : KitColor.paper)
            .overlay(Rectangle().strokeBorder(KitColor.ink, lineWidth: 2))
            // Gold is a light fill: keep its ink dark in both themes.
            .environment(\.colorScheme, selected ? .light : colorScheme)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func save() {
        guard let coordinate else { return dismiss() }
        let mark = Obstacle(kind: kind, at: coordinate, note: note)
        mark.expiresAt = keep.lastDay
        context.insert(mark)
        try? context.save()
        if kind == .closed { onSaveClosed(coordinate) }
        dismiss()
    }
}
