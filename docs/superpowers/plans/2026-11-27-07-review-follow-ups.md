# Review Follow-ups Implementation Plan (spec section 7)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship section 7's offline heat-and-rain hints, the tourist extras that need no new data licence, and the ride-screen UI fixes.

**Architecture:** Small, independent changes in existing views plus two pure helpers (`HeatHint`, `PresetLoops`), each with a self-check. Alarm/HELP items in section 7 are already in plan 6.

**Tech Stack:** Swift / SwiftUI, iOS 18+, assert-based `selfCheck()`s at launch in DEBUG.

**Spec:** `docs/superpowers/specs/2026-11-20-kit-personalised-places-design.md`, section 7 (and "UI (Figma v3)").

## Global Constraints

- Heat and rain, offline only: "Cooler before 10 am or after 5 pm; 1–4 pm is hottest and storms are common." Sheltered rest stops marked (`shelter`, `covered=yes`). Kit suggests a shelter when the ride starts in the afternoon. No live weather.
- Tourist extras: rental shops and bicycle parking can be start and end points ("return the bike here"); 2–3 preset iconic loops. Ship only sources whose licence allows bundling, with attribution. Rider-facing text spells out "park connector" and "hawker centre".
- Ride screen: turn arrow and distance always the large top row of the banner, Kit's message under it, "600 m" never wraps; in the ride panel next turn and km to go come first, the timer smaller; Pause and End ride above the home indicator, End ride needs a hold; touch targets ≥ 52 pt; contrast WCAG AA in both themes; map pins carry pixel icons, not colour alone; "Along the way" rows have chevrons and swipe to add/remove a stop; Dynamic Type for body text; VoiceOver labels for icons and Kit's mood.
- Native iOS controls and Apple-style sheets stay; Kit theming only on Kit's own parts.

## Out of scope here (needs the user)

- **LTA DataMall bicycle parking** (the research's recommended source) needs an LTA `AccountKey` and a build-time pull. Until the user provides one, parking comes from the OSM points already in `places.json` (`bikeParking`), which are ODbL and already credited.
- **DM Sans and Jersey 10 fonts** are SIL OFL and may be bundled, but must be downloaded once from their official repositories; the system font stands in until then.
- **GPX / Apple Health export** stays "later (optional)".

## Review Focus

1. **A ride starting at 13:00 on a route with no shelter:** the hint still shows; no shelter suggestion is invented. (Task 1 test.)
2. **Huge Dynamic Type (AX5):** the banner distance still never wraps; Kit's message wraps under it. (Task 3 check.)
3. **"Return the bike here" on a parking point:** the route's end pin snaps to it and the sheet says so. (Task 2 test.)
4. **A preset loop crossing an active closure:** it is planned like any route, so it bends round. (Task 2 test.)
5. **VoiceOver on a pixel-icon pin:** announces what it is, not "image". (Task 3 check.)

---

### Task 1: Heat and rain hint, sheltered stops

**Files:**
- Create: `cyclingskibidi/Features/Kit/HeatHint.swift`
- Modify: `cyclingskibidi/Features/Routes/SheetView.swift` (hint under the summary for Leisure/Moderate), `cyclingskibidi/Features/Kit/RestStops.swift` (`RestStop.sheltered: Bool` from a `shelter` amenity or `covered=yes`)

**Interfaces:**
- Produces: `nonisolated enum HeatHint { static let text = "Cooler before 10 am or after 5 pm; 1–4 pm is hottest and storms are common."; static func isHot(_ start: Date) -> Bool /* 13:00–16:59 Singapore time */; static func shelterSuggestion(start: Date, stops: [RestStop]) -> String? }` — when hot and a sheltered stop exists: "It's the hottest part of the day. <name> at km <n> has shelter." else nil.

- [ ] **Step 1: Failing test** `HeatHint.selfCheck()`: 12:59 not hot, 13:00 hot, 16:59 hot, 17:00 not (Singapore calendar `Closures.sg`); suggestion nil when no sheltered stop; names the first sheltered stop otherwise.
- [ ] **Step 2: Run** `zsh .superpowers/sdd/fix/run.sh`. **Expected:** BUILD FAILED.
- [ ] **Step 3: Implement.** Sheltered stops get an umbrella badge in the Rest stops rows.
- [ ] **Step 4: Run.** **Expected:** LAUNCH CLEAN.
- [ ] **Step 5: Commit** `feat(kit): heat and rain hint, sheltered rest stops`.

### Task 2: Rental and parking as start/end, preset loops

**Files:**
- Create: `cyclingskibidi/Features/Routes/PresetLoops.swift`
- Modify: `cyclingskibidi/Features/Routes/RouteBuilderView.swift` (search results for `bikeRental`/`bikeParking` offer "Start here" / "Return the bike here"; a "Loops" row with the presets)
- Modify: `cyclingskibidi/Features/Routes/SheetView.swift` (end-at-parking line)

**Interfaces:**
- Produces: `nonisolated struct PresetLoop: Identifiable { let id: String; let name: String; let blurb: String; let waypoints: [Coord] }`, `static let all: [PresetLoop]` with three loops: East Coast Park ↔ Gardens by the Bay East, Marina Bay loop, Punggol Waterway and Coney Island. Waypoints are hand-picked points on the park connector graph (each must snap within 30 m of a PCN node — asserted).

- [ ] **Step 1: Failing test** `PresetLoops.selfCheck()` (async, real graph): every loop's waypoints snap within 30 m; first == last; planned Leisure distance 8–30 km; a toy active closure on a loop's line is bent round (`Closures.hits` on the new line is empty). And a route whose last waypoint is a `bikeParking` place has the sheet line "Return the bike here: <name>".
- [ ] **Step 2–4:** RED → implement → LAUNCH CLEAN.
- [ ] **Step 5: Commit** `feat(routes): start or end at a rental or bike parking; three preset loops`.

### Task 3: Ride screen UI pass

**Files:**
- Modify: `cyclingskibidi/Features/Navigate/NavigateView.swift` (banner, panel, buttons, pins), `cyclingskibidi/Features/Routes/SheetView.swift` (Along the way rows), `cyclingskibidi/Features/Kit/PixelIcon.swift` (add the place icons: food, photo, water, rest, heritage, architecture, wildlife, art, café, kids, tourist, quiet, bridge — bitmaps read from Figma "Cycling — Kit style" pixel icon set)

**Interfaces:**
- Produces: `PixelArt.forCategory(_ category: String) -> [String]` (falls back to `photo`), used by map pins and rows; `HoldButton(title:seconds:action:)` (fill visible, used by End ride; plan 6's HELP stop reuses it if built first, else this task adds it).

- [ ] **Step 1: Failing test** `PixelArt.selfCheck()` gains: every new bitmap 12×12 of `#`/`.`; `forCategory` covers every `Discovery.leisureCategories` member and every `RestStops.amenityCategories` member with a non-fallback icon. `HoldButton` progress: `HoldButton.progress(held: 1.5, of: 3) == 0.5`, clamps at 1.
- [ ] **Step 2: Run.** **Expected:** BUILD FAILED.
- [ ] **Step 3: Implement** the constraints list above: banner top row `HStack(arrow, distance)` with `.lineLimit(1).fixedSize()` on the distance and Kit's message below; panel order next turn → km to go → smaller timer; Pause and End ride inside the safe area, End uses `HoldButton(seconds: 1.5)`; every button `minHeight: 52`; pins use `PixelIcon` with `accessibilityLabel`; Along the way rows with chevrons and `swipeActions` (add / remove stop); body text `.font(.body)` styles so Dynamic Type applies.
- [ ] **Step 4: Run.** **Expected:** LAUNCH CLEAN. Simulator screenshots at default and AX5 text sizes, light and dark; check "600 m" never wraps; Accessibility Inspector contrast check on terracotta/ink and on dark secondary buttons. Note results in the ledger.
- [ ] **Step 5: Commit** `feat(ui): ride screen review fixes`. Update the spec status line to add "section 7 (plan 7, except LTA parking, fonts, export)", commit `docs(kit): plan 7 built`.

## Decisions this plan makes

- **OSM parking now, LTA later**, because LTA needs a key only the user can get.
- **Presets are three hand-picked loops** checked against the real graph in a self-check.
- **End ride holds for 1.5 s**, HELP stop for 3 s (spec).
