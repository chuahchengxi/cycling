# Phase 2 — Hybrid Strict-PCN Routing — Design

Date: 2026-09-04
Status: design (not yet planned into tasks; not built)
Builds on: the Phase 1 seam (`Route.mode`, `Routing.plan(through:mode:)`) already shipped.

## Goal

Make leisure and moderate routes **stick to Singapore's Park Connector Network
(PCN)** — the dedicated off-road cycling/walking paths — as strictly as the data
allows, connecting only the unavoidable gaps by road. **Fast** mode drops the
constraint and takes the quickest cycling route, roads included (faster, riskier).

Decided direction (from the user): **bundle the official PCN dataset AND use a
hosted cycling router**, with the PCN dataset **refreshed periodically** so riders
stay current as new connectors open.

## Why Phase 1's engine can't do this

MapKit has no cycling engine. Today `Routing.plan` uses MapKit `.walking`, which
*often* uses connectors but never *guarantees* the PCN and gives no control per
mode. "Strictly follow the PCN" requires two things MapKit does not provide:
1. the PCN geometry as a **routable graph**, and
2. a **pathfinding algorithm** that is constrained to that graph.

Everything below is behind the existing `Routing.plan(through:mode:)` signature —
the Phase 1 UI, the wizard, and `Route.mode` do not change.

## The five components

### 1. PCN dataset — the map of connectors
- **Source:** NParks/LTA publish the PCN as GeoJSON (LineString features, each a
  connector segment) on data.gov.sg. *(Open item: confirm the exact dataset ID +
  the Singapore Open Data Licence attribution requirement before shipping.)*
- **Bundle a seed copy** in the app (`pcn-seed.geojson`) so routing works offline
  on first launch with no network.
- **Versioned:** a small `pcn-manifest.json` carries `{version, url, sha256}`.

### 2. Graph builder — turn lines into a network
Parse the LineStrings into a weighted graph:
- **Nodes** = connector vertices; **edges** = the segment between two consecutive
  vertices; **edge weight** = segment length in metres (from `Geo.distance`, which
  Phase 1 already has).
- **Junctions:** where two connectors share (or nearly share) a coordinate, the
  nodes are merged so the router can hop between connectors.
- **Snap tolerance** (the calibration knob): real GIS data has small coordinate
  mismatches at junctions. Connectors within ~3–8 m are joined; too small leaves a
  disconnected graph, too large invents false shortcuts. *Must be tuned against the
  real dataset — leave it a named constant, not a magic number.*
- **Spatial index** (a simple lat/lon grid) for fast "nearest PCN node/edge to a
  coordinate" lookups.
- Built once per dataset version and cached; rebuilt only when the dataset updates.

### 3. Router — find the on-PCN path
- Snap each waypoint (start, end, any intermediate) to its nearest PCN node/edge.
- Between consecutive snapped points, run **A\*** (Dijkstra with a straight-line
  distance heuristic) over the PCN graph → shortest path that **stays on the PCN**.
- Singapore's PCN is a few thousand nodes; A\* on-device is well within budget
  (milliseconds). Reuses the same `RoutePlan`/`StoredStep` output shape as today,
  so elevation, the turn list, difficulty, and the map all keep working unchanged.

### 4. Gap stitching + first/last mile — the hosted router
The rider's real start (home) and end are usually **not on** a connector, and the
PCN itself has gaps where a short road link is unavoidable. For those connective
bits only:
- Call a **hosted OSM cycling router** (e.g. BRouter — free/open — or GraphHopper's
  free tier) to route start→nearest-PCN-entry and PCN-exit→destination, and across
  any interior gaps.
- **Offline fallback:** if the hosted router is unreachable, fall back to MapKit
  `.walking` for the gap (today's behaviour) so a route always returns.
- Final route = `[road: start → PCN entry] + [strict PCN path] + [road: PCN exit →
  destination]`, stitched into one polyline.
*(Open item: pick the hosted router and confirm its ToS/rate limits/attribution.)*

### 5. Mode behaviour (what `plan(mode:)` branches on)
- **Leisure / Moderate:** maximise PCN usage (component 3), stitch gaps minimally
  (component 4). Leisure can additionally weight toward scenic connectors and folds
  in the Phase 1 discovery waypoints.
- **Fast:** skip the PCN graph entirely — one call to the hosted router with a
  "fastest" bike profile that allows roads. Faster, more exposed to traffic.

## Periodic dataset updates (the "keep to date" requirement)
- On launch, **throttled** (e.g. at most once/week), fetch the small
  `pcn-manifest.json`.
- If its `version` is newer than the cached one, download the new GeoJSON, verify
  the `sha256`, write it to the app-support directory, and rebuild the graph.
- Riders always route on the latest connectors (Singapore opens new PCN links
  regularly) without an app-store update.
- *(Open item: where the manifest+data are hosted, and the exact cadence.)*

## Integration — nothing in Phase 1 changes
```
Routing.plan(through: waypoints, mode: mode) →
    mode == .fast     → hostedRouter.fastRoute(waypoints)         // roads allowed
    else              → pcnRoute(waypoints)                        // strict PCN
                          = stitch( hostedRouter.gap(...),
                                    pcnGraph.aStar(...),
                                    hostedRouter.gap(...) )
```
The builder, wizard, `Route.mode`, difficulty, elevation, and turn-by-turn all
consume `RoutePlan` exactly as they do now.

## Risks & calibration knobs (real-world tuning a minimal model can't see)
- **Junction snap tolerance** — tune against the real dataset; disconnected graph
  vs. false shortcuts.
- **Hosted-router dependency** — network, ToS, rate limits; the offline MapKit
  fallback is mandatory, not optional.
- **Dataset licence** — Singapore Open Data Licence attribution.
- **PCN coverage** — the network doesn't reach everywhere; the honest UX is "as
  much PCN as exists between these points," not "100% PCN always."

## Open items to settle before this becomes a task plan
1. Exact data.gov.sg PCN dataset ID + licence/attribution.
2. Hosted cycling router choice (BRouter vs GraphHopper vs other) + ToS.
3. Update host + cadence for the manifest/dataset.
4. Leisure scenic-weighting: in scope, or a later refinement?
5. Offline behaviour spec when both the hosted router AND a cached dataset are
   unavailable.

## Suggested build order (when this is planned into tasks)
1. GeoJSON parser + graph builder + spatial index + `selfCheck` on a tiny fixture.
2. On-device A\* router over the graph + `selfCheck` (known shortest path).
3. Snap-to-PCN + the stitch assembly (hosted-router calls stubbed) + fallback.
4. Hosted-router client (fast profile + gap routing) + offline fallback.
5. `plan(mode:)` branching wired to the above; verify Phase-1 output shape intact.
6. Dataset bundle + manifest fetch + versioned cache + graph rebuild on update.
