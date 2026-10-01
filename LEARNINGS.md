# What we learned building Like Water

Three cities, two kinds of place, one pipeline. This is the record of what turned out to be
true, what we assumed and had to unlearn, and the process we ended up needing beyond
"download OpenStreetMap." Everything here was measured; the tools that measured it are
in the repo (`lwtool`, the `--no-*` baseline flags, the test suites).

---

## 1. The single biggest lesson: the data question is the product question

The PRD reads as if the hard part is the corridor algorithm and the sun model. Neither was.
Both were done and verified against oracles (exact lattice expectations; NREL SPA to
0.09°) inside the first day. **Everything after that was about where the geometry comes
from**, and every product limitation we found traces to a data limitation, not a model one:

| Product question | Turned out to be a data question |
|---|---|
| "Is my side of the street sunny?" | Does the graph have one edge per side? (OSM: 24% of SF, 19% of Moorpark) |
| "Why is the corridor a line at s=0?" | Sidewalk-level geometry has no exact ties — every staircase is a different length |
| "Why is this street sunny when it isn't?" | 19% of Moorpark houses had a guessed 10 m height |
| "Do hills matter?" | Depends entirely on where the terrain horizon sits relative to the sun's arc |

The corridor engine is ~300 lines and hasn't changed since day two. The pipeline is ~1,200
lines and changed every day.

---

## 2. San Francisco: what a well-mapped city taught us

### 2.1 You cannot fetch OSM at runtime, even when it works
V0 pulled the walking graph from Overpass on demand. It worked in demos and then:
a 245-second timeout on two mirrors, a 20-minute hang on one `leisure=park` query, a
`406` for a missing User-Agent. Overpass is a shared volunteer service that rate-limits
and refuses unpredictably. Even when it answered, the phone downloaded tens of MB of JSON
and then had to parse and build a graph while the user stared at a spinner.

**What we do instead:** build once, server-side, ship a binary bundle. The bundle *is*
the interface — the app never talks to OSM. "On demand" became "download a 3–33 MB file
from a manifest," which is faster for the user, kinder to OSM, and lets the pipeline use
DuckDB, GeoPandas and Overture parquet, none of which run on iOS.

### 2.2 "Sidewalk coverage" is two different numbers, and we conflated them
First pass said 34% of SF edges were sidewalks. Wrong. The flag was set for both
`footway=sidewalk` (a line drawn down one side of a street — 24%) and `sidewalk=both` on
a *centreline* (a single line down the middle that merely notes sidewalks exist — 10%).
Only the first can distinguish sides. Separate flags now, with a test that they never
overlap on one edge.

The general lesson: **a flag named after what you want is not evidence you have it.** Ask
what physical thing the tag describes.

### 2.3 A centreline cannot answer the question the sun layer asks
We measured it rather than argued it: on 51 SoMa centrelines that OSM says have sidewalks,
comparing the centreline's own sun score with points offset 8 m to each kerb:
- the centreline is only mildly optimistic (+1–9% of an edge in sun) — shadow reach dwarfs 8 m
- it lands in the same bucket as *at least one* kerb 88–98% of the time
- **the two kerbs disagree with each other 43–51% of the time**

So a centreline isn't wrong; it's answering "is this street sunny" when the user asked
"is *my side* sunny." On half of streets that's a different answer. This is the number
that justified building sidewalk synthesis at all.

### 2.4 At s = 0 the corridor is always a single line
The PRD expected a rectangle on the SoMa grid. On sidewalk-level geometry that cannot
happen: exactly one staircase is shortest, because every sidewalk run has its own length.
Two percent of slack (36 m on a 1.8 km walk) turns the line into 700 segments. **Slack is
not a refinement of this product; it is the product.** The default of 10% is probably
too wide for commuting and an absolute floor (~one block) may feel better than a ratio.

### 2.5 Component-aware snapping is not optional
The first "Ferry Building" destination snapped onto a six-node disconnected pier footway
and the app correctly said "unreachable." OSM walking extracts are full of islands. The
user snaps to the main network; the destination snaps to the user's component. Trivial
once you know; invisible until real data.

### 2.6 What each outside source actually gave us (SF)
| Source | Checked | Verdict |
|---|---|---|
| **DataSF Sidewalk Widths (2014)** | 16,174 segments, joined to OSM | **Median 1 m join, 87% of SoMa matched.** Presence (26% of streets have none), side, width. The thing that made synthesis credible. |
| **Overture buildings** | 164k SF footprints | **96% with height vs OSM's 71%**, merging OSM + USGS Lidar + Microsoft ML. Adopted. |
| Overture transportation | 2,728 SoMa segments | 2,714 are OSM-sourced, identical sidewalk count, **0% road widths.** Nothing. |
| **AWS Terrain Tiles** | z14, ~7.6 m/px | Free, no key. Nob Hill 100.6 m, Ferry Building 2.5 m. z15 agrees to 1 m. Adopted. |
| USGS 3DEP 1 m DEM | exists | Overkill for shadows; z14 tiles are within a metre where it matters. |
| OpenSidewalks, Tile2Net | — | No SF data (Seattle; Boston/NYC/DC). |
| osm2streets, sidewalkify | — | Rust with unpublished bindings; a 2018 package pinned to old GeoPandas. Wrote our own. |
| Apple MapKit | — | Draws sidewalks and 3D buildings in SF; exposes none of it. No height, elevation, or sidewalk API. |
| Google Elevation API | — | Works, paid; the free tiles are equivalent. |
| Google Solar API | — | Returns a DSM and **hourly shade rasters** — Google has precomputed what we compute — per paid call over ~100 m. Not a source; a possible validation oracle. |

### 2.7 Terrain matters in SF, in specific places
Measured as the share of sidewalk edges whose sun bucket changes when terrain is switched
off: **Twin Peaks east slope 33–37% at low sun**, Nob Hill 3–10%, SoMa 3–6%. The SoMa
number is not hills; it's a roof being `ground + height` rather than `height`.

---

## 3. Moorpark: what a suburban town taught us

### 3.1 OSM is the inverse of SF
| | SF | Moorpark |
|---|---|---|
| Street centrelines | 34% | **69%** |
| Per-side sidewalk ways | 24% | **19%** |
| Streets tagged `sidewalk=no` | thousands | **62** |
| Gated / `access=private` streets | rare | common (dropped by default; now kept) |
| Survey data | DataSF, joins at 1 m | none |
| Buildings with measured height | 96% (Overture) | 81% |

### 3.2 Synthesis is what makes a thinly-mapped place usable at all
With no survey, `build_bundle.py "Moorpark, California"` reached **72–98% of kerbs with
their own sidewalk edge**, 80–100% of it synthesised. In SF synthesis took coverage from
57% to 74% (SoMa); in Moorpark it took it from roughly 30% to 86%. **The less OSM has,
the more the synthesis does** — which is the whole point, and also the risk (see 3.6).

### 3.3 Your intuition about hills was wrong, and we can say exactly why
The obvious guess for a low-rise town in a valley: terrain does the shading. Measured:
- the terrain horizon from downtown is **6.6° to the north** (Walnut Canyon) but
  **0–2° through the entire arc the sun travels**, south through west — the valley opens
  toward Camarillo, so the setting sun looks *down* it
- fetching terrain 3 km beyond the city polygon (now the default) changed **zero** sidewalk
  buckets across four areas × four times of day
- aiming the sun due north by hand shades 134 of 145 edges — the hills are real; the sun
  is never there at 34°N

**The general rule:** terrain matters when the terrain horizon in the sun's *actual* arc
exceeds the sun's elevation. That's a per-place, per-bearing question, and `lwtool` can
answer it in seconds. Don't guess from "it's hilly."

### 3.4 Houses are what shade suburban sidewalks — and we had them 2× too tall
A 5 m house 8 m from the kerb blocks the sun below ~32°, so it shades its sidewalk all
morning and evening. 19% of Moorpark's buildings had no measured height and got a global
10 m default. Effect, measured by diffing bundles: **2–11% of sidewalk edges wrongly
shaded** (Peach Hill 6:30 pm: 11%). Fixed by taking the median of measured neighbours
within 150 m. In SF the same fix moves under 0.4% — tall buildings dominate there.

**The general rule:** any global default in a per-place dataset is a bug waiting for the
place it doesn't fit. Defaults should be local.

### 3.5 Two things the first outdoor test surfaced within an hour
**"The sun/shade isn't changing with time."** Measured, downtown Moorpark, 500 m, every
90 minutes: the field changes **20% between 7:30 and 9:00** and **33% between 18:00 and
18:30**, but only **1–4% per step from 10:30 to 15:00**. With 5 m houses and 11 m
roadways, once the sun is above ~40° almost nothing shades a sidewalk — the model is
answering honestly. What the tester *felt* midday was shade from trees, which the model
does not have. This is the trees gap (3.6) showing up as a user report on day one. In SF
the same test would not have produced the complaint: tall buildings shade at any hour.

**"Elkton Ct isn't included."** It is `highway=residential` + `access=private` — a gated
tract — and osmnx's walk filter drops `access=private` by default
(`ox.settings.default_access`). The whole neighbourhood was missing; the nearest graph
node was 104 m away. Fixed by keeping `access=private` (still dropping `access=no`) and
flagging those edges `FLAG_PRIVATE`. The Moorpark walk graph went from **14,898 to
20,802 nodes — 40% of the town's walkable network was gated or private.** Town-wide
kerb coverage is now 87%. **A suburban town has many of these; SF has almost none** — another place where the SF-tuned default was silently wrong for Moorpark.
Open question: the corridor engine does not yet treat private edges specially, so a
route *through* a gated tract you cannot enter is now possible. The right rule is
probably "private edges are traversable only if the origin or destination is inside
that tract," which needs the tract as a unit — not done.

### 3.6 Overpass is worse for small towns, not better
Counter-intuitive. The graph came fast; the *interest* queries (`leisure=park`, `shop=*`)
hung for 20 minutes on two mirrors. The pipeline now times every request out at 3 minutes
and rotates three mirrors; it recovered both hangs unattended. Then the *graph* query
timed out at 3 minutes on the next rebuild — the fix for one query type broke the
heavier one. Every Overpass call now rotates mirrors, with a 7-minute timeout for the
graph and 3 for tags. Overpass is the single least reliable component in the system; a
self-hosted Overpass or a planet extract (`osmium`) is the real answer at scale.

### 3.7 The remaining honest gaps in a suburb
- **Trees.** Not modelled. On a tree-lined suburban street this is probably the largest
  remaining error — larger than hills, possibly larger than houses. USGS NLCD tree canopy
  (30 m, national, free) is the scalable input.
- **Synthesis assumes sidewalks where OSM is silent.** With only 62 `sidewalk=no` tags and
  no survey, every untagged street gets two kerbs. Suburban CA tracts mostly have them;
  rural roads at the town edge may not. Berkeley shows the opposite failure: the hills are
  *tagged* `sidewalk=no`, so they get nothing (23% coverage) — correctly.
- **Roadway widths are class defaults** (Residential 11 m, Alley 6 m…). Fine for shadows;
  metres off for anything that cares where the kerb exactly is.

---

## 4. The process we actually needed (beyond "download OSM")

What "build a city" means now, in order, with what each step exists to fix:

| Step | Exists because |
|---|---|
| 1. OSM walking graph via osmnx, largest component only | islands make destinations "unreachable" |
| 2. Classify edges by *physical thing*, not tag name | the 34%/24% conflation |
| 3. Join a sidewalk survey if one exists (DataSF) | presence and width without guessing |
| 4. **Synthesise per-side sidewalks** where OSM lacks them | centrelines can't say which side is lit |
| 5. Buildings from Overture, not OSM | 96% vs 71% heights |
| 6. **Local-median default** for unknown heights | 19% of Moorpark houses at 2× |
| 7. Terrain grid, **+3 km beyond the city** | hills outside a polygon can shade into it |
| 8. Per-building ground level | a tall building downhill may not shade at all |
| 9. Interest features with mirror rotation and 3-min timeouts | Overpass hangs |
| 9b. Keep `access=private` streets, flagged | gated tracts vanished from a suburb |
| 10. Binary bundle + manifest | the app never talks to OSM |
| 1b. **Big cities: read a Geofabrik extract, not Overpass** | Overpass refused even a count query for NYC/LA |
| 4b. Survey adapters, decided per OSM way | per-segment answers near corners said "no sidewalk" 88% wrongly |
| 4c. Remove centrelines OSM already sidewalked (incl. `sidewalk=separate`), link their junctions | side-less centrelines were 40% of Seattle's bare street |
| 10a. **Metros: one graph, cut into ~4 km tiles with global node ids; app stitches** | a single NYC bundle would be ~300 MB |
| 10b. Live sky from Open-Meteo, 9 cells around the user, blended into the palette | a shade map under overcast is a lie |
| 11. **Measure, don't eyeball**: `lwtool coverage / sun / sunbias / corridor`, `--no-terrain`, `--no-sidewalk-synthesis`, `--global-default-height`, and diff bundles | every claim above came from one of these |

Step 11 is the one we'd keep if we could keep only one. Every time we guessed (hills
matter more; 34% coverage; 10 m is a fine default) the guess was wrong, and every time we
diffed two bundles the answer was unambiguous.

---

## 5. Urban vs suburban, side by side

| | San Francisco | Moorpark |
|---|---|---|
| What shades sidewalks | Buildings, then hills in specific districts | Houses, then (unmodelled) trees; hills ~never |
| Terrain horizon in the sun's arc | up to 30°+ on Twin Peaks' east slope | 0–2° |
| Effect of terrain on buckets | 3–37% by district | ~0% (5% from ground-level roofs) |
| Effect of local height defaults | <0.4% | 2–11% |
| Hour-to-hour change in the sun field, midday | large (buildings) | 1–4% (houses); trees would supply the rest |
| OSM per-side sidewalks | 24% | 19% |
| After synthesis (kerb-metres) | 74–85% | 72–98% |
| Survey available | yes (2014) | no |
| Bundle size | 33 MB | 5 MB |
| Build time | ~10 min | ~35 min (Overpass hangs) |
| Best first spot-check | Mission (84%) | Campus Park (98%) |
| Weather model cells across the city | 10–15 (fog gradient resolved) | 2–3 (one weather) |

(New York, Los Angeles and Seattle are in §10's table: same model, but the dominant errors
there were shadow reach, survey interpretation and centreline removal, not heights.)

The model is the same. The *dominant error* is different in each place, and you cannot
know which without measuring that place.

---

## 6. What scales and what doesn't

**Scales:** the pipeline (one command, any place name), Overture buildings (global),
terrain tiles (global), the synthesis (needs only OSM), the bundle/manifest download.

**Scales now (§10):** big cities as stitched tiles, read from state extracts; surveys
through adapters (NYC polygons, Seattle lines, SF's DataSF).

**Doesn't, yet:** sidewalk surveys for most cities (LA has none we could find — synthesis
defaults fill in), tree canopy (NLCD is US-only), validation (the only ground truth we have is
"walk it").

**Unknown:** cities where OSM has *neither* sidewalks nor `sidewalk=no` tags and where
the default assumption of two kerbs is wrong — dense old European centres, informal
settlements, rural US. The synthesis needs a "no sidewalk" signal from somewhere; without
one it will over-generate.

---

## 9. Weather: the sun map is only true under a clear sky

### 9.1 The question is not "sunny or cloudy" — it is "how much beam is there"
A geometric shade map assumes a direct beam. Under overcast there is none: nothing casts
a shadow, and every sidewalk is in the same flat light. In between — thin cloud, broken
cloud, the edge of the fog — the beam is weakened or intermittent and the shade contrast
shrinks with it. So the sky is reduced to one scalar, **beam strength** = forecast direct
normal irradiance ÷ what a clear sky would deliver at that sun elevation (Meinel's fit,
`ClearSky.directNormal`, which tracks the model's own clear afternoons to ~5%: 890 W/m² at
50°, 640 at 20°). It comes straight from the forecast's DNI, not from a cloud percentage,
because 50% cloud can mean "half the sky is bright cumulus, beam at full strength when it
is out" or "a uniform veil at half strength" — the DNI already averages that over the
15-minute step, cloud-cover does not.

Regimes: ≥0.75 clear, 0.4–0.75 thin cloud, 0.15–0.4 broken, <0.15 overcast (and "fog"
when the low-cloud layer is ≥60%). Below 0.15 the map stops pretending: all three classes
fall to one slate colour and the status says "no direct sun". Above it the sun/mixed colours
fade toward that slate by the beam strength. The geometry is never touched; only the
palette and the wording. A first attempt used a pale grey for the flat palette and the
sidewalks vanished into Apple's light-grey streets — measured by screenshot, fixed to a
darker slate.

### 9.2 Which source (all checked 2026-09-29 for six SF points)

| Source | Resolution over SF | Beam data | Verdict |
|---|---|---|---|
| **Open-Meteo, `best_match`** (HRRR 3 km under the hood) | 5 distinct cells for our 6 test points | DNI + diffuse at **15-min** steps, cloud by layer hourly, 16-day forecast, free, no key, multi-point in one call | **Used** |
| Open-Meteo `ncep_hrrr_conus` | same 5 cells | same | same data as best_match here |
| Open-Meteo `ncep_nbm_conus` | 6 cells | no low-cloud layer | can't say "fog" |
| Open-Meteo `ecmwf_ifs025` | **2 cells for all of SF** | yes | too coarse for microclimates |
| NWS `api.weather.gov` gridpoints | 2.5 km (grid X 81–86 spans SF) | `skyCover` % only, no irradiance | usable fallback for cloud, not for beam |
| Apple WeatherKit | per-coordinate, resolution undocumented | `cloudCover`, `uvIndex`, no DNI | needs the entitlement and a paid team; 500k calls/month free after that. Not needed while Open-Meteo works |
| GOES satellite (fog.today) | 2 km, 5-min, *observed* not forecast | none directly | the right answer for "is it foggy *right now*"; not wired, see 9.5 |

### 9.3 Does the model actually resolve San Francisco's microclimates? Yes, measurably
The worry was that any forecast would be one number for the city. Fourteen days of
`best_match` hourly low cloud for Ocean Beach vs the Mission, 9 am–5 pm:

| | |
|---|---|
| mean (Ocean Beach − Mission) low cloud | +13 points |
| hours with a ≥40-point gap | 22 of 135 (16%) |
| days with at least one such hour | 10 of 14 |
| mean absolute DNI gap | 160 W/m² |
| hours with a DNI gap >300 W/m² | 26 |

The textbook day is 2026-09-15 at 2 pm: low cloud 100% at Ocean Beach, 5% in the
Mission; DNI 2.5 vs 805 W/m² — fog on one side of Twin Peaks, full sun on the other. That
day is now the engine test fixture (`sky_sf_fog_2026-09-15.json`) and the assertion is the
product claim: beam <0.1 at the coast, >0.8 inland, at the same instant.

Interpolating between cells is inverse-distance over the nearest four. Walking the line
from Ocean Beach to the Mission the blend stays at 0.04–0.08 until 80% of the way and then
climbs to 0.98 — because the Twin Peaks cell in between was fogged too. It is not
monotonic (dips of ~0.01 as the Park Merced cell pulls); the first test asserted it was
and was wrong. Also: the request lattice is 2.5 km and the model grid is ~3 km, so 9
requested points came back as 4 distinct cells; before deduplication the blend counted one
cell three times.

### 9.4 What it costs
One request for the nine lattice cells around the user: 89 KB, 744 ms, cached 30 minutes
per cell set. The lattice is snapped to a global grid (one longitude step per 1° latitude
band — a step that varied with the query latitude broke cache hits between two points 100 m
apart) so two nearby launches ask for the same cells. Free tier is 10k calls/day counting
each point; nine points a request is ~1,100 requests/day, fine for one user, and a proxy
would be needed before a thousand.

This is the **one thing the apps fetch at runtime**, because it is the one thing that
cannot be built ahead of time. Offline, refused or out of range it degrades to the
clear-sky map with the status "No forecast · assuming clear sky", which is exactly what
the app was before weather existed.

### 9.5 What is still missing
- **Observation vs forecast.** HRRR is a forecast, updated hourly. When the fog burns off
  at 11:20 and the model said noon, the map is wrong for 40 minutes. GOES-West visible
  imagery (2 km, every 5 min) is the actual state and Open-Meteo has no equivalent; a
  small server that scores the fog line from the satellite would be the next step.
- **Intermittency inside a step.** Under broken cumulus the beam is on/off on a
  one-minute timescale; a 15-minute average DNI shows "sun at 55%" when the truth is
  "full sun, then none". The regime wording says "broken cloud", which is as honest as a
  forecast can be.
- **Trees + cloud compound.** In Moorpark the unmodelled trees were already the dominant
  midday error; cloud makes the geometric map matter less, not more, so the priority
  order there is unchanged.

---

### 9.6 GOES fog POC: first findings (2026-09-30)
Built `Pipeline/goes_poc.py` (classify each 0.0225° lattice cell from GOES-18 ACM cloud
mask, ACHA cloud-top height, ACTP phase and COD optical depth), `goes_log.py` (every 15
min: GOES + Open-Meteo for the same cells + SFO/OAK METAR) and `goes_report.py` (decision
rule). What the first day showed, before any verdict:
- **The data is small and fast.** One CONUS scan of the four products is 9.5 MB (ACM 3.4,
  COD 5.3, phase 0.5, height 0.3), on the bucket **2–3 min** after the scan ends (129 s and
  165 s measured; COD is the slowest). Cropping + classifying 600 Bay Area cells: ~5 s on
  the Mac including downloads. Latency is not going to decide this.
- **Cloud-top height reads high for the marine layer**: ACHA put the fog tops at
  1.0–1.9 km on mornings METAR had stratus at a few hundred metres. A 1.2 km "low cloud"
  cutoff misclassified most fog as mid/high; the cutoff is now **2 km with a liquid
  phase**, which is also what Open-Meteo means by `cloud_cover_low`, so the two compare
  like for like.
- **Fog is optically thick, remnants aren't.** Ocean Beach at 8 am on 2026-09-16 had COD
  51 (beam 0); the 10 am leftovers on 2026-09-30 had COD 0.6–2.5, which still lets
  ~20–50 % of the beam through. Beam is therefore `exp(−COD · air mass)` whenever COD
  exists (daytime), not a flat zero for "low".
- **The fog line is visible at cell scale**: 2026-09-16 15:00Z classifies Ocean Beach as
  liquid low cloud and the Mission as clear (`tests/test_goes.py` pins it on the cropped
  scan); 30 min later the fog had reached the Mission.
The verdict (GOES vs HRRR on disagreements against METAR, burn-off timing) comes after
≥ 10 days of logs: `Pipeline/.venv/bin/python Pipeline/goes_report.py`.

## 10. Scaling to New York, Los Angeles and Seattle

Everything up to here was one city per bundle, fetched from Overpass. Neither half of that
survives a big city. Numbers below are from `Pipeline/build_metros.sh`, `lwtool --metro`,
and `MetroTests` (release build, M-series Mac).

| | Seattle | New York | Los Angeles (+ Beverly Hills, WeHo, Santa Monica, Culver City) |
|---|---|---|---|
| Walk graph after synthesis | 542k nodes | 1.34M nodes, 6 components | 1.99M nodes |
| Overture buildings | 360k (70% with height) | 1.77M (94.5%), max 472 m | 2.00M (98%), max 335 m |
| Tiles (~4 km) | 31 | 76 | 109 |
| Total / median tile / largest tile | 64 MB / 1.8 / 4.6 MB | 175 MB / 2.2 / 4.6 MB | 290 MB / 2.6 / 5.5 MB |
| First build (downloads) / rebuild | 6 min / 0.8 min | 10 min / 1.6 min | ~12 min / 1.5 min |
| Peak pipeline memory | 2.4 GB | 4.8 GB | 5.3 GB |
| Stranded after synthesis | 0.8% | 2.1% (mostly subway stairs) | 1.1% |
| Kerbs with a sidewalk edge (600 m) | 33–77% | 56–99% | 55–87% |

### 10.1 Overpass cannot serve a big city; a state extract always can
A single Overpass *count* query for New York or LA failed outright on the public mirror
(Seattle's answered). A whole walk network is far heavier. Geofabrik state extracts
(NY 497 MB, WA 364 MB, SoCal 671 MB) are a download that never refuses, and pyosmium reads
the walk network out of them in 32 s (Seattle), 45 s (NYC), 56 s (LA) — faster than
Overpass ever served San Francisco. `osm_pbf.py` reproduces osmnx's walk filter so the
graph is the same shape and synthesis is shared.

### 10.2 One bundle stops working; tiles that stitch by id do
A New York single bundle would be ~300 MB. Instead the metro is built once as one graph
(synthesis and components need the whole city), then cut on a fixed 0.04° × 0.05° lattice:
every edge goes to the tile of its midpoint and carries its end nodes' metro-wide ids, every
building to the tile of its centroid, and terrain is sliced from one shared 10 m lattice.
The app loads the tiles within 2.5 km of the map centre (or of a walk's bounding box) and
stitches them: nodes unified by id, edges and buildings concatenated — nothing is matched
geometrically, so nothing can be duplicated. Measured: 6 tiles stitch in 14–18 ms, 9 in
29 ms (release, Mac). `testTilesStitchBackIntoTheSameGraph` cuts a lattice the pipeline's
way and gets the identical graph back; in stitched Seattle only 54 of 120,511 interior
nodes were off-network (the rest of the "second component" is a real geography cut,
joined only through tiles that weren't loaded).

### 10.3 The 100 m shadow search was hiding Billionaires' Row
The sun scorer only searched as far as a 100 m building could shade. At Central Park South
at December noon (el 26°) that marked **507** edges shaded; searching as far as the tallest
roof in the loaded tiles needs marks **1,060** of 2,463 — 23% of the field was wrongly sunny.
In June (el 69°) it changes nothing. The search now reaches `(tallest roof − walker's
ground) / tan(el)`, capped at 6 km, with a per-cell tallest-roof check so cells that can't
reach the sun line are skipped; a 400 m field still scores in 2–8 ms.

### 10.4 Terrain: a fixed 300 m / 3 km reach was wrong in principle, but not what mattered
The ray used to stop at 300 m of relief or 3 km, and past the grid edge it clamped — the last
row extended forever as a phantom plateau. Now the reach comes from the highest ground in the
grid, steps grow with distance, and past every grid there is no ground. A coarse 100 m
far-field grid covers the metro + 25 km. **Measured: the far field changed zero edges** in
every case tried (Tujunga, Studio City, Downtown LA, Downtown Seattle; sun at 3.4–12.6°):
the stitched 10 m tiles already reach the ridges that matter. It stays (2 MB) as the
guarantee. What *does* matter is local terrain: in Tujunga at 8 am in December it shades
102 more edges; at 3:30 pm it *unshades* 293, because buildings downhill of a sidewalk can't
reach above it.

### 10.5 City sidewalk surveys: right, once asked the right way
* **NYC Planimetrics** (50,865 sidewalk polygons) — the adapter casts a ray from each street
  midpoint along each normal; the first polygon gives the kerb and the property line, so
  offset and width are measured. First version: 296,624 street sides came back "no
  sidewalk". 88% of those in Midtown were segments under 15 m next to a corner, whose ray
  looks into the cross street's roadway. Deciding each side **once per OSM way** (present if
  ≥30% of answered length found a sidewalk; median offset for every segment) took Midtown's
  "absent street sides" from 2,273 to 71 and straightened the kerb lines.
* **Seattle SDOT** (46,268 lines; `SW_WIDTH` is inches; `SURFTYPE=UIMPRV` means none) — the
  survey lowers kerb coverage 9–33 points versus defaults, which looked like a bug. Split by
  class, on Capitol Hill the survey says 96% of real street sides have a sidewalk; the gap
  is **alleys** (81% have none), which the defaults gave two sidewalks each. In Lake City
  the survey says 60% of real street sides have none — which is what Seattle's own sidewalk
  program says about north Seattle. The survey was right both times. Without a survey,
  `service=alley` now gets no synthesised sidewalks.
* LA publishes no sidewalk survey we could find, so it runs on defaults.

### 10.6 Three centreline bugs that only a big, well-mapped city exposed
1. **Streets OSM had fully sidewalked kept their centreline** (the comment said otherwise).
   Seattle Downtown kerb coverage 46% → 67% once removed.
2. **`sidewalk=separate` streets were never touched** — Park Slope kept 16 km of side-less
   centreline in 600 m; 56% → 90%.
3. **Removing those centrelines stranded what hung off them** (alleys, paths, and — found in
   LA — streets we synthesised sidewalks for, whose corners linked only to the removed
   junction). Each such junction is now linked to the nearest OSM sidewalk node on each
   side. Stranded: Seattle 5.1% → 0.8%, LA 5.5% → 1.1%, NYC 5.0% → 2.1%, where what is left
   is mostly subway stairs, elevators and station corridors (45% of Midtown's stranded
   nodes were `highway=steps`).

### 10.7 "Largest component" is not "the city"
Staten Island is only reachable on foot by ferry, so it is its own component and the old
rule deleted it. Components ≥ 2,000 nodes are kept (NYC: main + 5 islands); in a stitched
tile set the walker snaps to any component ≥ 300 nodes, not the largest.

### 10.8 Smaller things that would have bitten
* Every app time string used the device's zone; Manhattan from California read 9 am at
  noon. Metros carry a time zone (timezonefinder) and the apps show "12:00 PM EST".
* Each GPS fix allocated three city-sized arrays in the corridor (~25 MB in New York); a
  reusable `CorridorScratch` resets only what the last call touched. The sun scorer's
  scratch array was silently copied on every call (copy-on-write through a dictionary).
* Panning the map cancelled in-flight downloads (the recompute task owned them); tile
  downloads now run detached and are shared by whoever asks.
* Two loads raced on one tile file. Like Water loads the start's tiles, then the walk's;
  they overlap, both downloaded the same file, and the second move failed with "an item with
  the same name already exists". Passed alone, failed in the full UI suite. Downloads are now
  one shared task per file.
* Overture's bbox filter was *containment*: a tower straddling the box edge was dropped.
  Metros query by overlap with a 1 km margin.
* Like Water now paints the sun around the map before any walk is set (Sun Map's 400 m
  field and 200 m re-trigger, stitched tiles in metros); a destination swaps it for the
  corridor and clearing it brings the field back. The shared `SunService` moved to
  `Apps/Shared`.
* **Weather reached only one app.** It was built into Sun Map; Like Water's corridor Sun
  layer and its no-walk view kept clear-sky colours, so on an overcast day the two apps
  disagreed about the same street. Both Like Water sun views now fetch the same forecast
  and fade the same way (`SkyPalette.fade`); UI tests pin "Overcast · no direct sun" on each.
  Lesson: a cross-cutting input needs a test in every view that shows its output.
* **The sun field was a 400 m square, not the screen.** It was the PRD's number, scored
  around the map centre. Both apps now score every edge in the visible region plus 15%,
  capped at 2 km a side (downtown SF on a phone: 8,995 edges in 324 ms on a debug
  simulator vs 2,231 before), and say "Zoom in…" past the cap.
* **The apps never moved to the user if the fix was slow.** The map reports its starting
  (demo) region before the first fix arrives; that set a centre, and every later fix was
  ignored as "we already have a position". Found by logging, not by reading: the location
  arrow was on and the map sat in SoMa. The initial region now counts as a stand-in until
  a real fix replaces it (unless the user has already moved the map).
* OSM mapping is thinnest where incomes are lowest: Boyle Heights, Watts and San Pedro are
  93–100% synthesised sidewalk, Hollywood and Venice 25–31%. Synthesis is what makes those
  neighbourhoods usable at all; it is also where the map is least verified.

---

## 11. A route inside the corridor (2026-09-30)

The owner reversed the PRD's "never pick a route / no ETA": Like Water now draws one
suggested route inside the corridor, with minutes and arrival time on every layer, and a
Fastest ↔ Sunniest slider. Everything below is `lwtool route` (release build, Mac) on
2026-09-23 departures unless it says otherwise.

### 11.1 Scoring the sun for when you get there changes the route — sometimes, and a lot
Five walks × three departures (9 am, 1 pm, ~sunset−1 h), λ = 1, time-aware vs scoring
every street at the departure instant (`--compare`, both then lit by the time-aware truth):
| Walk | slack 0.1 | slack 0.3 |
|---|---|---|
| Times Sq → Union Sq, 1 pm | **+11 points** sun (89 % vs 78 %) | **+19** (90 vs 71) |
| Union Sq → Ferry Building, 6:07 pm | +5 (30 vs 25) | **+15** (30 vs 15) |
| Union Sq → Ferry Building, 1 pm | 0 | +2 |
| SoMa → Caltrain (8 min walk), all three | 0 | 0 |
| the other cells | 0 | 0 |
The effect needs a walk long enough to cross a slot boundary and a sky where shadows move
fast (low sun, deep canyons). Short walks and noon don't care; Midtown and sunset do.
Pinned by `MetroTests.testNewYorkTimeAwareRouteFindsMoreSun`.

### 11.2 Discounting crossing time for sun made the router zig-zag
The first cost function discounted *every* edge by its sun, crossings included. At
λ = 1 a SoMa route crossed the street **15 times in 650 m** (fastest: 2) to stay on the lit
side — each 12 s wait in the sun was nearly free. Crossings (road surface + the wait) now
always cost their full seconds, and the sun percentage shown is over sidewalk time only,
matching the cost; same route now: 2 crossings. A cost term the user doesn't experience as
"sun" must not be bought with sun.

### 11.3 What it costs and how big the choice is
- **Pareto sets are real but small**: 1–8 distinct routes over 11 λ values (most walks
  1–3 at slack 0.1, 5–8 in Midtown at 0.3). A continuous slider with 5 detents is right; a
  3-stop picker would often show three identical routes.
- **Price of sun**: 0.4–4 min per +10 % sun depending on the walk (SoMa 0.4, Midtown at
  noon 3–4).
- **Timeline**: scored pairs are 58–82 % of edges × slots (the ±1-slot widening that covers
  hills and crossing waits costs more than the plan's "≤ 2 slots per edge"); 1–8 ms in SF,
  35–140 ms in NYC (slack 0.1/0.3). The next fix reuses the cache (in the app: 0 scored,
  1,098 cached after a step).
- **Route search**: 0.1–25 ms; Midtown at slack 0.3 hits the 16-label cap ~3,000 times
  (55k labels). Fine on the Mac; watch it on the phone before raising slack defaults.
- **Fastest is not shortest**: with 12 s per crossing the time-optimal Times Sq → Union Sq
  walk is 2,794 m against the 2,583 m shortest — it trades distance for fewer crossings.

### 11.4 Hysteresis is needed, 5 % is not enough in Midtown
Simulated walks re-routing every 50 m (`--walk`): SF 0–3 changes/km with tolerance 0,
**0 – 1.8 with 5 %**; Midtown 6–9/km → **2.7–4.2/km with 5 %** — the grid offers many
near-equal routes. In the app a route the walker is on is kept when its remainder is within
5 % (UI test: kept on ≥ 4 of 6 steps). Next lever if it flickers on the phone: a larger
tolerance or a per-change minimum gain in seconds.

### 11.5 ETA model
Pace 1.4 m/s (Relaxed 1.1 / Brisk 1.7), Tobler slope from the bundle's terrain (per
direction: +10 % → 0.70×, −5 % → 1.19×, −15 % → 0.84× — the plan had −15 % → 0.70, wrong),
12 s per marked crossing, stairs 0.6×. Not yet checked against real walks: the app's debug
line shows "last walk: predicted · actual" after a GPS walk, and `PaceEstimator` blends the
measured pace 50/50 after 300 m / 3 min and learns across walks. Accuracy goes here once
the owner has walked a few (PLAN Part 3 #9).

### 11.6 Dimming the corridor under the route read as "washed out" outdoors

The route was drawn on top of a corridor faded to 60 % opacity, so it would stand out.
On the first real walk with it (2026-10-01, a clear morning: the forecast gave 0.7–1.0 of
full sun after 7:45) the owner's report was "the walking path with the sun was dulled
out". The sky fade wasn't the cause; the 0.6 alpha was. On a phone in daylight, a
translucent sun palette over the light map reads as no sun. The corridor is full colour
again; the route stands out by its width (9 pt) and white casing alone. Lesson: on this
map, translucency means "cloud", so don't use it for "less important".

## 12. Loading anywhere: coverage, builds, eviction (2026-09-30)

- **Coverage by the first point was the bug behind "half a screen fails".** Both apps
  picked the city by `points.first` (the screen centre); now the whole box (centre + four
  corners, or a walk's two ends) decides, choosing the place with the most overlap, and
  the field carries `covered`/`partial`. Seattle's north edge now paints its half and says
  "Only part of this screen has sun data".
- **Unbuilt is a state, not an error.** Denver shows "No sun data here yet", the nearest
  built place, the sky and the sun position in **~4.5 s** (UI test, local server); the red
  "No map data for this area yet." is gone, also for a Like Water walk (no route without
  tiles — ours-only).
- **Two status bugs were races, not logic.** "Showing SoMa" was set once and only if the
  GPS fix beat the map's first region report (it usually doesn't), so it rarely appeared
  and, when it did, never left; it is now derived (`outsideCity && centerIsFallback &&
  !userMovedMap`). Adding a 150 ms pan debounce exposed the second: the "Zoom in" status was
  only set after a recompute, and a slow pinch's last region often needs none — the status
  now follows the view.
- **Builds are pinned.** Node ids are row numbers of one build, so a phone must never
  stitch tiles of two builds. The stitch key carries `buildKey`; a newer server build goes to
  `Cities/<id>/<buildKey>/`, becomes `.ready` after its first successful stitch, and only
  then are older copies deleted; a newer build whose tiles 404 falls back to the old one;
  a server going back to an older build never downgrades the phone
  (`BuildPinningUITests`, with `Pipeline/fake_rebuild_server.py`).
- **Eviction only with a server.** LRU over a ledger of downloaded files, 400 MB cap,
  protecting the current stitch, loaded singles and in-flight downloads. With a 30 MB cap,
  Seattle → LA → New York leaves the cache under 30 MB and Seattle (least recent) is the
  one re-downloaded. Without a configured server nothing is evicted: sideloaded tiles are
  the only copy.
- **Prefetch makes short pans free.** After a stitch the surrounding ring downloads in the
  background on Wi-Fi only; a 2 km pan in Seattle then needed **0 downloads**. The cost is
  disk: Seattle went from ~13 MB to ~43 MB with its ring.
- **Pages would have refused today's `Server/`**: `sanfrancisco.lwbundle` is 31.9 MiB,
  over Cloudflare Pages' 25 MiB per-file limit (`build_places.py --dry-run` checks the
  limits). Fixed in D.

## 13. The whole screen, at any zoom: score tiles and sun by block (2026-10-01)

The owner's complaint: panning was laggy, and zoomed out only a square in the middle was
painted ("Zoom in to see every street"). Both came from the same design — one box scored
from scratch wherever the map stopped, capped at 2 km.

- **Score on a fixed lattice, cache per tile and 15-minute slot.** Street-detail tiles are
  1/8 of a metro tile (~500 m); a pan re-scores only the tiles that came into view, the
  ring around the screen is scored in the background afterwards, and overlays are added and
  removed per tile. Measured in the simulator (debug): first new tiles on screen **0.89 s**
  after a 40 % drag including the 150 ms settle, the rest from the cache; before, every
  stop re-scored ~9k edges (350 ms debug) and rebuilt all overlays.
- **Past 2.5 km, sun by block.** Cells of 70 m … 4.4 km (36–72 across whatever the zoom),
  coloured by the sunny share of the sidewalk metres sampled in them — the 12 longest edges
  per cell, which is near length-weighted and deterministic (no flicker). Cost is bounded by
  the sample, not the zoom: one NYC metro tile scores in **43 ms at 70 m cells (8k edges),
  16 ms at 280 m, 5 ms at 1.1 km** (release, Mac; `lwtool blocks`).
- **A metro is scored a tile at a time from the tile's own file.** A whole-city view can't
  be stitched (60–70 tiles, 1M+ nodes), so each 4 km tile is loaded alone (5 ms) with only
  its own buildings. The price is shadows that should cross a tile border: measured against
  the stitched neighbourhood, mean |Δsun| per cell is **0.010 at 70 m cells (1.5 % of cells
  change band, 0.03 within 300 m of the border), 0.012 at 280 m (1 %), 0.000 at 1.1 km**;
  Seattle 0.002; NYC at a low December sun 0.001. Acceptable for a density view.
- **MapKit's "900 m" is 2 km.** `setRegion(latitudinalMeters: 900)` reports a visible span
  about twice that on a portrait phone, so the street/block threshold must be decided on
  the *visible* box, not the margin-widened scoring box — the first cut put the default
  zoom into blocks.
- **A swipe in XCUITest is a fling** that throws the map a screen or more, so a "pan reuses
  the cache" test must drag (`press(forDuration:thenDragTo:)`); the swipe version found
  zero overlap and read as a cache bug.
- **Several places per screen.** The Bay view has San Francisco and Berkeley; a field is
  now scored from every place under the screen (metros and single bundles), most overlap
  first. A side effect found on the way: "prefer the downloaded copy" in city selection
  made a downloaded *other* city (Berkeley, from a test) outrank the shipped one that
  covered the screen — overlap must come first, freshness only among copies of the same city.
- Cells are drawn 3 % larger than they are: separate translucent polygons otherwise leave
  hairline seams of bare map between them.

## 14. What a second pair of eyes found in one day's code (2026-10-01)

Three independent reviews of this round's code (route/service, catalog/store/cache,
pipeline/Worker/CI), each verified against the code before fixing. Every test suite was
green before the review; none of these had a test. The pattern is worth more than the list:
**the bugs were in the seams between parts** — an actor and its awaits, a cache and the
build it belongs to, a CI step and the platform it runs on — not in the algorithms.

- **Actor reentrancy.** `CorridorService.update` took its scorer out of actor state as an
  implicit lock and then awaited the weather fetch; a GPS fix arriving during the await
  threw "Set a destination first" with a destination set, and (rarely) a tile-set change
  during the await let the first call write the old graph's context back over the new
  one. Fixed with a generation counter checked after every await and the scorer taken out
  only around the synchronous scoring block. Rule: an actor method that suspends must
  assume the world changed when it resumes.
- **A cache keyed by file name, not build.** Parsed tiles and far terrain were cached as
  `metro/file`; after a server rebuild while the app stayed open, the tiles the old stitch
  had parsed would have been stitched with the new build's files — the one thing pinned
  builds exist to prevent (and the UI test relaunched between builds, so it couldn't see
  it). Keys now carry the build. Related: Pages tiles sat at build-less paths with
  `immutable` caching, so a proxy or the phone's own URL cache could hand an old tile
  under a new build's name; Pages now uses the same `metros/<id>/<buildKey>/` layout as S3.
- **A ledger that trusted itself.** The eviction ledger was never reconciled with disk,
  saved only every 8 touches, and never told when `markReady` deleted an old build — so
  it could count 290 MB of ghosts and evict live files to pay for them. It now rebuilds
  from a directory walk on load and saves after every stitch.
- **Platform assumptions in CI.** `/usr/bin/time -l` is macOS-only: the cloud build would
  have failed on every Linux run the moment the secrets were set. And a transient failure
  in "pull the live site" was treated as "no site yet", which would have deployed a partial
  site over the real one — the second time a *swallowed error* (`|| echo`) was the bug.
  Pull now raises on anything but a 404 of the manifest, and publishing refuses to shrink
  the metro list without `LW_ALLOW_REMOVALS`.
- **Measurement that measures the wrong thing.** The pace estimator used "route length
  shrank" as progress, which jumps whenever the slider or hysteresis picks another route
  and starts the clock when the destination is set, not when the walker moves; a 90 s look
  at the map taught it a 6 % slower pace for every later walk. It now accumulates distance
  between real fixes and starts on the first move. In the fog POC, a METAR up to 50 min old
  was ground truth for a scan, a late cron lost a scan and a log that began at 10 am
  counted as a fog morning with a perfect burn-off score; and the latency clause of the
  decision rule could not fail (bucket latency is 2–3 min by construction). All tightened
  (20-min METAR window, 3-hour log window, mornings only with 9:15 coverage).
- **Smaller:** YAML injection through a Nominatim city name written unquoted into
  `metros.yaml` (quoted now); resumed downloads could splice two Geofabrik snapshots
  (part file named by snapshot, md5 checked); launchd's PATH has no `npx`; the Worker's
  Cache API is a no-op on `*.workers.dev` (KV now); a failed auto-build dispatch was never
  retried; "partial coverage" was judged on the margin-widened box; `.noServer` was
  unreachable while a city ships in the app; two arrival times on screen once the measured
  pace kicked in; captions showed the kept route at λ = 0/1.
- Open (BACKLOG): three Pareto searches per fix (~75 ms worst case on a phone); the
  10 km cloud-top product makes "low vs mid" cloud a single pixel for ~16 cells.

## 7. Testing lessons that cost us

- **Two UI tests passed for a week while testing nothing.** An
  `.accessibilityIdentifier` on a container silently overrode the identifiers of the
  buttons inside it; the walk tests found no button, exited immediately, and passed in 6 s.
  A fast-passing UI test is a smell. Dump the accessibility tree when in doubt.
- **XCUITest cannot reliably drag a SwiftUI slider.** `adjust(toNormalizedSliderPosition:)`
  landed on duplicate values; a real press-and-drag missed the thumb. We added ±15-minute
  step buttons (the PRD's steps anyway) and test through those.
- **The oracle must be independent.** Sun position is checked against pvlib's NREL SPA,
  not against NOAA's own table; the bundle format is checked by reading a file the Python
  writer produced, not a hand-encoded fixture; the Folium maps render `lwtool`'s output,
  not a second implementation.
- **A `--no-X` flag on every model input** turned "does X matter?" from a debate into a
  30-second diff.
- **Presets built "around now" broke tests pinned to a date.** The weather presets
  covered now ±3 days; the UI tests pin 2026-09-23, six days earlier, and every preset
  came back as "no forecast". Anything time-windowed must take the *requested* time.

---

## 8. If we did it again

1. Start from the bundle, not from Overpass-at-runtime. V0's runtime fetch cost a day
   and taught nothing the second approach didn't.
2. Build the measurement tools (`lwtool`) *before* the second city, not after — every
   Moorpark finding came from a tool we wrote for SF.
3. Treat every default as a per-place hypothesis to be measured.
4. Get tree canopy in before the first outdoor spot-check in a suburb; otherwise the
   spot-check will mostly be measuring trees.
