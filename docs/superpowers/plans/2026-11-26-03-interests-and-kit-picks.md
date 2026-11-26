# Interests and Kit's Picks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Riders say what they like, how they're riding today and how fit they are. Kit then picks the places along a Leisure or Moderate route for them, explains each one in a line drawn from our own data, and learns from what they stop at.

**Architecture:** The corridor sweep from plan 2 (`Discovery.sights`) gives every eligible place. A new `Kit` enum scores them against a `RiderProfile` and returns quick picks (approach A) at once. On iOS 26+ with Apple Intelligence, `KitModel` sends the top 40 as compact lines to Foundation Models. The model returns IDs and notes; we validate them and they replace the quick picks when ready. The profile, including learned weights, lives in one `AppStorage` JSON value. "How I'm riding today" adds avoid-circles to routing.

**Tech Stack:** Swift / SwiftUI / SwiftData, iOS 18+, `FoundationModels` (iOS 26+, behind `#available`), assert-based `selfCheck()`s run at launch in DEBUG.

**Spec:** `docs/superpowers/specs/2026-11-20-kit-personalised-places-design.md`, section 2, plus "When things are decided" and the Anti-goals.

## Global Constraints

- iOS 18 and later. Foundation Models only via `if #available(iOS 26.0, *)` and `SystemLanguageModel.default.availability == .available`. On iOS 18–25 approach A is the whole feature, so it must be good on its own.
- Project defaults to MainActor isolation. No blocking async bridges; use fire-and-forget `Task {}`. Heavy pure work is `nonisolated` and runs in `Task.detached` (the pattern from plan 2).
- Fully offline. No network, ever.
- Anti-goal: Kit or the model naming a place, stall or fact that isn't in the bundled data. The model returns only candidate IDs; every ID is validated; notes may use only the candidate's own facts.
- Anti-goal: recommending a place that is closed, in a no-cycling zone, or not reachable. Picks come only from `Discovery.sights`, which already applies those filters.
- On-device model context is small: at most 40 compact candidates per request.
- Leisure and Moderate get Kit's picks; Fast gets none.
- Quick (approach A) picks show at once; the model's picks replace them when ready, so the rider never waits.
- Rider-facing text spells out "park connector" and "hawker centre" (never "PC" / "HC").
- "What I like": Nature & photos, Food, Architecture, Heritage, Wildlife, Art & murals, Cafés. "How I'm riding today": With kids, Visiting Singapore, Keep it quiet. Rider level: Beginner / Regular / Strong.

## Without Foundation Models (iOS 18–25, Apple Intelligence off, model not ready, error, timeout)

Approach A is the whole feature on these devices, and it has to stand on its own (Figma `v3 · 15`):

- **Same picks pipeline:** the corridor filters, the scoring against "What I like", learned weights and spread are the same on every iPhone. Only the notes differ.
- **Notes come word for word from our data** (`Kit.templateNote`): a Bib stall, "Try <dish> or <dish>", the note's first sentence, or "<category> · km n". Nothing is generated, so nothing can be made up.
- **Kit's card says "Quick picks"** and explains it in one line. No spinner, no "Apple Intelligence required" error, and no empty state. The model is an upgrade, not a requirement.
- **Detection:** `KitModel.pick` returns nil whenever `#available(iOS 26.0, *)` fails, `SystemLanguageModel.default.availability != .available`, the call throws, or 8 s pass. The caller keeps the quick picks on nil and never retries mid-ride.
- **Test:** Task 3's fallback checks (throwing, timing out, unavailable) plus Task 2's real-data check run on every simulator runtime. The launch check runs on the oldest installed runtime as well as iOS 27.

## Review Focus

1. **The model returns junk**: unknown IDs, duplicates, more picks than asked, empty notes, or a note naming a stall or number that isn't in the facts. The rider should still get exactly the target count of real places, each with a truthful note. (Task 3 tests.)
2. **No model**: iOS 18–25, Apple Intelligence off, model not ready, an error, or slower than the timeout. The quick picks stay, nothing spins forever, and no error is shown. (Task 3 tests.)
3. **A rider who skipped onboarding** (no interests): picks still spread along the route and favour notable places, not the first 5 cafés. (Task 2 test.)
4. **A stale model result**: the rider moves a pin while the model is still thinking. The old answer must never replace picks for the new line. (Task 3 test of the generation guard.)
5. **Learning runs away**: twenty Skips on cafés must not hide every café forever, and a stop at a place that wasn't a pick must not count. (Task 4 tests: weights are clamped; detection only matches picks.)

---

### Task 1: Rider profile and the interests sheet

**Files:**
- Create: `cyclingskibidi/Features/Kit/RiderProfile.swift`
- Create: `cyclingskibidi/Features/Kit/InterestsSheet.swift`
- Modify: `cyclingskibidi/App/ContentView.swift` (first-launch sheet)
- Modify: `cyclingskibidi/Features/Routes/RouteListView.swift` (toolbar button "Your interests")
- Modify: `cyclingskibidi/Features/Routes/RouteBuilderView.swift` (a "For you" button for Leisure/Moderate that opens the same sheet)
- Modify: `cyclingskibidi/App/cyclingskibidiApp.swift` (call `RiderProfile.selfCheck()`)

**Interfaces:**
- Produces:
  - `nonisolated enum Interest: String, Codable, CaseIterable, Sendable { case nature, food, architecture, heritage, wildlife, art, cafes }` with `var label: String` (exact copy above), `var symbol: String`, `var personaTags: Set<String>`, `var categories: Set<String>`.
  - `nonisolated enum RideContext: String, Codable, CaseIterable, Sendable { case kids, visiting, quiet }` with `label` ("With kids", "Visiting Singapore", "Keep it quiet").
  - `nonisolated enum RiderLevel: String, Codable, CaseIterable, Sendable { case beginner, regular, strong }` with `label`.
  - `nonisolated struct RiderProfile: Codable, Equatable, Sendable { var likes: Set<Interest> = []; var today: Set<RideContext> = []; var level: RiderLevel = .regular; var weights: [String: Double] = [:] }`, plus `static let storageKey = "riderProfile"`, `static func decode(_ raw: String) -> RiderProfile?` and `var encoded: String`.
  - `struct InterestsSheet: View`, bound to `@AppStorage(RiderProfile.storageKey) var raw: String`.

- [ ] **Step 1: Write the failing test.** `RiderProfile.selfCheck()`:
  - A profile with likes `[.food, .nature]`, today `[.kids]`, level `.strong` and weights `["hawker": 0.5]` round-trips through `encoded` / `decode`.
  - `decode("")` and `decode("garbage")` return nil.
  - `Interest.food.personaTags == ["food"]` and `Interest.food.categories == ["hawker"]`.
  - Every category any `Interest` names is in `Discovery.leisureCategories`.
  - Every overlay persona tag that is an interest (nature, food, architecture, heritage, wildlife) maps from exactly one `Interest`.
- [ ] **Step 2: Run it. Expected: build fails** (types don't exist).
- [ ] **Step 3: Implement the types.** Mappings:
  - nature: tags `nature`; categories park, nationalPark, beach, reservoir, waterway, bridge, viewpoint.
  - food: `food`; hawker.
  - architecture: `architecture`; none (hand-curated in the overlay only).
  - heritage: `heritage`; heritage, museum, worship.
  - wildlife: `wildlife`; nationalPark, zoo, aquarium.
  - art: no tags; artwork.
  - cafes: no tags; cafe.
- [ ] **Step 4: Implement `InterestsSheet`.** It is a native `NavigationStack` + `Form`:
  - "What I like" and "How I'm riding today" are toggle chips laid out with the existing `FlowLayout`.
  - Rider level is a segmented `Picker`.
  - "Done" writes `raw`. A first-launch sheet's Done also works with nothing chosen.
  - Touch targets are at least 52 pt.
  - `ContentView` presents it once, when `raw` is empty. `RouteListView` and `RouteBuilderView` (mode != .fast) open it on demand.
- [ ] **Step 5: Run the launch checks. Expected: PASS** (no "Assertion failed"; app alive after 45 s). Then open the app on a fresh simulator. Expected: the sheet appears once; Done dismisses it; relaunching does not show it again.
- [ ] **Step 6: Commit** `feat(kit): rider profile and interests sheet`.

### Task 2: Kit's quick picks (approach A) with notes from our data

**Files:**
- Create: `cyclingskibidi/Features/Kit/Kit.swift`
- Modify: `cyclingskibidi/Models/Geo.swift` (`Sight.note`)
- Modify: `cyclingskibidi/Features/Routes/Discovery.swift` (`spread` takes a score; `sights(along:)` takes `limit: Int? = 20`, where nil means no spread)
- Modify: `RouteBuilderView.swift`, `RouteDetailView.swift`, `SheetView.swift`, `NavigateView.swift` (`PassBySightCard`): sights for Leisure **and Moderate**, and show `note` under the name.

**Interfaces:**
- Consumes: `RiderProfile`, `Interest` (Task 1). `Discovery.sights(along:mode:start:in:facts:closed:walk:limit:)` and `Discovery.facts` (plan 2).
- Produces:
  - `Sight.note: String? = nil`. Old saves decode with nil.
  - `nonisolated struct KitCandidate: Sendable { let sight: Sight; let score: Double; let line: String }`. `line` is `"<osmID> | <name> | <category label> | km <n.n> | <facts>"`, where facts are the overlay's dishes, Bib/`since` stalls, best_time, note and reason codes in words, plus "Wikipedia" when `wiki` is set. "none" when there are no facts.
  - `nonisolated enum Kit`:
    - `static func score(_ s: Sight, profile: RiderProfile, facts: [String: PlaceFacts]) -> Double`
    - `static func candidates(_ sights: [Sight], profile:, facts:, max: Int = 40) -> [KitCandidate]`
    - `static func targetCount(lengthMeters: Double) -> Int` (= `max(3, Int((length / 20_000 * 5).rounded()))`)
    - `static func quickPicks(_ candidates: [KitCandidate], polyline: [CLLocationCoordinate2D], cumulative: [Double], count: Int) -> [Sight]` (spread by score, each with `note = templateNote(...)`)
    - `static func templateNote(_ s: Sight, facts: PlaceFacts?, lengthMeters: Double) -> String`
    - `static func picks(along polyline: [Coord], mode: RideMode, profile: RiderProfile, start: Date = .now) -> (quick: [Sight], candidates: [KitCandidate])`, which is called from `Task.detached`.

- [ ] **Step 1: Write the failing tests** in `Kit.selfCheck()` (registered in the app's `init`), using hand-made sights and facts on the 10 km test line from plan 2:
  - **Score:** a liked category (food → a hawker) beats an unliked one with equal notability. A persona-tag match scores above a category-only match. A note scores above Wikipedia, and Wikipedia above nothing. A learned weight of +1 on `cafe` moves a café above an equal park. Weights are read clamped to −2…+2.
  - **No interests:** with an empty profile and 30 cafés in the first km plus a museum with Wikipedia at km 9, `quickPicks(count: 3)` includes the museum and returns 3 in route order.
  - **Candidates:** 60 sights give at most 40 candidates, highest scores first. Each `line` has exactly 5 `|`-separated fields and starts with the OSM ID.
  - **Template notes:**
    - A hawker with a Bib stall gives `"Cheok Kee Duck Rice, Bib Gourmand 2026 · km 1.2"`.
    - A hawker with dishes only gives `"Try satay or BBQ chicken wings · km 1.2"` (the first two dishes).
    - A hawker with no data gives `"Hawker centre, local dishes · km 1.2"`.
    - A park with a note uses the note's first sentence: `"Resident otter family · km 3.4"`.
    - Any other place gives `"<category label> · km n.n"`.
    - A hawker in the last 20 % of the route ends `"· good after the ride"` instead of the km.
  - **Counts:** `targetCount(lengthMeters:)` gives 3 at 5 km, 5 at 20 km and 10 at 40 km.
  - **Real data:** `picks(along:)` on a Leisure line along East Coast Park with a food-loving profile returns at least one hawker centre among its picks. Fast mode returns `([], [])`.
- [ ] **Step 2: Run it. Expected: build fails.**
- [ ] **Step 3: Implement.**
  - Score = interest match (persona tag in likes 3, category in a liked interest 2) + notability (note 1.5, Wikipedia 1) + clamped weight for the category.
  - `quickPicks` reuses `Discovery.spread`, now taking `score: (Sight) -> Double` in place of the fixed notability. `sights(along:)` passes notability as before, so plan 2's tests are unchanged.
  - `picks` calls `Discovery.sights(along:..., limit: nil)` and then scores the result.
- [ ] **Step 4: Wire it in.**
  - Builder `replan()`, detail `.task`/`replan` and the save path all store `quick` as the route's sights, for `mode != .fast`.
  - Keep the existing `generation` guard in the builder.
  - Show `note` as a secondary line in the builder strip, `SheetView.sightList` and `PassBySightCard`.
- [ ] **Step 5: Run the launch checks. Expected: PASS.**
- [ ] **Step 6: Try it.** Plan a real Leisure route along East Coast Park with a temporary DEBUG print. Expected: about 5 picks over 6.5 km, spread along the route, each note true to `places_overlay.json`. Remove the print.
- [ ] **Step 7: Commit** `feat(kit): quick picks for the rider with notes from our data`.

### Task 3: Kit's model picks (Foundation Models, iOS 26+)

**Files:**
- Create: `cyclingskibidi/Features/Kit/KitModel.swift`
- Modify: `RouteBuilderView.swift`, `RouteDetailView.swift` (replace quick picks when the model answers, behind the generation guard)

**Interfaces:**
- Consumes: `KitCandidate`, `Kit.quickPicks`, `Kit.templateNote` (Task 2); `RiderProfile` (Task 1).
- Produces:
  - `nonisolated struct ModelPick: Sendable, Equatable { let id: String; let note: String }`.
  - `nonisolated enum KitModel`:
    - `static func validate(_ raw: [ModelPick], candidates: [KitCandidate], count: Int, facts: [String: PlaceFacts], lengthMeters: Double) -> [Sight]`
    - `static func noteIsGrounded(_ note: String, in candidate: KitCandidate) -> Bool`
    - `static func prompt(candidates: [KitCandidate], profile: RiderProfile, count: Int) -> String`
    - `static let instructions: String`
    - `static func pick(candidates:, profile:, count:, timeout: Duration = .seconds(8), ask: @escaping @Sendable (String) async throws -> [ModelPick] = KitModel.askSystemModel) async -> [ModelPick]?`, which returns nil when unavailable, on error or on timeout.
  - `@available(iOS 26.0, *) @Generable struct KitAnswer { @Guide(.maximumCount(12)) var picks: [KitAnswerPick] }` and `@Generable struct KitAnswerPick { var id: String; @Guide(description: "One short line, only from this place's facts") var note: String }`.
  - `static func askSystemModel(_ prompt: String) async throws -> [ModelPick]`. On iOS 26+ with `SystemLanguageModel.default.availability == .available`, it runs `LanguageModelSession(instructions: instructions).respond(to: prompt, generating: KitAnswer.self)`. Otherwise it throws.

- [ ] **Step 1: Write the failing tests** in `KitModel.selfCheck()`, using an injected `ask` (no real model):
  - **Validate:**
    - Unknown IDs are dropped.
    - Duplicate IDs are kept once.
    - More than `count` are cut to `count`.
    - Fewer than `count` are topped up from the quick picks not already chosen.
    - The result is in route order, and every returned sight is a candidate.
  - **Grounding:**
    - "Try the satay" is grounded for a candidate whose facts include satay.
    - "Try the laksa" is not.
    - "Tian Tian Chicken Rice is a Bib pick" is not grounded for a centre whose facts don't name it. Rule: every capitalised word after the first, and every number, must appear in the candidate's line, or be "Kit" or "km".
    - An empty note is not grounded.
    - An ungrounded note is replaced by `Kit.templateNote`.
  - **Fallbacks:**
    - An `ask` that throws gives nil.
    - An `ask` that sleeps 10 s with `timeout: .milliseconds(200)` gives nil within about 1 s.
    - A good `ask` returns its picks.
  - **Prompt:** contains every candidate line, the liked interests in words, and `count`. It is at most 40 lines of candidates.
  - **Generation guard:** in the builder's pick-application function (extract it as `static func apply(_ result: [Sight], forGeneration g: Int, current: Int) -> [Sight]?`), a result for an older generation returns nil.
- [ ] **Step 2: Run it. Expected: build fails.**
- [ ] **Step 3: Implement.**
  - Timeout: race `ask` against `Task.sleep(for: timeout)` in a task group; the first to finish wins, and the other is cancelled.
  - `instructions`: Kit is a friendly cycling cat. Choose places for this rider from the list only, and return their IDs exactly as given. Each note is one short line using only that place's facts; never name a stall, dish or number that isn't in the facts. Spell out "park connector" and "hawker centre".
  - Compile the `@Generable` types only under `#if canImport(FoundationModels)` and `@available(iOS 26.0, *)`.
- [ ] **Step 4: Wire it in.**
  - After the quick picks are stored, fire `Task { if let raw = await KitModel.pick(...) { ... } }`.
  - On an answer, `validate` it and apply it through the generation guard (builder) or check that `route.polyline` is unchanged (detail). Then save.
  - No spinner. The quick picks are already showing.
- [ ] **Step 5: Run the launch checks. Expected: PASS** on iOS 27 and on the oldest installed runtime.
- [ ] **Step 6: Try it** on an iOS 26+ device or simulator with Apple Intelligence. Plan the East Coast route twice: once with a food profile, once with nature. Expected: the picks differ and every note is true to the data. Record 3 sample notes in the ledger. If no Apple Intelligence device is available, write that in the ledger and say so in the final report.
- [ ] **Step 7: Commit** `feat(kit): Foundation Models picks with validated IDs and grounded notes`.

### Task 4: Kit learns from Stop / Skip and real stops

**Files:**
- Create: `cyclingskibidi/Features/Kit/KitLearning.swift`
- Modify: `NavigateView.swift` (`PassBySightCard`: "Stop here" / "Skip" Kit buttons)
- Modify: `RideRecorder.swift` (record which picks were passed)
- Modify: `FinishedView.swift` ("What Kit learned" line)

**Interfaces:**
- Consumes: `RiderProfile.weights` (Task 1); `Sight.category`; `Ride.track: [TrackPoint]` (existing: `lat`, `lon`, `t` seconds, `speed`).
- Produces:
  - `nonisolated enum KitLearning`:
    - `static let step = 0.25`
    - `static let limit = 2.0`
    - `static func record(_ category: String, stopped: Bool, in profile: inout RiderProfile)`
    - `static func detectedStops(track: [TrackPoint], picks: [Sight], minSeconds: Double = 180, radius: Double = 50) -> [Sight]`
    - `static func summary(before: RiderProfile, after: RiderProfile) -> String?`, giving e.g. "More hawker centres, fewer cafés next time", or nil when nothing changed.

- [ ] **Step 1: Write the failing tests** in `KitLearning.selfCheck()`:
  - Stop adds 0.25 and Skip subtracts 0.25.
  - 20 Skips on `cafe` leave the weight at −2.0 exactly.
  - A track standing still for 200 s within 30 m of a pick detects that pick.
  - 120 s still does not.
  - 200 s still 80 m away does not.
  - 200 s still beside a place that isn't a pick detects nothing.
  - `summary` names the categories that rose and fell, using `Discovery.icon(for:).label` in lowercase plural ("hawker centres", "cafés"). It returns nil for no change.
- [ ] **Step 2: Run it. Expected: build fails.**
- [ ] **Step 3: Implement.**
  - Stop / Skip on the pass-by card writes the profile via `@AppStorage` and closes the card.
  - At `finish()`, the detected stops count as Stops for categories not already Stopped or Skipped on this ride.
  - `FinishedView` shows the summary under the stats when it isn't nil.
  - Weights are read clamped (Task 2), so an old or hand-edited value can't run away.
- [ ] **Step 4: Run the launch checks. Expected: PASS.**
- [ ] **Step 5: Commit** `feat(kit): learn from Stop, Skip and real stops`.

### Task 5: "How I'm riding today" shapes the route

**Files:**
- Modify: `cyclingskibidi/Routing/PCN/PCNGraph.swift` (`penalised(closed:walk:avoid:)`)
- Modify: `cyclingskibidi/Routing/Routing.swift` (`plan(through:mode:context:start:)`)
- Modify: `cyclingskibidi/Features/Kit/Kit.swift` (`static func avoidCircles(for context: Set<RideContext>, at start: Date, facts:, places:) -> [NoGoCircle]`)
- Modify: the builder, detail and ride reroute callers (pass the profile's `today`)

**Interfaces:**
- Consumes: `RideContext` (Task 1); overlay `reasons` (`crowded_weekend`, `crowded_evening`, `dismount`) from `Discovery.facts`; `Closures.sg` calendar.
- Produces:
  - `PCNGraph.avoidExtraMeters: Double = 600`.
  - `penalised(closed: [NoGoCircle], walk: [NoGoCircle], avoid: [NoGoCircle] = [])`. Each edge with an endpoint inside an avoid circle gets `+avoidExtraMeters`; this is additive, never a removal, and the existing +30 % detour cap still applies.
  - `Routing.plan(through:mode:context: Set<RideContext> = [], start: Date = .now)`.

- [ ] **Step 1: Write the failing tests.**
  - **`Kit.selfCheck` (avoid circles):**
    - `.quiet` on a Saturday 10:00 gives a 150 m circle for each place tagged `crowded_weekend`.
    - On a Tuesday 10:00 there are none.
    - `crowded_evening` applies at 18:00 and not at 10:00.
    - `.kids` gives circles for `dismount` and `crowded_*` at the planned time.
    - `.visiting` alone gives none.
    - An empty context gives none.
  - **`PCNGraph.selfCheck`:** an edge in an avoid circle gains exactly `avoidExtraMeters` (±1).
  - **`PCNRouting.selfCheck`:** on the existing square test graph, an avoid circle on the short side sends the route the long way, while that way stays within the detour cap. With the cap exceeded, the short side is ridden.
- [ ] **Step 2: Run it. Expected: build fails / assertions fail.**
- [ ] **Step 3: Implement.** Routing passes `Kit.avoidCircles(...)` as `avoid` for Moderate and Leisure. Fast ignores context.
- [ ] **Step 4: Run the launch checks. Expected: PASS.** The Bedok closure check and the road check timings are within 20 % of before.
- [ ] **Step 5: Commit** `feat(kit): ride context steers routes away from crowded and dismount stretches`.
- [ ] **Step 6: Update the spec's status line** to "Built: section 0 (plan 1), section 1 (plan 2), section 2 (plan 3), section 5 (offline)". Commit `docs(kit): plan 3 built`.

## Decisions this plan makes (the builder's calls, per "Left to the builder")

- **Storage:** the profile and learned weights live in one `AppStorage` JSON string, not SwiftData. They are small, per device, and never queried.
- **Scoring weights:** persona tag 3, liked category 2, research note 1.5, Wikipedia 1, learned −2…+2 in steps of 0.25.
- **Model timeout:** 8 s. The quick picks are already showing, so a slow model costs nothing visible.
- **Grounding check:** capitalised words and numbers in a note must appear in the candidate's facts line. This catches invented stalls, places and prices. It cannot catch a wrong common-noun claim; the instructions and the facts-only prompt are the guard there.
- **Per-route edits:** the builder's "For you" button edits the saved profile. There is no separate per-route copy, because the spec's per-route edit and the settings edit would otherwise drift apart.
- **Hawker centres with no data** get "Hawker centre, local dishes". Naming a generic dish there could be untrue for that centre.
- **Visiting Singapore** doesn't bend the route in this plan. "Favour iconic views and rental points" is a discount on edges near features, which is the scenic slider's mechanism (section 4). It lands with plan 5, so the two don't fight over edge costs.
- **Start ride refresh:** the detail view already recomputes picks on every open (plan 2 fix), and Start is pressed from there, so there's no separate refresh at Start.
