# Kit Alarms and Fall Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Kit takes over the screen when the rider closes on a marked hazard, a closure the route still touches, or a walk-your-bike stretch; and the app detects a fall while recording, asks "Are you OK?", and rings a loud HELP alarm (even on silent) with Call 995.

**Architecture:**
- One `KitAlarm` value and one full-screen `KitAlarmView` serve every obstacle / no-access alarm. The expressway alarm from plan 2b becomes one of its kinds, so all alarms share the layout, the "Not there" silencing and the once-per-approach rule.
- `RideRecorder` decides when an alarm is due: first a sound and haptic at the warning distance, then the takeover inside the last ~100 m (scaled by speed).
- A pure `FallDetector` state machine eats motion samples (`CMDeviceMotion` at 50 Hz in the app, synthetic arrays in tests) and reports `.impact` → `.still` → `.fallen`. `FallMonitor` wraps Core Motion and runs only while recording.
- `HelpAlarm` plays a looping tone through an `AVAudioSession` in `.playback`, which ignores the silent switch; the `audio` background mode keeps it ringing with the screen locked.

**Tech Stack:** Swift / SwiftUI, Core Motion, AVFoundation, iOS 18+, assert-based `selfCheck()`s at launch in DEBUG.

**Spec:** `docs/superpowers/specs/2026-11-20-kit-personalised-places-design.md`, sections 6 and 7 ("Alarms and safety UI").

## Global Constraints

- Alarms: within ~100 m (scaled by speed) of an active hazard, a closure the route still touches, or a `no_cycling` stretch. First warning is a sound and haptic; the full-screen takeover only within the last ~100 m. Each alarm fires once per approach. Dismissing returns to navigation.
- Every obstacle / no-access alarm has a "Not there" button: silences that spot for this ride and records a false alarm; it auto-dismisses once the spot is passed.
- Alarm screens put distance and what it is first, Kit smaller. Two Kit buttons (e.g. "Take the detour" / "I see it, carry on"; "I'll walk my bike" / "Find a way round"). Obstacle alarms ochre, no-access terracotta, both with a light-mode version.
- Fall detection only while a ride is recorded; Core Motion ~50 Hz; impact > ~3–4 g with a fast tumble, then ~10 s of near-stillness. Thresholds are calibration constants (`// ponytail:`), not a model. Sensitivity Low / Normal / High (default Normal), and it can be turned off.
- "Are you OK?" with a 30 s countdown, haptics and a rising tone; "I'm OK" cancels; "Ring the alarm now" skips ahead. The countdown is announced to VoiceOver every 5 s.
- HELP screen: Call 995 is the main button with a phone icon (a tap, `tel://995`); stopping the alarm needs a 3 s hold with a visible fill; bystander line "Call 995. Don't move them."; "Help" in English, 中文, Melayu and தமிழ்; place, km, coordinates and time; its own red/ink flash, different from no-access.
- Loud on silent: `AVAudioSession` category `.playback`, full app volume; add `audio` to `UIBackgroundModes` beside `location`. Critical Alerts: not depended on.
- No automatic message or call (iOS needs a tap). All touch targets ≥ 52 pt. WCAG AA contrast.

## Review Focus

1. **Phone dropped on a table, not a fall:** an impact with no stillness after (rider picks it up) never triggers. (Task 3 test.)
2. **Bumpy kerb at speed:** a 3.5 g spike with no tumble is not a fall at Normal. (Task 3 test.)
3. **Ride paused or finished during the countdown:** the countdown and any alarm stop with the ride. (Task 4 test.)
4. **Two hazards 30 m apart:** one takeover at a time; the second shows after the first is dismissed or passed. (Task 1 test.)
5. **"Not there" on a hazard then a reroute:** still silent for the rest of the ride. (Task 1 test.)

---

### Task 1: One alarm model for obstacles, closures and walk stretches

**Files:**
- Create: `cyclingskibidi/Features/Navigate/KitAlarm.swift` (model + `KitAlarmView`)
- Modify: `cyclingskibidi/Features/Navigate/RideRecorder.swift` (`checkAlarms(at:speed:)`; the plan-2b `noBikeAhead` becomes `alarm` of kind `.noBikes`)
- Modify: `cyclingskibidi/Features/Navigate/NoBikeAlarm.swift` (delete; its view becomes `KitAlarmView`), `NavigateView.swift`
- Modify: `cyclingskibidi/Models/Models.swift` (`Obstacle.falseAlarms: Int = 0`)

**Interfaces:**
- Produces:
  - `nonisolated struct KitAlarm: Equatable, Sendable { enum Kind { case hazard(ObstacleKind), closure, walk, noBikes(expressway: Bool) }; let key: String; let kind: Kind; let title: String; let detail: String; var distance: Double; var tone: Tone }` with `enum Tone { case obstacle, noAccess }` (hazard → obstacle/ochre; closure, walk, noBikes → noAccess/terracotta; walk uses gold accents).
  - `RideRecorder.alarm: KitAlarm?`, `silencedAlarms: Set<String>`, `func silenceAlarm()` ("Not there": silences + increments `Obstacle.falseAlarms` for hazards), `func dismissAlarm()`.
  - `static func takeoverDistance(speed: Double) -> Double` = `max(100, speed * 12)` (12 s of warning); `static let warnDistance = 250.0` for the first sound + haptic.
  - Buttons per kind: hazard "Take the detour" (reroute around it, existing `rerouteAround`) / "I see it, carry on"; closure "Take the detour" / "I see it, carry on"; walk "I'll walk my bike" / "Find a way round"; noBikes keeps plan 2b's three. Every kind also has "Not there".
  - `KitAlarmView(alarm:onPrimary:onSecondary:onNotThere:)`: distance first ("STOP IN 80 m" / "80 m"), title, detail, Kit avatar small, ochre or terracotta background with ink text, light and dark versions.

- [ ] **Step 1: Write the failing tests** in `RideRecorder.selfCheckAlarms()`:
  - Hazard on route, closing at 5 m/s: at 240 m `alarm == nil` but `warnedAlarms` contains it (sound + haptic once); at 90 m `alarm` is set with distance ≈ 90; at 20 m past and moving away it auto-dismisses.
  - At 10 m/s `takeoverDistance` is 120: alarm at 115 m.
  - Two hazards 30 m apart: only the nearer is `alarm`; after `dismissAlarm()` the other shows on the next fix.
  - `silenceAlarm()` on a hazard: no alarm for it again this ride, after a reroute too; its `falseAlarms` went up by one; `reset()` clears the silence.
  - A closure circle the route touches and a walk circle both alarm with kinds `.closure` / `.walk`; an expired closure doesn't.
  - Plan 2b's no-bike tests still pass against `alarm` with kind `.noBikes`.
- [ ] **Step 2: Run** `zsh .superpowers/sdd/fix/run.sh`. **Expected:** BUILD FAILED.
- [ ] **Step 3: Implement.** The hazard banner stays for the warning stage; the takeover replaces it inside `takeoverDistance`.
- [ ] **Step 4: Run** it. **Expected:** LAUNCH CLEAN.
- [ ] **Step 5: Commit** `feat(kit): full-screen Kit alarms for hazards, closures and walk stretches`.

### Task 2: Loud-on-silent alarm sound

**Files:**
- Create: `cyclingskibidi/Features/Navigate/AlarmSound.swift`
- Modify: `cyclingskibidi.xcodeproj/project.pbxproj` (`INFOPLIST_KEY_UIBackgroundModes = "audio location";` in both configurations)

**Interfaces:**
- Produces: `@MainActor final class AlarmSound { static let shared; func start(_ style: Style); func stop(); var isPlaying: Bool }`, `enum Style { case rising, help }`.
  - Tone synthesised in memory with `AVAudioEngine` + `AVAudioSourceNode` (no bundled sound file): `rising` sweeps 600→1200 Hz over 2 s and repeats; `help` alternates 960/1280 Hz every 0.25 s.
  - `start` sets `AVAudioSession.sharedInstance().setCategory(.playback, options: [])`, activates it, and runs the engine at full volume; `stop` stops it and deactivates with `.notifyOthersOnDeactivation`.
  - `static func samples(_ style: Style, at t: Double) -> Float` (nonisolated, pure) — the waveform, for the test.

- [ ] **Step 1: Write the failing test** `AlarmSound.selfCheck()`: `samples(.help, at:)` stays within −1…1 for 1 s at 44.1 kHz; its frequency changes at t = 0.25 s (count zero crossings in 0–0.25 vs 0.25–0.5: ratio ≈ 1280/960); `samples(.rising, at: 0)` frequency < at 1.9 s.
- [ ] **Step 2: Run** the launch check. **Expected:** BUILD FAILED.
- [ ] **Step 3: Implement**, and the plist key.
- [ ] **Step 4: Run** it. **Expected:** LAUNCH CLEAN. On a device with the silent switch on, `AlarmSound.shared.start(.help)` from a DEBUG button is audible (note result in the ledger; simulator can't test the switch).
- [ ] **Step 5: Commit** `feat(safety): alarm tone that rings on silent`.

### Task 3: Fall detector (pure)

**Files:**
- Create: `cyclingskibidi/Features/Navigate/FallDetector.swift`
- Modify: `cyclingskibidi/App/cyclingskibidiApp.swift` (`FallDetector.selfCheck()`)

**Interfaces:**
- Produces:
  - `nonisolated enum FallSensitivity: String, Codable, CaseIterable { case off, low, normal, high }` with `impactG` (low 4.0, normal 3.5, high 3.0), `tumbleRadPerSec` (low 6, normal 5, high 4); `.off` never detects. `// ponytail:` calibration constants, tune on real rides.
  - `nonisolated struct MotionSample { let t: Double; let accelG: Double /* |userAcceleration| in g */; let rotation: Double /* |rotationRate| rad/s */ }`
  - `nonisolated struct FallDetector { var sensitivity: FallSensitivity; mutating func feed(_ s: MotionSample) -> Bool }` — true once, when a fall is confirmed.
  - Rule: an impact (`accelG > impactG`) with a tumble (`rotation > tumbleRadPerSec`) within ±0.5 s of it, followed by `stillFor = 10` s where every sample has `accelG < 0.15` and `rotation < 0.5`, starting within 3 s of the impact. Any motion breaking the stillness cancels the candidate. After a confirmed fall, nothing more until `reset()`.

- [ ] **Step 1: Write the failing tests** `FallDetector.selfCheck()` (50 Hz synthetic streams):
  - Riding noise (0.3 g, 1 rad/s) for 60 s: never.
  - Impact 5 g + tumble 7 rad/s, then 10.5 s still: true, exactly once.
  - Same impact, then picked up after 4 s (0.6 g): never (dropped phone).
  - 3.5 g kerb spike with rotation 1 rad/s, then still: never at Normal.
  - 3.2 g + tumble then still: true at High, never at Normal or Low; never at `.off` for any stream.
- [ ] **Step 2: Run** the launch check. **Expected:** BUILD FAILED.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** it. **Expected:** LAUNCH CLEAN.
- [ ] **Step 5: Commit** `feat(safety): fall detector from motion samples`.

### Task 4: Are you OK? and the HELP screen

**Files:**
- Create: `cyclingskibidi/Features/Navigate/FallMonitor.swift` (Core Motion wrapper)
- Create: `cyclingskibidi/Features/Navigate/HelpViews.swift` (`AreYouOKView`, `HelpAlarmView`)
- Modify: `cyclingskibidi/Features/Navigate/RideRecorder.swift` (start/stop the monitor with the ride; `fallPhase`)
- Modify: `cyclingskibidi/Features/Navigate/NavigateView.swift` (present them)
- Modify: `cyclingskibidi/Features/Kit/RiderProfile.swift` (`fallSensitivity: FallSensitivity = .normal`, decoded with a default for old profiles) and `InterestsSheet.swift` (a Low/Normal/High/Off picker)
- Modify: `project.pbxproj` (`INFOPLIST_KEY_NSMotionUsageDescription = "Notices if you fall while you ride, so the app can ring an alarm for help."`)

**Interfaces:**
- Consumes: `FallDetector` (Task 3), `AlarmSound` (Task 2).
- Produces:
  - `RideRecorder.fallPhase: FallPhase` with `enum FallPhase: Equatable { case none, asking(deadline: Date), ringing(since: Date) }`; `func fallDetected()`, `func imOK()`, `func ringNow()`, `func stopHelp()`; `static let askSeconds = 30.0`.
  - `FallMonitor` starts `CMMotionManager.startDeviceMotionUpdates` at 50 Hz on its own `OperationQueue` when the ride starts running and stops on pause / finish / reset; feeds the detector off main; hops to main to call `fallDetected()`. Not started when sensitivity is `.off` or `deviceMotionAvailable` is false.
  - `AreYouOKView`: "Are you OK?", a 30 s countdown (Jersey-style numerals), "I'm OK" (primary) and "Ring the alarm now"; haptic each second; `AlarmSound.start(.rising)`; VoiceOver announcement "Ringing for help in N seconds" every 5 s.
  - `HelpAlarmView`: full-screen red/ink flash at 2 Hz (`accessibilityReduceMotion` → steady red), "HELP · 救命 · TOLONG · உதவி", bystander line "Call 995. Don't move them.", place (nearest sight or "Park connector"), km along the route, coordinates to 5 dp, the time; the main button "Call 995" with `phone.fill` opens `tel://995`; "Hold to stop alarm" needs a 3 s press with a visible fill. `AlarmSound.start(.help)`.

- [ ] **Step 1: Write the failing tests** in `RideRecorder.selfCheckFall()`:
  - `fallDetected()` while running → `.asking` with deadline 30 s out; `imOK()` → `.none`.
  - `fallDetected()` then time past the deadline (inject a clock: `var now: () -> Date`) → `tickFall()` makes it `.ringing`.
  - `ringNow()` skips straight to `.ringing`; `stopHelp()` → `.none`.
  - `pause()` or `finish()` during `.asking` → `.none` and the sound stopped (`AlarmSound.shared.isPlaying == false`; guard the sound calls behind a `var sound: AlarmSoundPlaying` protocol-free closure pair `startSound/stopSound` so the test doesn't play audio).
  - `fallDetected()` while paused does nothing.
  - `RiderProfile` decoded from JSON without `fallSensitivity` → `.normal`.
- [ ] **Step 2: Run** the launch check. **Expected:** BUILD FAILED.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** it. **Expected:** LAUNCH CLEAN. In the simulator, a DEBUG-only "Simulate fall" action shows Are you OK?, the countdown reaches 0, and the HELP screen flashes; the hold-to-stop fill takes 3 s.
- [ ] **Step 5: Commit** `feat(safety): are you OK countdown and the HELP alarm`. Update the spec status line to add "section 6 (plan 6)", commit `docs(kit): plan 6 built`.

## Decisions this plan makes

- **Takeover distance = max(100 m, 12 s at current speed).** "~100 m scaled by speed" with a floor.
- **The plan-2b expressway alarm joins the shared model** so every alarm has one look and one silencing rule.
- **Tone is synthesised**, so no audio asset or licence; `.playback` is what ignores the silent switch.
- **Stillness must start within 3 s of the impact and last 10 s** — a dropped phone gets picked up, a fallen rider doesn't move.
- **No automatic call or message**: iOS requires a tap (spec non-goal).
