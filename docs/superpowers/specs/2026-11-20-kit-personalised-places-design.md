# Kit — Personalised, Offline Places Along Your Route — Design

Date: 2026-11-20
Status: approved. Built: section 0 (plan 1), section 1 (plan 2), section 2 (plan 3), section 3 (plan 4), section 4 (plan 5), section 5 (offline), section 6a (plan 2b), section 7 (plan 7, except LTA parking, fonts, export). Amended 26 Nov 2026: iOS 18 target, places from the shared OSM extract, section 6a no-bike ways.
Builds on: Phase 2 PCN routing (`docs/superpowers/specs/2026-09-04-phase2-pcn-routing-design.md`), existing leisure sights (`Discovery.swift`, `Sight`, `RideRecorder.checkSights`).
Research: `reports/Singapore PCN stops and reviews.md`, `reports/Singapore cycling rider personas.md` (+ `research_notes/`).
Visual reference: Figma file `XXNkFRE4TcJ9VesSYFxnBx`, page "Cycling — Kit style", section "REDESIGN v3" (screens `v3 · 01`–`06`, components `Kit/bubble`, `Kit/timer`, `Kit/chart`, `Kit/avatar`).

## Intent — why

Places along a route today are **not personalised and not accurate**: some aren't really on the route, some are closed, some are badly regarded. The user wants:

- places picked **for the rider** (nature lover sees bridges, canals and scenic stretches; foodie sees hawker centres with a dish to try; and other rider types),
- **rest stops** on long rides (>20 km) based on both the rider's fitness level and stop quality,
- routes that **avoid closed paths**,
- everything working **fully offline** (no network at plan or ride time for places, closures and AI),
- **Apple Foundation Models** (on-device) choosing and explaining the picks, voiced by **Kit** (the pixel cat from the user's design system) as a helper.

## Goals

1. Routes never send riders onto currently-closed PCN stretches; expired closures prompt "check status".
2. Places come from a bundled offline file, filtered for real proximity to the line, openness, and no-cycling rules.
3. Riders pick interests (what they like) and ride context (how they're riding today) once; Kit picks and explains places accordingly.
4. Rides over 20 km get rest stops spaced by rider level and chosen by facility quality, with warnings before water gaps.
5. Leisure routes can bend toward scenic stretches via a Direct ↔ Scenic slider.
6. Kit learns from Stop / Skip and from places the rider actually stopped at.

## Non-goals

- Live data of any kind (reviews, opening status, weather, crowds). The app ships what the bundled files say.
- Automatically messaging or calling someone after a fall (iOS needs a tap to send a text or place a call; see section 6).
- Star ratings. Research found no retrievable crowd reviews; "quality" is reason codes (crowded, dismount, no water, closed) plus notability, not scores.
- Exact closure geometry. Closures are circles along the stretch.
- Rest stops on Fast mode.
- Any download at any time, even optional. The app is fully offline for a challenge; data updates ship only with app releases.
- Kit-theming system UI. Native iOS controls and Apple Maps stay as they are.

## Anti-goals (failure even if it "works")

- Kit or the model **naming a place, stall or fact that isn't in the bundled data** (hallucination).
- Recommending a place that is closed, in a no-cycling zone, or not reachable from the line.
- A noticeably worse app on iPhones without Apple Intelligence (must have a deterministic fallback).
- Routing a rider onto a closed stretch.

## Constraints

- **iOS 18 and later** (decided with the user, 26 Nov 2026; replaces the earlier 27.2 target). Anything newer sits behind `#available` with a fallback that works on iOS 18:
  - Kit's model picks (Foundation Models) run only on iOS 26+ with Apple Intelligence on. Every device first gets the approach A picks; the model's picks replace them only when they are better (see the model stage). On iOS 18–25 approach A is the whole feature, so it must be good on its own.
  - Liquid Glass falls back to the standard material on iOS 18–25.
  - Fall detection, alarms, fonts and Kit's UI use only iOS 18 APIs.
- Project defaults to MainActor isolation; avoid blocking async bridges (see memory: use fire-and-forget `Task {}`).
- Fully offline: data ships in the bundle; refreshed by the developer re-running scripts before a release.
- OpenStreetMap data is **ODbL**: visible "© OpenStreetMap contributors" credit (About / map attribution), OSM-derived file stays ODbL and can be provided on request. Our own labels, research notes and Michelin list live in a **separate file keyed by OSM ID**.
- On-device model context is small: send ≤ ~40 compact candidates per request.

## Approaches considered (who picks the places)

| Approach | Trade-off | Decision |
|---|---|---|
| A. Deterministic scoring picks; model only writes notes | Repeatable, testable, same on all devices; less nuanced | **Used as the fallback** |
| **B. Foundation Models picks from a pre-filtered candidate list and writes notes** | Handles subtle preferences; slower, non-deterministic, needs fallback | **Chosen by the user** ("slower is fine at leisure pace") |
| C. Pre-rank per interest in the build script | Least app code; can't fit the rider's own line or fitness | Rejected |

Guardrails that make B safe: (1) hard filters run in code before the model sees anything; (2) the model returns only candidate IDs via `@Generable` structured output — it cannot introduce places; (3) notes always come from our template, never from the model (amended 26 Nov 2026: on-device trials showed the model pasting facts, writing "none" and borrowing other places' facts); (4) devices without Apple Intelligence (or on model error/timeout) use approach A.

## Decisions made with the user

- Fully offline, including places; OSM extract + research overlay bundled.
- Build order: **0 Closures → 1 Places file → 2 Interests + Kit picks → 3 Rest stops → 4 Scenic slider**, with **5 Offline** and **6 Alarms + fall detection** (order between them set in the plan; the map airplane-mode test runs first of all).
- **Whole app offline.** Decisions per online part are in section 5.
- **Kit alarms:** full-screen takeovers with looping animation when approaching an obstacle or a no-access stretch.
- **Fall detection** using the phone's motion sensors, with an alarm that is loud even on silent mode.
- **After the three-round review (20 Nov 2026):** strictly offline, with no optional download. Ride export (GPX / Apple Health) is optional, for later. Yes to: rest stops on short rides too, offline heat/rain hints, and tourist extras (rental shops, bike parking, preset loops) from researched Singapore data. Rework the screens with every UI fix the review listed (section 7).
- Approach B with fallback A.
- Rest stops on rides > 20 km; spacing from **rider level** and choice from **stop quality** ("both").
- Scenic routing is **rider-controlled** by a Direct ↔ Scenic slider.
- Foodie gets **dish suggestions**; stalls only when sourced (Michelin Bib Gourmand 2026 or long-established with a source).
- Persona model is split into two axes:
  - **What I like** (picks places): Nature & photos, Food, Architecture, Heritage, Wildlife, Art & murals, Cafés.
  - **How I'm riding today** (shapes the route): With kids, Visiting Singapore, Keep it quiet.
- UI: native iOS (SF Pro, sheets, rows, slider, segmented control) and Apple Maps retained. **Kit-themed:** Kit's speech cards, the ride timer, charts, **all action buttons and map control buttons** (Kit spec), and **pixel icons** for places, pins and interest chips. Maps are shown in Apple Maps dark style in mockups.
- Closure gaps with no on-connector path: dashed off-connector stretch, rider chooses their own way (offline).

## The design

### 0. Closures (first)

- **Data:** `closures.json` bundled. Each entry: `id`, `name`, `circles: [{lat, lon, radius_m}]`, `starts`, `valid_until` (nullable), `note` (detour text), `source_url`, `kind` (`closure` | `no_cycling`). `no_cycling` entries never expire.
- **Seed content** from the research (as of 20 Nov 2026), e.g. Rail Corridor South Henderson Rd→Spooner Rd (to 2027-07-31), Loyang PC (Q3 2029), AMK Ave 6 PC (end 2028), AMK Ave 5 diversion (2028-04-30), Kallang PC near St Michael's (2H 2027), Alexandra–Queensway PC (Q3 2027), two Bedok PC sections (2026-12-31), Gardens by the Bay Waterfront Promenade (no end date), Punggol Point Park (≈2027-12-31). No-cycling: Henderson Waves, Kent Ridge Canopy Walk, Telok Blangah Forest Walk, Labrador/Berlayer/Bukit Chermin boardwalks, West Coast Marsh Garden boardwalk, Punggol Kelong/Wave/Adventure bridges, Pasir Ris & Changi boardwalks, Jurong Lake Gardens no-cycling zones, nature reserves, Botanic Gardens.
- **Routing (revised after review):** edges touching an **active** `closure` circle get an *additive* cost (their length + a fixed 1.5 km), and any detour is capped at about +30% of the open route. Closed runs are not ridden. Each closed run is replaced by a gap leg routed around the closure (road network in plan 6, otherwise a straight dashed line). `no_cycling` circles mean **walk your bike**: a small penalty and a warning, not avoidance. A* gets a binary heap and runs off the main actor. Rider-reported hazards (`NoGoCircle`) use the same edge-removal path instead of forcing the whole route through BRouter.
- **Closure gaps (decided with the user):** keep the route on the connector map wherever possible. If removing a closure leaves no on-PCN path, the gap is shown on the map as a **dashed "off-connector" stretch**. *My call, after the road-network decision in section 5:* the dashed stretch follows the bundled road network so it is a real rideable way; if even that fails, it is a straight dashed line and the rider picks their own way. Kit's Heads-up card names the gap and its length.
- **Expired** closures don't block; if the route passes through one, show "Was closed until <date> — check status".
- Kit `Heads-up` card in route detail and during navigation when the route was bent around a closure.

### 1. Offline places file

- **Build script** (run on the developer's Mac, not in the app): read the same Singapore OSM extract the map and road scripts use (`scripts/map/extract.py`, `sg.osm.pbf`) with `osmium`, keep places within ~1 km of the PCN graph, emit `places.json` (ODbL). One OSM snapshot feeds places, roads and tiles. Do **not** depend on the public Overpass server (overloaded in research); `scripts/places/places.ql` is replaced.
- **Record:** `osm_id`, `name`, `lat`, `lon` (entrance/edge point where available, else centroid), `category`, `tags` subset (`opening_hours`, `wikipedia`/`wikidata`, `religion`, amenity details), `area_m2` for large features.
- **Categories and OSM sources** (see personas report table): named bridges (`man_made=bridge`), waterways (`waterway=canal/river`), reservoirs/wetlands/beaches, `tourism=viewpoint`, parks, hawker centres (`amenity=food_court|marketplace|restaurant` with hawker-style names, cross-checked against NEA list), cafés, places of worship, `historic=*`, museums, `tourism=artwork`, playgrounds, rest-stop amenities (`toilets`, `drinking_water`, `water_tap`, `shelter` excluding bus shelters, `bicycle_repair_station`, `bicycle_parking`, `bicycle_rental`).
- **Overlay** `places_overlay.json` (ours, not ODbL-derived): keyed by OSM ID or by name+coord for hand-added places. Fields: `persona_tags`, `reason_codes` (`crowded_weekend`, `dismount`, `no_water`, `limited_food`, …), `status` + `valid_until`, `signature_dishes`, `stalls` (only Bib 2026 or sourced long-established), `best_time` (e.g. golden hour), `note` (one sourced line), `source_url`. Architecture spots are **hand-curated** here (OSM has no usable architecture tags in Singapore).
- **Replaces** the MapKit search in `Discovery.sights(along:)`; `Look Around`, website and phone actions degrade to name, type, hours, distance along route.
- **Accuracy fixes:** proximity = distance from line to the place's nearest point (100 m small places, 300 m large parks); drop places closed at the rider's estimated pass time (from `opening_hours`); drop anything inside a `no_cycling` circle unless it's "park and walk" tagged; spread picks across the route (no first-20 truncation).

### 2. Interests and Kit's picks

- **Onboarding sheet** (Figma `v3 · 01`, to be updated for the two-axis split): "What I like" chips, "How I'm riding today" chips, and rider level (Beginner / Regular / Strong). Editable later in settings and per-route in the builder.
- **Candidate stage (code):** places within the corridor, after hard filters, scored roughly by persona match + notability (`wikipedia`) + overlay reason codes + spacing; top ~40 sent to the model as compact lines (`id | name | category | km along | facts`).
- **Model stage (Foundation Models, on device):** `LanguageModelSession` with instructions describing Kit and the rider profile, the approach A picks given as a draft; `@Generable` result `{ ids: [String] }` with a target count (~5 per 20 km, rider-adjustable later). Validate every returned ID against the candidates; drop unknown IDs; notes come from the template. The model's picks replace the approach A picks only when their summed score is strictly higher, they are no more bunched, and every strong approach A pick (score ≥ 4) is still in (amended 26 Nov 2026, from a measured trial: the model was worse than approach A in ~20 of 36 answers).
- **Fallback (approach A):** if the model is unavailable, errors, or exceeds a timeout, take the top-scored candidates and fill notes from a template ("Toilets and water · km 11").
- **Ride context axis** changes the route, not the places: With kids → avoid climbs, gravel, roads; Visiting Singapore → favour iconic views and pass rental points; Keep it quiet → avoid stretches with `crowded_*` reason codes at the planned time.
- **Learning:** Stop / Skip on Kit's pass-by card and detected stops (stationary ≥ 3 min within 50 m of a pick) adjust per-category weights stored on device; the finished screen shows what Kit learned.
- **Foodie:** dish suggestion from overlay `signature_dishes`; stall only when listed; otherwise generic local dishes. Mid-ride vs post-ride and opening patterns (dinner-only, morning market) shape the suggestion.

### 3. Rest stops

- Applies to Leisure and Moderate routes of any length (revised: beginners riding 5–15 km still need water and toilets). Under 20 km, show the water and toilet stops along the route without spacing windows.
- **Spacing by level:** Beginner 5–7 km, Regular 10–15 km, Strong 15–20 km. Starts from the onboarding choice; after 5 finished rides, re-estimated from recorded distance/speed.
- **Choice by quality** within each window: water > toilet > shade/shelter > food > bike parking; repair station is a bonus. Never closed or no-cycling.
- **Gap warnings:** if the next window has no water, Kit warns at the previous stop ("No water for 8 km — fill up here").
- Shown in route detail rows, as map pins, and as a Kit `Rest stop` pass-by card (reuses the existing pass-by mechanism in `RideRecorder.checkSights`).

### 4. Scenic slider

- Leisure only, Direct ↔ Scenic, default midway. Scenic end allows up to ~+30% distance; builder shows the extra distance live.
- Implementation: A* edge cost multiplied down for PCN edges near water, parks, viewpoints and named bridges (precomputed per edge from `places.json` at graph build); slider maps to the discount strength. Respect the +30% cap by falling back to a lower discount if exceeded.

### 5. Fully offline (decided with the user, 20 Nov 2026)

Online parts found in the code and what replaces each:

| Today (online) | Where | Decision |
|---|---|---|
| Apple Maps map tiles | `Map()` everywhere | **Test first.** Build an airplane-mode check on the user's iPhone before other work. If tiles go blank offline, come back to the user (options were: bundle our own map with an open-source library, or accept an online map background). |
| BRouter `brouter.de` (start/end stitching, Fast mode, gaps) + `MKDirections` walking fallback | `PCN/BRouter.swift`, `Routing.swift` | **Bundle the road network.** A script extracts Singapore's rideable roads and paths from the same OSM extract into an offline graph; the app routes start/end legs, Fast mode and closure gaps on it with the existing A*. PCN edges stay preferred by cost. Remove the BRouter and `MKDirections` calls. |
| open-meteo elevation | `Routing.swift:114` | **Bundle heights.** The build script adds a height to every PCN and road node from free elevation data (e.g. SRTM/Copernicus 30 m); the climbs chart and difficulty read those. |
| Start/destination search `MKLocalSearch` | `RouteBuilderView.swift:324` | **Places + stations + addresses.** Search the bundled places file, MRT stations, parks, connector names, and OSM street addresses / postal codes (coverage incomplete; show "not found, drop a pin instead"). |
| Corridor POIs `MKLocalPointsOfInterestRequest`, typed taste search | `Discovery.swift` | Replaced by `places.json` (section 1). |
| Look Around | `Discovery.swift:250` | Removed (section 1). |
| PCN dataset update from GitHub | `PCNDataset.swift:24` | *My call:* remove. The URL is still a placeholder (`OWNER/REPO`) so it never worked; data updates ship with app releases. |

Foundation Models runs on device, so it is already offline. After this, the app makes no network requests; a test can assert that by running a full plan + ride with networking blocked.

### 6. Kit alarms and fall detection

**Full-screen alarms (Figma `v3 · 07–11`).** When the rider comes within ~100 m (scaled by speed) of an active hazard, a closure that the route still touches, or a `no_cycling` stretch, Kit takes over the whole screen: scrolling hazard tape, pixel rings pulsing out from Kit, Kit wobbling with a "!", the distance counting down in Jersey 10, one line of what it is and one of what to do, and two Kit buttons (e.g. "Take the detour" / "I see it, carry on"; "I'll walk my bike" / "Find a way round"). Plus a strong haptic and a short sound. Dismissing returns to navigation; each alarm fires once per approach. Obstacle alarms are ochre, no-access alarms terracotta, both with a light-mode version.

**Fall detection (my calls, open to change):**
- Runs only while a ride is being recorded, using Core Motion (accelerometer + gyroscope, ~50 Hz).
- Triggers on a hard impact (roughly > 3–4 g) together with a fast tumble, followed by ~10 s of near-stillness. Thresholds get tuned on real rides; a ponytail-style calibration constant, not a model.
- Shows **"Are you OK?"** with a 30 s countdown, haptics and a rising tone. "I'm OK" cancels; "Ring the alarm now" skips ahead.
- **Alarm:** full-screen flashing terracotta/ink "HELP!" for passers-by, with location (place, km, coordinates, time), "Hold to stop alarm", and "Call 995" (a tap, works on cell signal without internet).
- **Loud on silent:** play the alarm through an audio session in playback mode at full app volume, which ignores the silent switch. Requires adding the `audio` background mode next to the existing `location` one so it keeps ringing with the screen locked. Apple's "Critical Alerts" permission (gets past Focus / Do Not Disturb via a notification) needs Apple to approve the app; apply for it but don't depend on it.
- iPhone's own Crash Detection is for car crashes and has no app API; Apple Watch fall detection is separate. This feature is the app's own.

### 6a. No-bike ways (decided with the user, 26 Nov 2026)

Two kinds of "no cycling", treated differently:

| Kind | Examples | Routing (plans and reroutes) | Warning |
|---|---|---|---|
| **No bikes at all** (terracotta) | Expressways and their slip roads, `bicycle=no` ways, steps | **Never**: not by the road network (already true), and never by a straight fallback leg that crosses one. A reroute that would need one is not applied. | Before the ride: Kit card + "No bike path" row (Figma `v3 · 13`). Riding off route toward an expressway or no-bike entrance: full-screen alarm (`v3 · 12`). Reroute banner says why (`v3 · 14`). |
| **Walk your bike** (gold) | Henderson Waves, Punggol Waterway bridges, boardwalks (`no_cycling` in `closures.json`) | Used when sensible, plans and reroutes alike, with the small penalty from section 0 | A gold row before the ride; on the bridge, the "Walk your bike" banner and map label, moving time paused (`v3 · 16`) |

Labels use `Kit/road label` (13 kinds, three tones: terracotta = no access, gold = caution, paper = info) and the 12×12 pixel traffic icons in Figma. This change ships the four it needs (no bikes, expressway, walk your bike, closed); the rest come with the UI rework.

### 7. Review follow-ups (decided with the user, 20 Nov 2026)

**Heat and rain (offline):** a static best-time hint ("cooler before 10 am or after 5 pm; 1–4 pm is hottest and storms are common"), sheltered rest stops marked (`shelter`, `covered=yes`), and Kit suggests a shelter when the ride starts in the afternoon. No live weather.

**Tourist extras:** bundle rental shops and bicycle parking from the "Singapore bike parking and rentals" research (LTA, OSM, operator rules; ship only sources whose licence allows bundling, with attribution). Rental shops and parking can be start and end points ("return the bike here"). Add 2–3 preset iconic loops. Spell out "park connector" and "hawker centre" instead of "PC" and "HC" in rider-facing text.

**Alarms and safety UI:**
- Every obstacle/no-access alarm has a "Not there" button that silences that spot for this ride and records a false alarm. It auto-dismisses once the spot is passed.
- First warning is a sound and haptic. The full-screen takeover comes only within the last ~100 m.
- The alarm screens put distance and what it is first, with Kit smaller.
- Fall detection has a sensitivity setting (Low / Normal / High, default Normal) and can be turned off.
- The HELP screen:
  - Call 995 is the main button, with a phone icon.
  - Stopping the alarm needs a 3 s hold with a visible fill.
  - Bystander line: "Call 995. Don't move them."
  - "Help" in English, 中文, Melayu and தமிழ்.
  - Its own red/ink flash, different from no-access.

**Ride screen UI:**
- The turn arrow and distance always stay as the large top row of the banner. Kit's message sits under it, and "600 m" never wraps.
- In the ride panel, next turn and km to go come first and the timer is smaller.
- Pause and End ride sit above the home indicator. End ride needs a hold.
- All touch targets are at least 52 pt.
- Contrast is WCAG AA or better in both themes: ink text on terracotta, cream icons on dark secondary buttons.
- Map pins carry pixel icons, not colour alone.
- "Along the way" rows have chevrons and swipe to add or remove a stop.
- Dynamic Type for DM Sans body text. VoiceOver labels for icons and Kit's mood. The fall countdown is announced every 5 s.

**Later (optional):** export rides as GPX and to Apple Health.

### When things are decided (my calls)

- **Picks and rest stops** are chosen at planning time assuming the ride starts now, and refreshed when the rider taps Start ride. The quick (approach A) picks show at once; Kit's model picks replace them when ready, so the rider never waits.
- **Who gets what:** Leisure and Moderate get Kit's picks and rest stops; Fast gets neither (Fast still gets closures).
- **Saved routes** are checked against `closures.json` when opened and at ride start. If a route now crosses an active closure, Kit warns and offers to re-plan.
- **"How I'm riding today"** starts as rough adjustments from what the bundled data has: With kids avoids off-connector stretches and stretches tagged crowded/dismount; Visiting Singapore favours iconic views and rental points; Keep it quiet avoids stretches near places tagged `crowded_*` at the planned time, using a small hand-made list of busy areas and times. Per-stretch surface, elevation and live crowd data are later work.

### UI (Figma v3)

- Native: status bar, sheets, segmented controls, sliders, list rows, Apple Maps `Map()`.
- **During a ride, Kit's pass-by, closed-ahead, water and rest-stop messages appear inside the top directions banner** (`Kit/guidance banner`, Mode=Kit moment) for about 5 s with a pixel bar showing time left, then the banner returns to plain directions. No separate floating cards or notifications. Full-screen takeovers are reserved for the section 6 alarms.
- `Kit/avatar` has two moods: Happy (tips, picks) and Alarmed (warnings, closures, fall check, alarm).
- Kit alarm parts (loop on their own in prototype via Smart Animate): `Kit/alarm-pulse`, `Kit/hazard-tape`, `Kit/alarmed`, `Kit/alarm-flash`.
- Kit-themed: `Kit/bubble` (Tip / Heads-up / Rest stop / Food), `Kit/timer` (Jersey 10 numerals, pixel progress), `Kit/chart` (elevation, speed), `Kit/button` (Primary / Secondary / Destructive, Large / Medium), `Kit/icon-button` (Default / Caution), and the 12×12 pixel icon set (food, photo, water, rest, closed, heritage, architecture, wildlife, art, café, kids, tourist, quiet, bridge, plus control icons).
- Kit's cards use Kit's tokens from the Figma `UI` collection (paper, ink, sage, gold, blue, terracotta) and DM Sans; numbers in Jersey 10. These fonts must be bundled in the app.

## Left to the builder

- File formats/schemas beyond the fields listed; exact scoring weights; the model prompt wording; timeout value; how per-category weights are stored (SwiftData vs `AppStorage`).
- Edge-to-feature proximity thresholds for scenic cost; golden-hour computation.
- Geocoding the research rows (OneMap / OSM) and merging them into the overlay.
- Where the OSM attribution lives in the UI (About screen + map corner is sufficient).

## Data-quality notes to carry into the build

- Only 2 research coordinates are sourced; all others must be geocoded before shipping.
- Several conflicts are resolved in favour of dated official notices (see personas report "Data quality"); re-check NParks PCN and Rail Corridor notices before each release.
- Hawker stall-to-centre links tagged `[unverified-loc]` in research must be verified or dropped.
