# No-Bike Safety Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** No plan or reroute ever leads a rider onto an expressway or another way where bikes aren't allowed. Riders get a clear, labelled warning before the ride, when a reroute happens, and if they head toward one off route. Walk-your-bike bridges get their own banner and label.

**Architecture:**
- A build step adds `nobike.json` to the bundle. It holds the no-bike lines, used to test straight fallback legs, and their entrances, used for the off-route alarm.
- `Routing.plan` marks every straight fallback leg that crosses a no-bike line. Saved routes keep those points, and reroutes that contain one are never applied.
- `RideRecorder` raises the expressway alarm and the walk-your-bike mode. Both reuse its existing approach-and-pass mechanics.
- A small `PixelIcon` view draws the same 12×12 bitmaps as Figma, so the labels need no image assets.

**Tech Stack:** Python + osmium (`scripts/map/`), Swift / SwiftUI / SwiftData, iOS 18+, assert-based `selfCheck()`s at launch in DEBUG.

**Spec:** `docs/superpowers/specs/2026-11-20-kit-personalised-places-design.md`, section 6a (and section 0 for walk-your-bike routing).

## Global Constraints

- **No bikes at all** (terracotta): expressways and slip roads (`highway=motorway|motorway_link`), `bicycle=no` ways and `highway=steps`. These are never routed: not by the road network (already true, `scripts/map/roads.py:11,53`), and not by a straight fallback leg that crosses one. A reroute that would need one is not applied.
- **Walk your bike** (gold): the `no_cycling` circles in `closures.json`. Plans and reroutes use them with the existing small penalty. They are never hard-blocked.
- Fully offline; the data ships in the bundle. iOS 18+. MainActor by default; heavy pure work is `nonisolated` and runs in `Task.detached`.
- Copy and look follow Figma `v3 · 12`, `13`, `14` and `16`, the `Kit/road label` component and the pixel icons on the "Cycling — Kit style" page. Rider-facing text spells out "park connector" and "hawker centre".
- Every full-screen alarm has "It's not there", which silences that spot for this ride (spec section 7).

## Review Focus

1. **Over- and underpasses:** a real road or path crosses an expressway on a bridge or in an underpass every few hundred metres. Only straight fallback legs may be flagged, never real network edges. (Task 3 test.)
2. **Riding beside an expressway:** service roads and park connectors run 15–30 m from the Pan-Island Expressway and the East Coast Parkway. A rider on route there must never be alarmed, and an off-route rider only when heading into an entrance. (Task 4 tests.)
3. **A reroute with no safe answer:** the rider keeps the old line and gets an honest "Turn back to your route" banner. There is no loop of reroutes. (Task 3 test.)
4. **Old saved routes** without the new field decode and show no false warning. (Task 3 test.)
5. **Walk mode not ending:** GPS noise near the bridge end must not flip walk mode on and off every second. It needs hysteresis. (Task 4 test.)

---

### Task 1: No-bike data in the bundle

**Files:**
- Modify: `scripts/map/extract.py` (collect no-bike ways with their names and node refs)
- Create: `scripts/map/nobike.py` (with its own `--check`)
- Create: `cyclingskibidi/nobike.json` (generated; Git LFS not needed if under 500 KB)
- Modify: `scripts/map/README.md` (one step and the committing note)

**Interfaces:**
- Produces `cyclingskibidi/nobike.json`:
  - `{"lines": [{"kind": "expressway"|"nobike"|"steps", "name": String, "pts": [[lat, lon], ...]}], "entrances": [{"kind": ..., "name": String, "lat": Double, "lon": Double}]}`
  - Each line is thinned to keep a point at least every 50 m.
  - An entrance is a node shared by a no-bike way and a rideable way: one in `roads.py`'s `CLASS` that isn't excluded.
  - Coordinates are rounded to 6 dp. There is one entry per line, and the output is sorted, so it's deterministic.

- [ ] **Step 1: Write the failing check** in `nobike.py --check`:
  - `kind({"highway": "motorway"}) == "expressway"`, and `"motorway_link"` is too.
  - `kind({"highway": "footway", "bicycle": "no"}) == "nobike"`.
  - `kind({"highway": "steps"}) == "steps"`.
  - `kind({"highway": "residential"}) is None`.
  - `kind({"highway": "footway", "bicycle": "yes"}) is None`.
  - `entrances()` on a toy graph returns exactly the junction node: motorway_link nodes `[1, 2, 3]` and residential nodes `[3, 4]` give one entrance at node 3. Two motorway ways meeting give none.
  - `thin()` keeps both ends, and no gap is over 50 m.
- [ ] **Step 2: Run** `.venv/bin/python -I scripts/map/nobike.py --check`. **Expected:** NameError (RED).
- [ ] **Step 3: Implement.**
  - `extract.py` adds `"nobike": [(tags_subset, pts, node_refs)]` to the pickle.
  - `nobike.py layers.pickle` writes `cyclingskibidi/nobike.json` and runs the same `CLASS`/exclusion rules `roads.py` uses: import them, don't copy them.
- [ ] **Step 4: Run the check.** **Expected:** "nobike checks passed".
- [ ] **Step 5: Build it.**
  - Re-run `extract.py`, then `nobike.py layers.pickle`. Run it twice and `cmp` the outputs: they must be identical.
  - Print the counts. **Expected:** expressway lines in the low hundreds, entrances in the hundreds, file under 500 KB. If it's over, thin to 80 m and record a ruling.
  - Spot-check that the Pan-Island Expressway, Ayer Rajah Expressway and East Coast Parkway are present by name.
- [ ] **Step 6: Commit.** Code in `feat(safety): bundle no-bike ways and their entrances`, the data in `data: no-bike ways from OSM 2026-11-26`.

### Task 2: Pixel icons and the road label in SwiftUI

**Files:**
- Create: `cyclingskibidi/Features/Kit/PixelIcon.swift`
- Create: `cyclingskibidi/Features/Kit/RoadLabel.swift`

**Interfaces:**
- Produces:
  - `struct PixelIcon: View { let rows: [String]; var size: CGFloat = 16 }`. It draws `#` cells from a 12×12 grid on a `Canvas` in `foregroundStyle`, with no antialiasing gaps.
  - `nonisolated enum PixelArt { static let noBikes, expressway, walkBike, closed: [String] }`. The rows are copied exactly from the Figma components (`icon/no-bikes` `263:7376`, `icon/expressway` `263:7416`, `icon/walk-bike` `263:7325`, `icon/closed` `220:604`). Read them from the file's vector paths: 2 pt cells on a 24 pt grid.
  - `enum RoadLabelKind: String, CaseIterable { case noBikes, expressway, closed, walkYourBike }` with `text` ("NO BIKES", "EXPRESSWAY · NO BIKES", "CLOSED", "WALK YOUR BIKE"), `tone` (`.noAccess` / `.caution`) and `art`.
  - `struct RoadLabel: View { let kind: RoadLabelKind }`. Its layout:
    - paper / terracotta / gold fill and a 2 pt ink border, square corners
    - padding 10 × 6, a 6 pt gap, a 16 pt icon
    - DM Sans Bold 12 at 8 % tracking (system bold if the font isn't bundled yet), ink text
    - an accessibility label equal to the text in sentence case

- [ ] **Step 1: Write the failing test** `PixelArt.selfCheck()`:
  - Every bitmap is 12 rows of 12 characters, using only `#` and `.`.
  - `expressway` is left–right symmetric.
  - `noBikes` has the diagonal `(r, r)` set for every r.
  - Each `RoadLabelKind`'s text is uppercase and its tone matches the spec table (noBikes, expressway and closed are `.noAccess`; walkYourBike is `.caution`).
- [ ] **Step 2: Run** the launch check. **Expected:** the build fails (RED).
- [ ] **Step 3: Implement.** Add a `#Preview` showing all four labels in light and dark.
- [ ] **Step 4: Run** the launch check. **Expected:** PASS. Compare the preview with Figma `Kit/road label` (`264:7401`) side by side. Write any differences in the ledger.
- [ ] **Step 5: Commit** `feat(kit): pixel icons and road labels`.

### Task 3: Straight legs never cross a no-bike way; reroutes never apply one

**Files:**
- Create: `cyclingskibidi/Routing/NoBike.swift`
- Modify: `cyclingskibidi/Routing/Routing.swift` (`RoutePlan.noBikeCrossings`)
- Modify: `cyclingskibidi/Models/Models.swift` (`Route.noBikeData`, set in `make` and `apply`)
- Modify: `cyclingskibidi/Features/Navigate/RideRecorder.swift` (`applyReroute` guard + banner reason)
- Modify: `RouteDetailView.swift` / `SheetView.swift` (Kit card + rows, Figma `v3 · 13`)

**Interfaces:**
- Consumes: `nobike.json` (Task 1); `RoadLabel` (Task 2); `RoutePlan.offConnectorSegments` (existing: 2-point entries are straight fallback legs); `Closures.activeCircles().walk`.
- Produces:
  - `nonisolated struct NoBikeLine: Sendable { let kind: String; let name: String; let pts: [Coord] }` and `NoBikeEntrance` likewise.
  - `nonisolated enum NoBike`:
    - `static let lines: [NoBikeLine]`, loaded once from the bundle
    - `static let entrances: [NoBikeEntrance]`
    - `static func crossings(of leg: [Coord], lines: [NoBikeLine] = NoBike.lines) -> [Coord]`, the crossing points of a straight leg with any line (segment intersection with a bbox prefilter)
  - `static func crossings(inOffSegments segments: [[Coord]], lines: [NoBikeLine] = NoBike.lines) -> [Coord]`: tests only the 2-point segments, which are the straight fallback legs.
  - `RoutePlan.noBikeCrossings: [Coord]`, set by `Routing.plan` from `NoBike.crossings(inOffSegments: plan.offConnectorSegments)`. This covers the empty-graph fallback too, because it is stored as one off segment; if that segment has more than 2 points, split it into pairs first.
  - `Route.noBikeData: Data?` with `var noBikeCrossings: [Coord]` (nil = none, so old saves decode).
  - `RideRecorder.rerouteBlockedReason: String?`.
  - `static func walkStretches(on polyline: [Coord], walk: [NoGoCircle], names: [String]) -> [(name: String, along: Double, length: Double)]`, for the gold rows.

- [ ] **Step 1: Write the failing tests** in `NoBike.selfCheck()` and the existing checks:
  - **Crossing:** a straight leg crossing a toy expressway line gives 1 point, within 1 m of the true intersection. A parallel leg 20 m away gives 0. A leg ending 5 m short gives 0.
  - **Real data:**
    - A straight leg across the Pan-Island Expressway near Toa Payoh (two points either side, about 400 m apart) gives at least 1 crossing.
    - `NoBike.lines` has at least one line named "Pan-Island Expressway".
    - A real road-network route between the same two points has `noBikeCrossings.isEmpty`. It crosses on a bridge or underpass, which is a real edge and is never tested.
  - **Plan step:**
    - `crossings(inOffSegments:)` with one 2-point segment across a toy expressway and one 40-point road segment across the same line returns exactly 1 point, from the straight leg only.
    - An empty list returns [].
    - `Routing.plan`'s empty-graph fallback path calls it: assert by reading `plan.noBikeCrossings` on a fallback plan whose pins straddle a toy line passed through a `lines:` parameter added to `plan` with default `NoBike.lines`.
  - **Reroute:** `applyReroute` with a plan whose `noBikeCrossings` is non-empty keeps the old polyline, sets `rerouteBlockedReason = "Turn back to your route: no bike path ahead"`, and does not count as an attempt that triggers another immediate reroute.
  - **Saved routes:** a `Route` saved without `noBikeData` has `noBikeCrossings == []`.
  - **Walk rows:** `walkStretches` on a line through a 50 m walk circle returns one stretch about 100 m long at the right offset. It returns none when the circle is 200 m off the line.
- [ ] **Step 2: Run** the launch check. **Expected:** the build fails (RED).
- [ ] **Step 3: Implement.**
  - In `Routing.plan` (new trailing parameter `noBikeLines: [NoBikeLine] = NoBike.lines`), after `poly` is final, set `plan.noBikeCrossings = NoBike.crossings(inOffSegments:lines:)`.
  - `Route.make` and `apply` persist it.
  - **Route detail** (Figma `v3 · 13`):
    - When there are crossings, the Kit card shows terracotta "KIT · NO BIKE PATH HERE" with "No bike path for <n> m near <nearest line name>, and the road beside it is an expressway. Walk the footpath, or move your end point."
    - Each crossing adds a terracotta "No bike path · km x" row with `RoadLabel(.noBikes)`.
    - Each walk stretch adds a gold "<name> · km x" row with `RoadLabel(.walkYourBike)` and "No cycling here: walk your bike <n> m."
- [ ] **Step 4: Run** the launch check. **Expected:** PASS.
- [ ] **Step 5: Try it.** Plan a Moderate route whose end pin sits on the far side of the Ayer Rajah Expressway with no nearby crossing, using a temporary DEBUG print. **Expected:** the crossings are flagged and the route detail shows the card. Remove the print.
- [ ] **Step 6: Commit** `feat(safety): straight legs never cross a no-bike way; reroutes refuse them`.

### Task 4: On the ride: the expressway alarm and walk-your-bike mode

**Files:**
- Create: `cyclingskibidi/Features/Navigate/NoBikeAlarm.swift` (Figma `v3 · 12`)
- Modify: `RideRecorder.swift` (`checkNoBike(at:)`, `walking` state, moving time)
- Modify: `NavigateView.swift` (present the alarm; banner for walk mode and reroute reason, Figma `v3 · 14`, `v3 · 16`)

**Interfaces:**
- Consumes: `NoBike.entrances` (Task 3), `RoadLabel` (Task 2), `Closures.activeCircles().walk`, and the recorder's existing `offRoute`, GPS fix and speed.
- Produces:
  - `RideRecorder.noBikeAhead: (entrance: NoBikeEntrance, distance: Double)?`
  - `RideRecorder.silencedNoBike: Set<String>` (keyed by `lat|lon`)
  - `RideRecorder.walkingThrough: String?` (the zone name)
  - `static let entranceRadius = 60.0`
  - `static let walkEnter = 0.0`, `walkExit = 15.0` (metres outside the circle before walk mode ends)

- [ ] **Step 1: Write the failing tests** in `RideRecorder.selfCheckNoBike()`:
  - **On route** 20 m from an entrance and closing: no alarm, ever.
  - **Off route**, approaching an entrance (50 m → 30 m over two fixes): alarm, with distance about 30.
  - **Off route** 50 m away but moving away: no alarm.
  - **Off route**, passing parallel to an expressway line 20 m away with no entrance within 60 m: no alarm.
  - After "It's not there", the same entrance stays silent for the rest of the ride. A different entrance still alarms.
  - Each entrance alarms once per approach.
  - **Walk mode:**
    - Entering a walk circle sets `walkingThrough` to its name.
    - Fixes alternating 2 m inside / 5 m outside the edge keep it set (hysteresis). 20 m outside clears it.
    - Moving seconds do not increase while `walkingThrough != nil`.
- [ ] **Step 2: Run** the launch check. **Expected:** the build fails (RED).
- [ ] **Step 3: Implement.**
  - **Alarm** (`NoBikeAlarm`, a full-screen terracotta takeover like `v3 · 12`):
    - "STOP IN <n> m" (big numerals), "Expressway ahead: bikes not allowed" or "No bikes ahead", and one line naming the entrance.
    - Buttons: "Take the way round" (reroute from here; the reroute obeys Task 3), "Show me on the map" (dismiss and centre the map on the entrance) and "It's not there" (silence).
    - A strong haptic and a short sound.
  - **Walk mode:** the banner shows "Walk your bike" with the zone name and `RoadLabel(.walkYourBike)`, as in `v3 · 16`.
  - **Reroute:** when `rerouteBlockedReason` is set, the banner shows it (`v3 · 14` style). It clears when the rider rejoins the route.
- [ ] **Step 4: Run** the launch check. **Expected:** PASS. Run on the oldest installed runtime too.
- [ ] **Step 5: Try it** in the simulator with a GPX walk-through (Xcode location simulation). The track goes off route toward an Ayer Rajah Expressway entrance, then across Henderson Waves. **Expected:** the alarm fires once; "It's not there" silences it; walk mode shows on the bridge and clears after it. Note the result in the ledger.
- [ ] **Step 6: Commit** `feat(safety): expressway alarm off route and walk-your-bike mode`.
- [ ] **Step 7:** Update the spec status line to add "section 6a (plan 2b)". Commit `docs(kit): plan 2b built`.

## Decisions this plan makes

- **Only straight fallback legs are tested for crossings.** Network edges cross expressways on bridges and in underpasses, which is legal, and they never ride on one, by construction.
- **The alarm triggers on entrances, not lines.** Riding beside an expressway is normal; entering one is the danger. It only fires while off route, because on-route lines are no-bike-free by construction.
- **A blocked reroute keeps the old line.** The rider can always turn back along a line that was safe. A banner explains it, and there is no retry loop.
- **Walk mode pauses moving time.** Pushing a bike isn't riding, and the stats should say so.
- **Only four labels ship now** (no bikes, expressway, walk your bike, closed). The other nine `Kit/road label` kinds need data or UI from later plans.
