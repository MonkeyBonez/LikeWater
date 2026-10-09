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

## More non-US metros

Seoul and Singapore are built (LEARNINGS §16): one `metros.yaml` entry + a build each,
~1–5 min with cached inputs. What abroad still lacks: no sidewalk surveys or canopy
(synthesis defaults), 15-min DNI is interpolated from hourly global models outside HRRR /
ICON-D2 / AROME, GOES covers the Americas only (East Asia would be Himawari).
**Next candidates:** Toronto (HRDPS 2.5 km), Tokyo. **Trigger:** owner decision.
**Before many more:** a place whose Overture heights are under ~20% known should be
spot-checked (`lwtool sun` vs. the old fill), as Seoul was.

## Narrow alleys get synthesised sidewalks (Seoul)

Seoul's villa neighbourhoods are 3–6 m shared alleys (골목) with no kerb; synthesis treats
them as streets and draws a sidewalk on each side (Mangwon: 100% synthesised). The sun on
an alley is close to the sun on its centreline, so the error is small, but the corridor
counts two "sides" and their crossings where a walker sees one lane. **Fix:** treat
`highway=service|living_street|residential` narrower than ~6 m (`width`, or no
`lanes`/`sidewalk` and a short block) as a shared lane — keep the centreline, no
synthesis, no crossings. **Trigger:** a Seoul walk where crossings or side choice feel
wrong. **Effort:** ~half a day + a `--no-sidewalk-synthesis` diff per city.

## Covered walkways are shade (Singapore)

Singapore's HDB estates and MRT approaches are threaded with covered linkways (OSM
`covered=yes` on `highway=footway`, and `building=roof` canopies). We score them as open
sky, so an estate reads sunnier than it walks (Toa Payoh 59% sunny at 09:00). **Fix:** a
`FLAG_COVERED` edge bit from `covered=yes|arcade` / `tunnel=building_passage`, scored
fully shaded; `building=roof` polygons as 3 m buildings. **Trigger:** first Singapore
walk. **Effort:** ~half a day (pipeline flag, one line in the scorer, bundle-format bit).

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

## Sun by block: sky per cell, shadows across tile borders

The zoomed-out field reads the beam once at the screen centre (9 forecast cells ≈ 7 km),
so a 40 km Bay view fades uniformly even when the fog line is inside it; and each metro
tile is scored from its own buildings only (LEARNINGS §13: 1.5 % of 70 m blocks change
band at the border). **What:** sample the forecast field per cell (needs a wider lattice
fetch — more Open-Meteo calls; the owner's rate-limit lever), and give the tile-alone
scorer a 300 m strip of the neighbours' buildings. **Trigger:** a visible fog line or seam
in the block view on a real walk. **Effort:** ½ day each.

## Route search cost per GPS fix

`makeRoute` runs three Pareto searches per fix (λ, 0 and 1 for the slider captions), each
rebuilding the corridor's local index. Measured 25 ms per search in Midtown at slack 0.3
on the Mac; ~3× on a phone. **What:** build the local index once per fix and reuse it;
recompute the λ = 0/1 captions only when the corridor's edge set changed. **Trigger:** a
visible stutter on fixes in Manhattan. **Effort:** ½ day.

## GOES cloud-top height at 2 km

`ABI-L2-ACHAC` is 10 km, so the "low vs mid/high" class is one pixel for ~16 lattice cells
and `top is None` with a liquid phase reads as mid/high. The 2 km `ACHA2KC` product isn't
on the public bucket today; check again before the build-out, else derive "low" from the
11 µm brightness temperature in `CMIPC` C14 (fog is warm). **Trigger:** the POC verdict.
