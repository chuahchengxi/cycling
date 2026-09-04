# Phase 2 — Hybrid Strict-PCN Routing — Design

Date: 2026-09-04
Status: design — all open items resolved 2026-09-04 (BRouter · scenic deferred · self-hosted updates); ready for an implementation plan; not yet built.
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
- **Source (confirmed):** NParks "Park Connector Loop" on data.gov.sg, dataset
  `d_a69ef89737379f231d2ae93fd1c5707f` — a GeoJSON `FeatureCollection` of
  `LineString` connector alignments. Licence: **Singapore Open Data Licence**
  (free for personal/commercial use; carry the NParks attribution string in an
  in-app credits line). *(Access Points + NParks Tracks datasets exist too and can
  supplement junction/entry data later — not needed for v1.)*
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

### 4. Gap stitching + first/last mile — the hosted router (BRouter, confirmed)
The rider's real start (home) and end are usually **not on** a connector, and the
PCN itself has gaps where a short road link is unavoidable. For those connective
bits only:
- Call **BRouter** (free, open-source, cycling-tuned) to route
  start→nearest-PCN-entry and PCN-exit→destination, and across any interior gaps.
  REST shape: `GET {host}/brouter?lonlats={lon,lat|lon,lat|…}&profile={p}&format=geojson`
  → a GeoJSON `LineString` we convert to `[Coord]` (the same shape the graph router
  emits, so stitching is uniform).
- **Host:** start against the public instance `https://brouter.de/brouter`
  (best-effort, no SLA) behind a named `BRouterConfig.baseURL` constant, so swapping
  to a self-hosted instance later is a one-line change, not a code change. Profiles:
  a **path-favouring** profile (`trekking`, which prefers footpaths/pavements/quiet
  ways over roads) for gap/leisure links, `fastbike` for fast mode — both named in
  `BRouterConfig` so the routing knobs live in one place.
- **Gaps prefer walkable paths, roads only when forced.** The gap profile is tuned
  to take footpaths/pavements over roads wherever one exists; an actual road segment
  appears only when there is no path alternative between two connector points.
- **Road transparency + redirect (decided).** Any stitched segment that leaves the
  PCN onto a road is tagged (`StoredStep.offConnector = true`) and drawn distinctly
  in the preview, with a one-line summary (e.g. "1.2 km off-connector"). The rider
  can **reject** the route, or **redirect** it by dropping/moving a waypoint — the
  Phase 1 builder already re-plans on every waypoint edit, so "redirect" reuses that
  mechanism, no new interaction to build. Nothing is hidden.
- **Offline fallback:** if BRouter is unreachable, fall back to MapKit `.walking`
  for the gap (today's behaviour) so a route always returns.
- Final route = `[walkable/road: start → PCN entry] + [strict PCN path] +
  [walkable/road: PCN exit → destination]`, stitched into one polyline.

### 5. Mode behaviour (what `plan(mode:)` branches on)
- **Leisure / Moderate:** maximise PCN usage (component 3), stitch gaps minimally
  (component 4), and fold in the Phase 1 discovery waypoints as intermediate snap
  targets. *Scenic connector weighting is **deferred** — v1 weights every connector
  edge by length only; a `sceneryFactor` edge-weight multiplier is the named upgrade
  seam for when it's built.*
- **Fast:** skip the PCN graph entirely — one BRouter call with the `fastbike`
  profile that allows roads. Faster, more exposed to traffic.

## Periodic dataset updates (the "keep to date" requirement)
- **Hosting (confirmed):** you self-host `pcn-manifest.json` + the versioned GeoJSON
  on a static host (a GitHub repo/release is the zero-cost default) — full control
  over when riders get a refresh, independent of data.gov.sg API changes. Refreshing
  = re-export from data.gov.sg, bump `version`, upload. No app release needed.
- On launch, **throttled** (at most once/week), fetch the small `pcn-manifest.json`.
- If its `version` is newer than the cached one, download the new GeoJSON, verify
  the `sha256`, write it to the app-support directory, and rebuild the graph.
- Riders always route on the latest connectors (Singapore opens new PCN links
  regularly) without an app-store update.

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
- **PCN coverage** — the network doesn't reach everywhere. Handling (decided): gaps
  prefer **walkable paths** over roads; any unavoidable road segment is **flagged**
  in the preview and the rider can **reject or redirect** (waypoint) around it.
  Honest UX is "as much PCN as exists, walkable paths for the rest, roads only when
  forced — always visible," not "100% PCN always."

## Open items — all resolved (2026-09-04)
1. **PCN dataset:** ✅ data.gov.sg `d_a69ef89737379f231d2ae93fd1c5707f` ("Park
   Connector Loop"), GeoJSON LineStrings, Singapore Open Data Licence (attribution
   in-app).
2. **Hosted router:** ✅ **BRouter** — public `brouter.de` to start, behind a
   swappable `BRouterConfig.baseURL`; `trekking`/`fastbike` profiles.
3. **Update host + cadence:** ✅ self-hosted manifest+GeoJSON (GitHub); throttled
   check ≤ once/week.
4. **Leisure scenic-weighting:** ✅ **deferred** (length-only edges in v1;
   `sceneryFactor` seam noted).
5. **Offline (both router AND cached dataset unavailable):** ✅ the bundled
   `pcn-seed.geojson` guarantees a dataset is *always* present, so the only real
   offline gap is BRouter — which already falls back to MapKit `.walking`. If even
   that fails, surface "couldn't build a route — check your connection," never a
   crash or an empty route.

## Suggested build order (when this is planned into tasks)
1. GeoJSON parser + graph builder + spatial index + `selfCheck` on a tiny fixture.
2. On-device A\* router over the graph + `selfCheck` (known shortest path).
3. Snap-to-PCN + the stitch assembly (hosted-router calls stubbed) + fallback.
4. Hosted-router client (fast profile + gap routing) + offline fallback.
5. `plan(mode:)` branching wired to the above; verify Phase-1 output shape intact.
6. Dataset bundle + manifest fetch + versioned cache + graph rebuild on update.
