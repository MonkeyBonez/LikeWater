# Like Water

An iOS walking app that paints the **corridor** — every street you can take to your
destination without meaningfully losing distance — and colours it with one of three
layers: **Crossings**, **Interest**, or **Sun**. It never picks a route.

Built against `Like Water — PRD updated.md` (23 Sep 2026). Two app targets share one
engine and one bundled city:

| Target | What it is |
|---|---|
| `SunMap` | The PRD's MVP, built first. No destination, no corridor — just the sidewalks around you coloured by sun, with a time scrubber and the live sky (Open-Meteo) fading the palette as cloud takes the beam away. Its only job is to prove the sun model against reality. |
| `LikeWater` | The full app: search, corridor, three layers, slack setting, arrival. Before a destination is set, the map shows the sun around wherever you are looking. |

## Running it

```bash
# once: build the San Francisco bundle (~7 min, downloads from Overpass)
cd Pipeline && python3 -m venv .venv && .venv/bin/pip install osmnx pvlib folium
.venv/bin/python build_bundle.py "San Francisco, California" -o ../Resources/sanfrancisco.lwbundle

xcodegen generate
open LikeWater.xcodeproj          # schemes: LikeWater, SunMap
```

Tests — 93 across four suites (54 engine, 26 UI, 13 pipeline). The metro tests need
`Server/` built and, for UI tests, `cd Server && python3 -m http.server 8765`:

```bash
cd Engine && swift test                                     # 53 engine tests, no simulator needed
cd Pipeline && .venv/bin/python -m pytest tests -q          # 13 pipeline tests
xcodebuild -project LikeWater.xcodeproj -scheme SunMap    -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test    # 10 UI tests (4 need the server)
xcodebuild -project LikeWater.xcodeproj -scheme LikeWater -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test    # 11 UI tests (2 need the server)
```

On a device: the project signs with team `FMDJTXM4W7`; `xcodebuild -destination 'id=<udid>'`
then `xcrun devicectl device install app --device <udid> <path>.app`.

Both apps pick the bundle covering the user's location. Shipped cities are found in the
app bundle; other cities are fetched on demand from a bundle server, which is nothing
more than the pipeline's output folder served over HTTP:

```bash
cd Server && python3 -m http.server 8765     # serves manifest.json + *.lwbundle
# app: -bundleBaseURL http://<host>:8765/   (or the LWBundleBaseURL Info.plist key)
```

`manifest.json` (written by the pipeline) lists each city's bounding box and size; the
app reads it only when the user is somewhere no local bundle covers, downloads that one
file into Application Support, and uses it from then on. Nowhere with data at all: both
apps fall back to a SoMa demo position and say so.

## Big cities: tiled metros

New York, Los Angeles and Seattle are too big for one file (New York alone is 1.77M
buildings and 1.34M graph nodes). `Pipeline/build_metro.py` builds each once, as one graph
read from a Geofabrik state extract (Overpass cannot serve a city this size), and cuts it
into ~4 km tiles that carry metro-wide node ids. The apps download only the tiles within
2.5 km of what you are looking at — or of your whole walk — and stitch them into one
graph in ~20 ms. See `LEARNINGS.md` §10 for what that took.

```bash
cd Pipeline
mkdir -p cache/pbf && cd cache/pbf && for f in new-york washington california/socal; do
  curl -LO https://download.geofabrik.de/north-america/us/$f-latest.osm.pbf; done; cd ../..
# surveys (optional, used when present): data/nyc_planimetrics_sidewalk.gpkg (NYC Open Data
# 52n9-sdep), data/seattle_sdot_sidewalks.gpkg (SDOT "Sidewalks (Active)")
./build_metros.sh            # or: ./build_metros.sh nyc   → ../Server/<id>/
cd ../Server && python3 -m http.server 8765    # app: -bundleBaseURL http://<host>:8765/
```

| | Seattle | New York | Los Angeles |
|---|---|---|---|
| Tiles / total | 31 / 64 MB | 76 / 175 MB | 109 / 290 MB |
| First view downtown (4 tiles + far terrain) | 12.7 MB | 11.8 MB | 19.7 MB |
| Sidewalk survey | SDOT lines | Planimetrics polygons | none (defaults) |
| Time zone shown | Pacific | Eastern | Pacific |

`Server/manifest.json` gains a `metros` entry per city, pointing at `<id>/metro.json`
(tile index, time zone, demo point, build stats). Tiles are bundle format version 3:
version 2 plus a per-node global id. A phone without a server can be given a metro
directly: copy `Server/<id>/` into the app's `Library/Application Support/Cities/<id>/`
(`xcrun devicectl device copy to --domain-type appDataContainer …`).

## Coverage, builds and eviction

- **Which place**: the box spanned by the screen's corners (or a walk's two ends) picks the
  place most of it falls in; a field is `covered` or `partial`; nothing built → a banner
  ("No sun data here yet", nearest built place, sky kept) and, when `LWCoverageRequestURL`
  is set, "Request this area".
- **Builds**: `metro.json` and the manifest carry `built`; server builds land in
  `Cities/<id>/<buildKey>/`, sideloads in `Cities/<id>/`. A new build serves after its first
  successful stitch (`.ready`); then older copies are deleted. Never downgraded.
- **Cache**: `Cities/ledger.json`, LRU, 400 MB (`-uiTestCacheCapMB`), only when a server
  can give files back; the ring around each stitch is prefetched on Wi-Fi.
- **Config**: `LW_BUNDLE_BASE_URL` / `LW_COVERAGE_REQUEST_URL` build settings → Info.plist
  `LWBundleBaseURL` / `LWCoverageRequestURL` (empty = unset). `-bundleBaseURL` and
  `-coverageRequestURL` override them at launch.

## The route

Inside the corridor Like Water suggests one route (PLAN.md §1.3–1.5, LEARNINGS §11):
- **Cost** of an edge entered τ s after departure: `seconds · (1 − 0.9·λ·sun(edge, slot(τ)))`
  for sidewalks, full seconds for crossings; λ is the Fastest ↔ Sunniest slider.
- **Bound**: Pareto-label Dijkstra over corridor edges, pruned by `metres + dTo ≤ D·(1+slack)`
  — the route never leaves the corridor or its slack.
- **Time of arrival**: sun is scored per 15-minute slot of the clock, only for the slots a
  walker could be on each edge (`SunTimeline`), cached across fixes; the beam per slot comes
  from the sky along the walk.
- **ETA**: `PaceModel` — pace (Relaxed/Normal/Brisk), Tobler slope from terrain, 12 s per
  crossing, stairs 0.6×; `PaceEstimator` learns the walker's pace from real walks.
- **Hysteresis**: the route being walked is kept while within 5 % of the new optimum.

```sh
Engine/.build/release/lwtool route --metro Server/nyc --from 40.7580,-73.9855 --to 40.7359,-73.9911 \
  --at 2026-09-23T17:00:00Z --sun-weight 1 --compare --ladder --walk --out route.geojson
```

## Satellite fog (proof of concept)

The sky layer is a forecast (HRRR via Open-Meteo). Whether observing the fog from GOES-West
beats it is being measured before anything is built (PLAN.md §2 E, LEARNINGS §9.6):

```sh
cd Pipeline
.venv/bin/pip install xarray netCDF4 pyyaml   # once
.venv/bin/python goes_poc.py                  # latest scan → per-cell clear/low/mid_high + beam
.venv/bin/python goes_log.py                  # one log row (GOES + Open-Meteo + SFO/OAK METAR)
.venv/bin/python goes_report.py               # after ≥ 10 days: agreement, who's right, decision
```

`Pipeline/launchd/com.likewater.goes-log.plist` runs the logger every 15 min (installed on
the owner's Mac; it only logs while the Mac is awake). Logs: `Pipeline/cache/goes_log/`.

## The bundle

`Pipeline/build_bundle.py` takes a place name — nothing in it is specific to one city —
and writes a single binary file (`Pipeline/bundle_format.py`, version 2). San Francisco:

| | |
|---|---|
| Nodes / edges | 266,222 / 335,871 undirected |
| Sidewalk edges | 152,442 — 51,246 drawn in OSM, **101,196 synthesised** |
| Crossings | 49,377 (30,573 OSM + 18,804 synthesised at intersections) |
| Buildings | 164,080 footprints from **Overture** (96% with a height; 8% USGS Lidar-measured) |
| Terrain | 10 m grid, 1,166 × 1,327 cells, from AWS Terrain Tiles |
| **Size** | **29.7 MB** (target 40) · loads in ~800 ms, once, off the main actor |

### Where the data comes from, and what was checked

| Source | Verdict |
|---|---|
| **OpenStreetMap** (osmnx) | The walking graph. Per-side sidewalks exist for only 24% of SF edges. |
| **DataSF Sidewalk Widths (2014)** | 16,174 street segments from an AECOM survey: which streets have sidewalks (26% have none), on which side, and how wide (median 12 ft). Joins to OSM streets at a **median 1 m**; 87% of SoMa street segments match. Used for presence and widths. |
| **Overture Maps — buildings** | 164k SF footprints, **96% with height** vs OSM's 71%, merging OSM, USGS Lidar and Microsoft ML. Adopted. |
| **Overture Maps — transportation** | 2,714 of 2,728 SoMa segments are OSM-sourced; the sidewalk count is identical to OSM's; **0% of roads carry a width**. Nothing to gain. |
| **AWS Terrain Tiles** | Free, no key, 7.6 m/px. Checked against known SF elevations (Nob Hill 100.6 m, Ferry Building 2.5 m). Adopted; USGS 3DEP 1 m exists but is overkill for shadows. |
| **OpenSidewalks / Tile2Net** | No San Francisco data (Seattle; Boston, NYC, DC). |
| **osm2streets, sidewalkify** | Rust with unpublished Python bindings; a 2018 package pinned to old GeoPandas. Wrote the synthesis instead. |
| **Apple MapKit** | Draws sidewalks and 3D buildings in SF but exposes none of it: no elevation, height, or sidewalk API. |
| **Google Elevation API** | Works, paid; the free terrain tiles are equivalent. |
| **Google Solar API** | Returns a DSM and *hourly shade rasters* — Google has precomputed what this app computes — but per paid call over a ~100 m radius. Not a data source; a possible validation oracle. |

### Sidewalk synthesis (`Pipeline/sidewalks.py`)

For every street that DataSF says has a sidewalk (or that OSM does not mark `sidewalk=no`),
offset the centreline to each kerb by half the roadway width plus half the surveyed
sidewalk width, join consecutive offsets into corner nodes (standard polyline offsetting),
add a crossing across each street at every intersection, and link the centreline node to
its corners wherever something else attaches there so nothing is stranded. Sides that OSM
already drew are left alone; once both kerbs have a sidewalk the centreline is removed.

Roadway widths come from DataSF's Better Streets class (Downtown Commercial 18 m …
Alley 6 m) or OSM's `lanes`; only 1% of SF streets carry an OSM `width` tag, so a
per-class default is unavoidable. For shadows it barely matters — shadow reach is tens
of metres, a kerb 2 m off is noise.

Measured effect, length-weighted, as the share of kerb-metres that have their own
sidewalk edge (`lwtool coverage`):

| Area | OSM as-is | After synthesis |
|---|---|---|
| SoMa (3rd & Howard) | 57% | **74%** |
| Financial District | 65% | **85%** |
| Mission (24th & Mission) | 49% | **84%** |
| Sunset (Judah & 30th) | 72% | **76%** |
| Nob Hill | 46% | **81%** |
| Castro | 45% | **79%** |

The remainder is service roads, alleys and streets the survey marks as having no
sidewalk. Synthesis leaves 0.14% of connected nodes stranded (they are dropped);
the largest component is kept, per the PRD.

Sidewalk-level geometry has one consequence for the corridor: **at `s = 0` every
corridor is a single line**, even in the SoMa grid, because no two sidewalk staircases
have exactly the same length. 2% of slack turns that line into hundreds of segments.

### Terrain

Hills shade too. Measured as the share of edges whose sun bucket changes when terrain is
switched off (`lwtool sun --no-terrain`), at low sun:

| Area | 8:30 am (el 17°) | 6:00 pm (el 12°) | Dec 3:30 pm (el 12°) |
|---|---|---|---|
| SF · Twin Peaks east slope | 18% | **33%** | **37%** |
| Berkeley Hills | 19% | 20% | 20% |
| SF · Nob Hill | 10% | 8% | 3% |
| Downtown Berkeley | 6% | 2% | 8% |
| SF · SoMa (flat) | 6% | 4% | 3% |

Under Twin Peaks in the evening a third of the sidewalks are in hill shadow that a flat
model calls sunny. On flat ground the few percent that change come from a roof being
`ground + height` rather than just `height`.

### A third city: Moorpark

Suburban Ventura County, no survey, thin OSM: 69% of walkable edges were bare street
centrelines and only 19% sidewalk ways. `build_bundle.py "Moorpark, California"` gives
27,059 nodes, 18,667 synthesised sidewalk edges, 11,558 Overture buildings, terrain
127–386 m, **3.0 MB**, 36 stranded nodes.

| Area | kerbs with a sidewalk edge | of which synthesised |
|---|---|---|
| Downtown (High St & Moorpark Ave) | 86% | 95% |
| Moorpark College area | 91% | 93% |
| Campus Park | 98% | 100% |
| Tierra Rejada / Peach Hill | 72% | 80% |

Nearly all of it is synthesis — which is the point: a place OSM has barely touched still
gets per-side sidewalks.

**Hills versus houses in Moorpark.** The intuition that hills matter more than buildings
in a low-rise town turns out to be wrong here, and measurably so. The terrain horizon from
downtown is 6.6° to the north (Walnut Canyon) but 0–2° through the entire arc the sun
actually travels, south through west: the valley opens toward Camarillo, so the setting
sun looks *down* it. Fetching terrain 3 km beyond the city (now the default, so hills
outside a city polygon can shade into it) changed **zero** sidewalk buckets in Moorpark
across four areas and four times of day. Aiming the sun due north by hand shades 134 of
145 edges — the hills are real; the sun just never goes there.

Houses are what shade Moorpark sidewalks: a 5 m house 8 m from the kerb blocks the sun
below ~32°. Which exposed a real bug — 19% of Moorpark buildings had no measured height
and were defaulted to a flat 10 m, twice a real house. Unknown heights now take the
median of measured neighbours within 150 m (`Pipeline/overture.py`, tested in
`Pipeline/tests/test_heights.py`). Effect: **2–11% of sidewalk edges** in Moorpark had
been wrongly shaded (Peach Hill at 6:30 pm: 11%), all now sunnier. In San Francisco the
same fix moves under 0.4% — tall buildings dominate there.

**Gated streets.** osmnx drops `access=private` by default, which removed every gated
tract and HOA street in Moorpark (Elkton Court's whole neighbourhood; nearest node 104 m
away). They are kept now and flagged `FLAG_PRIVATE`; routing does not yet avoid cutting
through a tract you cannot enter.

**Midday the field barely changes**, and that is correct: with 5 m houses and 11 m
roadways, a sun above ~40° shades almost no sidewalk. Downtown Moorpark changes 20% of
buckets between 7:30 and 9:00, 33% between 18:00 and 18:30, and 1–4% per step from
10:30 to 15:00. What you feel at noon is tree shade, which the model does not have.

**Trees are not modelled**, and in a suburb they are probably the largest remaining
error. USGS NLCD tree-canopy (30 m, national, free) is the scalable input; not done. The caveat is the flip side of Berkeley's: with only 62 streets
tagged `sidewalk=no` and no survey, synthesis assumes both kerbs wherever OSM is silent.
Suburban California tracts mostly do have them; rural roads at the edges may not.

Overpass was the only hard part. Two mirrors hung mid-query; the pipeline now times each
request out at 3 minutes and rotates mirrors, and recovered both.

### A second city

`build_bundle.py "Berkeley, California"` with no width survey: 55,642 nodes, 29,367
synthesised sidewalk edges, 51,732 Overture buildings, terrain to 529 m, **7.1 MB**, 24
stranded nodes. Downtown reaches 83% kerb coverage; the Berkeley Hills only 23%, because
OSM tags those streets `sidewalk=no` — which is true, and the synthesis respects it.

## The engine

`Engine/` is a SwiftPM package, so its tests run on macOS in about a second without a
simulator. Both apps depend on it; nothing is fetched at runtime.

**Corridor.** An edge `A→B` of length `L` is in the corridor when
`d_from[A] + L + d_to[B] ≤ D · (1 + s)`, checked in both orientations, with
`excess = d_from[A] + L + d_to[B] − D` stored per edge.

**How it's searched.** The PRD specifies two full Dijkstras per destination, rerun when
the user leaves the corridor. This does something cheaper and exact:

1. **One backward Dijkstra from the destination**, bounded — it stops expanding once the
   popped distance passes `D · (1 + s)`, where `D` is learned when the origin settles.
   The resulting `d_to[]` is **invariant while the user walks**: it depends on the
   destination and the graph, never on where the user is standing.
2. **A forward flood that is A\* using `d_to` as its heuristic.** Because `d_to` is the
   *exact* remaining distance the heuristic is perfect and consistent, so `f = g + d_to`
   is monotone and the search expands precisely the nodes inside the slack envelope.
   Cost scales with the corridor, not the graph.

So the corridor is recomputed exactly on every location update instead of only on
corridor exit. Measured on the real SF graph: labels 1–20 ms once per destination,
forward flood 0.2–3 ms per update.

`CorridorEngine.corridor` throws `labelsTooNarrow` rather than silently truncating if
asked for more slack than the labels were bounded to.

**Sun.** NOAA solar position (own implementation, no dependency), then for each edge five
sample points, each casting a ray toward the sun azimuth. First the ray walks the terrain
grid in 25 m steps out to where the city's tallest hill (300 m) could still rise above the
sun line; then it walks a 100 m grid of building footprints (Amanatides–Woo). A point is
shaded when the ground, or some roof at `ground + height`, rises above the sun line from
the walker's own ground level — so a tall building downhill may not shade at all. Edge
score is the lit fraction, bucketed at 0.3 and 0.7.

Accuracy is checked against **pvlib's NREL SPA** implementation (accurate to ~0.0003°),
regenerated by `Pipeline/solar_vectors.py` over four sites and ten instants: worst
elevation error **0.093°**, worst azimuth error **0.007°**. The PRD asked for 0.5°.

Performance, 1,761 edges around 3rd & Howard, swept across the day:

| Build | Worst case (2,231 edges, with terrain) |
|---|---|
| Debug | 180 ms |
| Release | 4.5 ms |

Budget was 200 ms for 2,000 edges.

**Interest** is precomputed in the pipeline: OSM features within 30 m of each edge,
weighted 3 / 2 / 1 per the PRD, stored as one byte and rendered in three brightness
buckets. Zero runtime cost.

## Checking it on a map

`Engine`'s `lwtool` dumps exactly what the app computes as GeoJSON, and
`Pipeline/check_maps.py` renders it with Folium — so the check is of the shipping code,
not a second implementation that might agree by accident.

```bash
swift build -c release --product lwtool --package-path Engine
Engine/.build/release/lwtool corridor --from 37.78415,-122.40060 --to 37.78060,-122.39460 \
  --slack 0.1 --out check/soma1.geojson --bundle Resources/sanfrancisco.lwbundle
cd Pipeline && .venv/bin/python check_maps.py ../check ../check/maps
```

## What the tests pin down

| Suite | Test | Asserts |
|---|---|---|
| Engine | `testGridCorridorIsExactlyTheRectangle` | on a unit lattice the corridor is exactly the 17 monotone edges of the rectangle |
| Engine | `testForwardFloodExploresOnlyTheCorridor…` | the flood touches 12 of 25 nodes — the A\* pruning is real |
| Engine | `testCorridorShrinksAsTheWalkerAdvances` | strictly shrinks each block, collapses to one edge |
| Engine | `testAskingForMoreSlackThanTheLabelsCover…` | refuses rather than truncating |
| Engine | `testMatchesNRELSolarPositionAlgorithm` | 40 sun positions within 0.5° of SPA |
| Engine | `testPeakElevationAtEquinoxMatchesLatitude` | peak elevation = 90 − \|lat\| at three latitudes |
| Engine | `testDaylightWindowBracketsTheInstant…` | the scrubber's window is right after sunset too |
| Engine | `testShadowLengthFollowsTheElevationAngle` | a 20 m wall shades exactly 20 m at 45° |
| Engine | `testOppositeSidesOfAStreetDisagree` | one side lit, the other not — the whole point |
| Engine | `testCentrelinesCannotAnswerWhichSideIsSunny` | measures the centreline's bias and how often the two kerbs differ |
| Engine | `testReadsWhatThePipelineWrote` | binary format contract, both directions |
| Engine | `testSunFieldPerformanceForASoMaBlock` | worst case across the day inside budget |
| SunMap | `testSoMaSunThroughTheDay` | the field actually changes through the day |
| SunMap | `testSunDownShowsTheMessage` | "Sun is down." |
| SunMap | `testScrubberMovesTheSun` | 15-minute steps move the sun; Now leaves the pinned time |
| SunMap | `testOvercastFlattensTheSky` | overcast preset: "no direct sun", beam 0, flat palette |
| SunMap | `testFogWestSplitsTheCity` | two weathers at once: fog in the Sunset, clear in the Mission, each side told which it is in |
| SunMap | `testSkyPickerOverridesTheForecast` | Auto/Sunny/Partly/Cloudy picker overrides and restores |
| SunMap | `MetroUITests` (3) | fresh install downloads Seattle's tiles, relaunch reuses them; New York shows "12:00 PM EST"; LA paints |
| LikeWater | `AmbientSunUITests` (3) | sun around the map with no destination; follows a pan; returns after clearing; New York in EST |
| LikeWater | `testNewYorkCorridorAcrossTiles` | Times Square → Union Square across tiles, in Eastern time |
| Engine | `ScaleTests` (8) | tiles stitch back into the identical graph; terrain mosaic; 430 m tower shades 600 m away; far-field ridge; no phantom plateau; island snapping; corridor scratch reuse |
| Engine | `MetroTests` (6) | real Seattle/NYC/LA tiles: no seams, cross-tile walks, Staten Island, Central Park South winter shadows, LA terrain |
| Pipeline | `test_scale.py` (8) | CSR, footprint flattening, NYC polygon rays, per-way survey aggregation, Seattle line survey, shared terrain lattice |
| Engine | `SkyTests` (7) | clear-sky reference vs model clear days; the 2026-09-15 fog-day fixture (coast <0.1, Mission >0.8); interpolation; cell dedupe |
| SunMap | `testDownloadsBerkeleyOnDemand` | with the shipped Berkeley hidden, the app finds it in the server manifest, downloads it, paints it, and reuses the file on relaunch |
| Engine | `testSecondCityBundleIsComplete` | a city built with no width survey loads, synthesises, and carries 500 m terrain |
| Engine | `testHillsShadeAtLowSunAngles` | a 40 m rise 90 m away blocks a 12° sun and not a 40° one |
| Engine | `testBuildingGroundLevelMatters` | a roof is ground + height, so a building downhill may not shade |
| LikeWater | `testEachLayerPaintsTheCorridor` | all three layers render the same corridor |
| LikeWater | `testWalkingShrinksTheCorridorAndArrivalResets` | states 4 and 5, distance never grows |
| LikeWater | `testRandomFreeChoicesNeverCostDistance` | every random free choice is free |
| LikeWater | `testSlackFromDirectToWander` | monotone in slack across 0–60% |

## What this build found

- **At `s = 0` every corridor is a single line, even in the SoMa grid.** The PRD expects a
  rectangle there. On a *sidewalk-level* graph, exact ties between staircase paths are
  essentially impossible — each sidewalk run has its own length. 2% slack (about 36 m on
  a 1.8 km walk) turns that line into hundreds of segments. Slack is not a refinement of
  this product; it is the product.
- **Only 24% of edges are per-side sidewalk geometry**, not the 34% a first pass suggested.
  The flag was conflating `footway=sidewalk` (a real line per side, 51,247 edges) with a
  street centreline tagged `sidewalk=both` (22,277 edges) — the latter records that
  sidewalks exist but is still one line down the middle of the road and cannot tell the
  sides apart. They are separate flags now, and a test asserts they never overlap.
  By neighbourhood: Mission 47%, Sunset 37%, SoMa 26%, Financial District 25%.
- **Nothing is filtered out.** All 216,539 edges are routed over and all of them are
  sun-scored; the sidewalk flag feeds diagnostics only. The open question was whether
  scoring a road *centreline* stands in for its kerbs. Measured over the 51 SoMa
  centrelines OSM says have sidewalks, comparing each against points offset 8 m to
  either side: the centreline is only mildly optimistic (+1% to +9% of an edge in sun,
  because shadow reach dwarfs an 8 m offset) and lands in the same bucket as at least
  one kerb 88–98% of the time. **But the two kerbs land in different buckets 43–51% of
  the time.** So a centreline is not wrong so much as unable to answer the question the
  user is asking — "is *my* side sunny" — on about half the streets where sidewalks are
  not drawn separately. `testCentrelinesCannotAnswerWhichSideIsSunny` pins this down,
  and `lwtool sunbias` reproduces it.
- **`d_to` being walk-invariant** is what makes the sun layer affordable: it is rescored
  per location update on a corridor that was itself found in a couple of milliseconds.

## Known gaps

- **Six cities.** San Francisco, Berkeley and Moorpark ship in the app; New York, Los Angeles
  and Seattle are tiled metros served from `Server/` (there is no public server yet — the
  phone gets them by sideloading). Building one is a single
  command and 5–10 minutes; the slow steps are Overpass (rate-limited, mirror-dependent)
  and the interest features.
- **Where OSM says `sidewalk=no`, there is no sidewalk edge** — the Berkeley Hills are
  23% covered for that reason. That is the data being right, but it means the sun layer
  there colours the road.
- **Roadway widths are class defaults** where the survey has none (all of Berkeley). Fine
  for shadows; a couple of metres off for anything that cares about exact kerb position.
- **No roof shapes or trees.** Terrain is in; a flat-topped extrusion is still what a
  building is.
- **XCUITest cannot drag a SwiftUI slider** in this configuration; the scrubber is tested
  through its step buttons, which are the PRD's 15-minute steps anyway.
- **Weather is a forecast, not an observation.** Beam strength comes from HRRR via
  Open-Meteo (15-min DNI, ~3 km cells; see `LEARNINGS.md` §9). It resolves the SF fog
  gradient but it can be an hour off on when the fog burns. `lwtool sky --center LAT,LON
  [--at ISO]` prints exactly what the app would say.
- **Interest weights are the PRD's, unvalidated.**
- **The real test is still outdoors.** Everything here says the model is self-consistent,
  matches NREL, and now knows about hills. Whether the bright side matches your skin on
  Howard St is the walk test.
