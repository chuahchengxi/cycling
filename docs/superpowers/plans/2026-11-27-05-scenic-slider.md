# Scenic Slider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Leisure riders bend their route toward water, parks, viewpoints and named bridges with a Direct ↔ Scenic slider, never more than about 30 % longer than the direct route, and see the extra distance live.

**Architecture:**
- Once per launch, off the main actor, mark the PCN nodes within 50 m of a scenic place from `places.json` (cached next to the PCN graph).
- `PCNGraph.scenic(_:strength:)` discounts edges between two scenic nodes; A* scales its heuristic so it stays admissible.
- `PCNRouting.stitched` already tries a list of graphs under the +30 % cap (`maxDetourRatio`); the scenic graph goes first, then a half-strength one, then today's graphs, so the cap is kept by falling back to a lower discount.

**Tech Stack:** Swift / SwiftUI / SwiftData, iOS 18+, assert-based `selfCheck()`s at launch in DEBUG (`zsh .superpowers/sdd/fix/run.sh` prints LAUNCH CLEAN).

**Spec:** `docs/superpowers/specs/2026-11-20-kit-personalised-places-design.md`, section 4.

## Global Constraints

- Leisure only. Direct ↔ Scenic, default midway. Scenic end allows up to ~+30 % distance (`PCNGraph.maxDetourRatio = 1.3`); the builder shows the extra distance live.
- A* edge cost multiplied down for PCN edges near water, parks, viewpoints and named bridges, precomputed from `places.json`; the slider maps to the discount strength; respect the +30 % cap by falling back to a lower discount.
- Closures and walk-your-bike penalties still apply on top; a scenic bend never routes through an active closure.
- Fully offline; heavy work `nonisolated` in `Task.detached`. Native iOS `Slider`.

## Review Focus

1. **Slider at Direct (0)** gives exactly today's route. (Task 2 test.)
2. **No scenery near the line:** the scenic route equals the direct one; extra distance "+0.0 km" is hidden, not shown. (Tasks 2, 3.)
3. **Scenic stretch inside a closure:** closure cost still wins; the route goes round. (Task 2 test.)
4. **Dragging the slider quickly:** only the last value's plan is applied (stale plans dropped). (Task 3.)
5. **Old saved routes** without the field decode as midway for Leisure. (Task 3 test.)

---

### Task 1: Scenic nodes and the discounted graph

**Files:**
- Modify: `cyclingskibidi/Routing/PCN/PCNGraph.swift` (`scenic(_:strength:)`, `heuristicScale`)
- Modify: `cyclingskibidi/Routing/PCN/PCNGraph+AStar.swift` (heuristic × `heuristicScale`)
- Modify: `cyclingskibidi/Routing/PCN/PCNDataset.swift` (`static func scenicNodes() async -> Set<GridKey>`, cached)

**Interfaces:**
- Produces:
  - `static let scenicCategories: Set<String> = ["waterway", "reservoir", "park", "nationalPark", "beach", "viewpoint", "bridge"]` (on `PCNGraph`)
  - `static let scenicRadius: Double = 50`, `static let maxScenicDiscount: Double = 0.5`
  - `func scenicNodes(near places: [Sight], facts: [String: PlaceFacts]) -> Set<GridKey>` — a node is scenic when within `scenicRadius` of a scenic place's pin or any point of its outline (`facts[osmID]?.shape`); bucket the points in a ~50 m grid so this is one pass over nodes.
  - `func scenic(_ nodes: Set<GridKey>, strength: Double) -> PCNGraph` — `strength` clamped 0…1; edges with both ends in `nodes` get weight × `(1 − maxScenicDiscount × strength)`; returns `self` when strength is 0 or nodes empty; sets `heuristicScale = 1 − maxScenicDiscount × strength`.
  - `var heuristicScale: Double = 1` used by A*'s `Geo.distance(...)` terms (push and lazy-deletion check alike).
  - `PCNDataset.scenicNodes()` computes once from `PCNDataset.graph()` and `Discovery.places/facts` in `Task.detached` and caches.

- [ ] **Step 1: Write the failing test** in `PCNGraph.selfCheckAStar()`: a toy square A→B two ways, the north side 10 % longer and all scenic. `strength 0` → south; `strength 1` → north (cost 1.1 × 0.5 < 1); `scenic([], strength: 1)` → south; `heuristicScale` is 0.5 at strength 1 and 1 at 0. `scenicNodes(near:)` with a toy park 30 m from one node and 80 m from another marks only the first; a river Sight whose pin is far but whose `shape` passes 20 m from a node marks it.
- [ ] **Step 2: Run** the launch check. **Expected:** BUILD FAILED.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** it. **Expected:** LAUNCH CLEAN, and no slower launch (the cache is lazy).
- [ ] **Step 5: Commit** `feat(routing): scenic nodes and discounted connector graph`.

### Task 2: Plans bend toward scenery within the cap

**Files:**
- Modify: `cyclingskibidi/Routing/PCN/PCNRouting.swift` (`fallback: PCNGraph?` → `fallbacks: [PCNGraph] = []`, tried in order after `graph`)
- Modify: `cyclingskibidi/Routing/Routing.swift` (`plan(... scenic: Double = 0)`)

**Interfaces:**
- Consumes: Task 1.
- Produces: `Routing.plan(through:mode:closures:context:start:scenic:)`; `scenic` is ignored unless `mode == .leisure`.
  - Graph order passed to `stitched`: `penalised(closed, walk, avoid).scenic(nodes, s)`, then `….scenic(nodes, s / 2)`, then `penalised(closed, walk, avoid)`, then (if avoid non-empty) `penalised(closed, walk)`. Duplicates (s == 0) are skipped.
  - Existing callers that passed `fallback:` move to `fallbacks: [x]`.

- [ ] **Step 1: Write the failing tests** in `PCNRouting.selfCheck()` on fixtures:
  - The square from Task 1 through `stitched`: scenic graph first → north side.
  - A scenic loop 1.6 × the direct length: the first graph's path breaks the cap, the half-strength one too, so the direct path is used (cap respected).
  - A scenic side inside an active closure circle: route avoids it.
  - Existing tests for `fallback` still pass with `fallbacks: [x]`.
- [ ] **Step 2: Run** the launch check. **Expected:** BUILD FAILED.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** it. **Expected:** LAUNCH CLEAN. On the real graph, a Leisure plan along the Kallang River at scenic 1 is no longer than 1.3 × scenic 0 (DEBUG print, then remove).
- [ ] **Step 5: Commit** `feat(routing): leisure plans bend toward scenery within +30%`.

### Task 3: The slider

**Files:**
- Modify: `cyclingskibidi/Models/Models.swift` (`Route.scenicRaw: Double?`, `var scenic: Double { scenicRaw ?? 0.5 }`)
- Modify: `cyclingskibidi/Features/Routes/RouteBuilderView.swift` (slider under the mode picker, Leisure only)
- Modify: `cyclingskibidi/Features/Routes/RouteDetailView.swift` (re-plans pass `route.scenic`)

**Interfaces:**
- Consumes: `Routing.plan(... scenic:)`.
- Produces: `Route.scenic`.

- [ ] **Step 1: Write the failing test** in `Route.selfCheck()`: a new Route has `scenic == 0.5`; set 0.2, read 0.2. Add `static func extraLabel(scenic: Double, direct: Double) -> String?` on `RouteBuilderView` (or a small nonisolated helper beside it): nil when the difference < 50 m, else "+1.2 km"; test both.
- [ ] **Step 2: Run** the launch check. **Expected:** BUILD FAILED.
- [ ] **Step 3: Implement.**
  - Native `Slider(value:in: 0...1)` with "Direct" and "Scenic" labels at its ends, default 0.5, Leisure only (hidden for other modes).
  - Re-plan on release (`onEditingChanged` false), keep a request token so only the last result applies. Plan the direct route once per waypoint change and cache its distance; show `extraLabel` beside the slider.
  - Every re-plan of a saved route (detail screen, Start ride re-check) passes `route.scenic`.
- [ ] **Step 4: Run** it. **Expected:** LAUNCH CLEAN. In the simulator, a Leisure route along a river grows by a few hundred metres at Scenic and the label updates.
- [ ] **Step 5: Commit** `feat(routes): Direct ↔ Scenic slider for leisure`. Update the spec status line to add "section 4 (plan 5)", commit `docs(kit): plan 5 built`.

## Decisions this plan makes

- **Scenic = near a scenic place, both ends of the edge.** Per-edge precompute from places.json without a new build script; outlines make rivers and parks count along their length.
- **Discount, not bonus:** max 50 % off at Scenic, so a scenic edge costs at least half its length; A*'s heuristic is scaled to stay admissible.
- **The cap reuses `stitched`'s try-in-order logic** instead of a second loop.
