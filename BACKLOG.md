# Backlog

Things we have decided to do later, with enough context to pick them up cold.
Newest at the bottom. Move an item to `LEARNINGS.md` when it is done and taught us something.

## Fog from satellite, not forecast — GOES job build-out (POC running)

**Status:** the proof of concept is built and logging (`Pipeline/goes_poc.py`,
`goes_log.py` every 15 min via `Pipeline/launchd/com.likewater.goes-log.plist`,
`goes_report.py`; LEARNINGS §9.6). Build the job only if, after ≥ 10 days of daytime
logs, GOES is right in ≥ 70 % of its disagreements with the forecast at SFO/OAK and the
median latency is ≤ 15 min (`goes_report.py` prints the decision).

**What the build-out is:** a scheduled job (GitHub Actions cron at 30 min fits the free
2,000 min/month; a 10-min cadence needs the Mac or a €4 VPS) runs `goes_poc.observe()` and
writes `sky/goes/<city>.json` (the `--json` output) next to the tiles on the static host;
`WeatherService` gains a `SkySource.observed` that wins for |now − t| ≤ 20 min, HRRR keeps
scrubbed future times; Sun Map's status says "Fog (satellite, 9:50)". The JSON is
documented in README as a public, best-effort endpoint (attribution, no uptime promise).

**Trigger:** the POC verdict. **Effort:** 1 day after the verdict.

## Tree canopy

Moorpark's dominant midday error is trees, not houses or hills (LEARNINGS §3.7). NLCD
Tree Canopy Cover (30 m, US-only) as a per-edge shade factor is the cheap first step;
LiDAR-derived canopy height where a city publishes it is the real one.

## Corridor should not route through private tracts

`access=private` streets are in the graph and flagged (LEARNINGS §3.5) so they render in
Sun Map, but the corridor engine still treats them as walkable. Penalise or exclude
`EdgeFlag.privateAccess` in `CorridorEngine` unless the user's start or destination is
inside the tract.

## Go live on Cloudflare (owner's step; everything is ready)

`publish.py --target pages` after `npx wrangler login`; the Worker (`Worker/`) after creating
its KV namespace; then build the apps with `LW_BUNDLE_BASE_URL` (and
`LW_COVERAGE_REQUEST_URL`). README "Hosting" has the commands; all of it is tested locally.
**Trigger:** the owner wants a second phone (or a tester) to download tiles.

## Open-Meteo proxy before scale

**Status:** written and off — the Worker's `/sky` (15-min shared cache, optional paid key)
answers 404 until `SKY_PROXY=on`. The apps still call Open-Meteo directly; switching them
to the proxy is a `WeatherService` URL change.

Nine points per request against the 10k-points/day free tier is ~1,100 requests/day: fine
for one user, not for a thousand. A caching proxy (one fetch per lattice cell per 30 min,
shared by everyone) or a paid key is needed before any public release.

## Apple `MKDirections` as a yardstick and no-tiles fallback

**Why parked:** the owner chose ours-only pathfinding (PLAN.md standing decisions). Apple
would give an independent distance/ETA check and a walking route in unbuilt places (no
sun), free and on-device, but no via points (it can't follow our route) and undocumented
throttling. **Trigger:** users stuck in unbuilt places, or disputes about our ETA.
**Effort:** ~1 day (AppleDirections wrapper, dashed overlay, debug comparison line).

## Non-US metros

Nothing is US-bound (PLAN.md §1.7.10): terrain abroad is ~30 m, no sidewalk surveys or
canopy (synthesis defaults), 15-min DNI only from HRRR (N. America) and ICON-D2/AROME
(central Europe), GOES covers the Americas only. **First candidate:** Toronto (HRDPS
2.5 km). **Trigger:** owner decision. **Effort:** one `metros.yaml` entry + a build.

## Scheduled rebuilds for freshness

OSM changes daily, Overture monthly. Pinned builds (`buildKey`) make a rebuild safe to roll
out. **Trigger:** a user-reported stale street. **Effort:** a cron entry over
`build_places.py --rebuild`.

## Fully automatic build-on-request

Today a human approves each `metros.yaml` entry produced by `requests_to_places.py`.
**Trigger:** the wish-list outgrows nightly review. **Effort:** ~1 day (thresholds,
Nominatim → place, auto-append, budget guard).

## Stable node ids (bundle v4)

Node ids are row numbers of one build, so tiles from two builds can't be mixed (C5 pins
builds instead). Stable ids (hash of rounded coordinates + way id) would allow per-tile
incremental rebuilds. **Trigger:** rebuild time or download size becomes the problem.

## Signalised vs unsignalised crossing waits

The pace model waits 12 s at every crossing edge. OSM `crossing=traffic_signals` vs
`uncontrolled/marked` would let signalised crossings cost ~30 s and zebras ~5 s.
**Trigger:** ETA error correlates with crossing count (PLAN Part 3 #9). **Effort:** a
pipeline flag + one line in `PaceModel`.

## Route UI extras

Pareto tick marks / a 3-stop picker if measured Pareto sets are tiny (Part 3 #2); turn
hints along the route. **Trigger:** owner feedback from real walks.

## Valhalla for routing in unbuilt areas

Open-source OSM pedestrian router (self-hosted, or Stadia's free non-commercial tier):
via points, tunable costing. The backend to use if we ever route where we have no tiles.

## GPS map-matching to the sidewalk side

GPS is ±20–50 m downtown; an on-phone HMM over our graph would say which sidewalk the
walker is on. Not needed for the corridor; would sharpen "you're on the sunny side".
