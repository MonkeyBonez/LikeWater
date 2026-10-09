# Plan — route + ETA, time-of-arrival sun, load-anywhere, free hosting, US coverage growth, GOES fog POC

Approved 2026-09-30. This is the working plan for the next round; it is self-contained so
an agent can pick it up cold. Read `CLAUDE.md` (ground rules), `README.md` (architecture)
and `LEARNINGS.md` (what we have measured) first. Line numbers below are as of
2026-09-30 and may drift; the symbol names are the stable reference.

## Standing decisions (from the owner)

- **Route + ETA everywhere.** The PRD's "the app never picks a route / no ETA" is reversed:
  Like Water draws one suggested route inside the corridor, with minutes and arrival time
  on every layer. The corridor stays as context.
- **Ours-only pathfinding.** No Apple `MKDirections`, no Google, no Mapbox, no hosted
  Valhalla. Our sidewalk graph is the only router; our own pace model is the only ETA.
  (The analysis that led here is in §1.6; the Apple yardstick/fallback is parked in
  `BACKLOG.md`.)
- **USA only for now.** New places are seeded from a US list (§2 F). Nothing in the
  architecture is US-bound (§1.7.10). **Exception (owner, 2026-10-08): Seoul and
  Singapore are built** as named entries in `metros.yaml`; automatic proposals
  (`requests_to_places.py`) stay US-only. See `LEARNINGS.md` §16.
- **The owner owns scaling plans** (weather rate limits, paid keys, proxies). This plan
  records the triggers and the options and builds none of them.
- **A GOES fog proof-of-concept first**; the satellite job is built out only if the POC
  wins (§2 E).
- **Free hosting without buying a domain** (Cloudflare Pages, `*.pages.dev`); publishing
  is an outward-facing step the owner performs (`wrangler login`); the scripts are written
  here, nothing is uploaded by an agent.
- Repo etiquette: the repo is private `MonkeyBonez/LikeWater` on GitHub; commit and push to `main` after each tested step; update `LEARNINGS.md` and `BACKLOG.md` in
  the same turn as the code (per `CLAUDE.md`); measure with `lwtool`, don't eyeball.

---

## Part 1 — Think-through (why the plan is shaped this way)

### 1.1 Scaling

**Many phones.** Compute already scales for free: corridor flood 0.2–3 ms, whole-screen
sun field ~30 ms release, 6-tile stitch ~15 ms, the new route < 2 ms — all on the phone.
Three things don't scale as-is:

| | Today | Breaks at | Fix |
|---|---|---|---|
| Tile distribution | `python3 -m http.server` on the owner's Mac; **no `LWBundleBaseURL` in `project.yml`, so a real phone cannot download anything** (metros are sideloaded by `install_phone.sh`, ~1 GB per app) | the second phone | a static host + the Info.plist key (Part 2 D) — free, §1.7.2 |
| Weather | each phone calls Open-Meteo directly, 9 lattice points per request, 30-min cache | free tier is non-commercial, 600/min, 5,000/h, 10,000/day, 300k/month → ~1,100 fetches/day ≈ 300–500 daily users | *owner's call*: a caching Worker (free to 100k req/day; one upstream fetch per cell per 15 min shared by everyone) and/or the $29/mo key (1M calls/month; required anyway with ads/subscriptions) |
| Apple MapKit (base map, search) | free, no key, undocumented throttling | only on abuse | nothing to do |

First view downtown is 10–30 MB (Seattle 12.7, LA 19.7, NYC 17.8 — the README's 11.8 for
NYC is `lwtool`'s centre-only padding; the app pads the box corners). 1,000 users × 30 MB
= 30 GB/month: free on Pages.

**Many areas.** The pipeline is generic: Geofabrik extract + Overture buildings (S3,
anonymous) + AWS Terrain Tiles (no key) + timezonefinder; 6–12 min and 2.4–5.3 GB RAM per
metro; 64–290 MB output. The top 50 US metros ≈ 8–10 GB and a weekend of Mac time. What's
missing for *unbuilt* areas is behaviour, not data: today the app throws ("No map data for
this area yet." / "No bundle server configured…") and Sun Map keeps a stale "showing SoMa"
status. Part 2 C makes that a calm state (sky summary and sun times still shown — they
work anywhere — plus "Request this area"); Part 2 F grows coverage from a US list and from
human-approved requests. Fully automatic build-on-request and stable node ids (bundle v4,
for per-tile incremental builds) are parked; pinned builds (C5) suffice.

### 1.2 A backend: what it buys, for which parts

| Part | Server? | Why |
|---|---|---|
| Tile distribution | **static host only** | §1.7.2 — tiles can't be built on the phone or shipped in the app |
| Weather forecast (GPS → HRRR cell → beam) | no for one user; **yes at scale** | the phone already maps its position onto the 3 km cells and blends them; a proxy only shares fetches / hides a key |
| Fog/cloud *observation* (GOES) | **yes, server-only** | GB-scale NetCDF every 5 min; must be cropped/classified into a few-KB per-city JSON by a scheduled job. This is the real "GPS → cloud" gap: HRRR is a forecast and misses the fog burning off 40 min early (§1.7.3) |
| Corridor, route, sun scoring, ETA | no | ms on the phone, offline, private |
| Routing in unbuilt areas | not offered | ours-only decision: an unbuilt place shows the banner + request button until it is built |
| Coverage growth — **new places** | a job runner | the owner's Mac via launchd now; GitHub Actions cron (free 2,000 min/month) when the wish-list outgrows it — Part 2 F |
| Accounts/favourites | no | CloudKit if ever |

"Coverage growth needs a job runner", spelled out: new places (a user pans to Portland and
we haven't built it) are batch jobs, not requests the phone makes. Something has to run
`Pipeline/build_metro.py` (Python + pyosmium + DuckDB, 2.4–5.3 GB RAM, 6–12 min, a
300–700 MB Geofabrik extract, ~1 GB of Overture reads) and then `publish.py`. Today that
"something" is the owner at the Mac. A job runner is a machine that does it on a schedule
or a trigger: the Mac with launchd (free, only while the Mac is on; fine for months) or
GitHub Actions cron (2,000 free runner-minutes/month for a private repo, unlimited for a
public one; the 7 GB runner fits NYC's 4.8 GB and LA's 5.3 GB peaks; a cold build is
~15–25 min because caches aren't persistent, so ~80–130 builds/month fit). Build on
request is the same runner reading a wish-list (the app's "Request this area" button
increments a counter per 0.1° cell in a Worker KV; the nightly job builds cells with ≥ N
requests after a human approves the `metros.yaml` entry). Nothing here is a server the app
depends on at walk time; if the runner is down, built cities keep working.

**Hosting options, cheapest first** (checked 2026-09-30):

| Option | Free tier | Then | Pros | Cons |
|---|---|---|---|---|
| **Cloudflare Pages** (static) — chosen | unlimited bandwidth; 25 MiB/file; 20,000 files/deploy; 500 deploys/month; free `<project>.pages.dev` | free | `wrangler pages deploy Server/` and done; CDN; **no domain to buy**; today's `Server/` (589 MB, ~220 files, ≤ 5.5 MB per file) fits | 20k-file cap ≈ 60 metros; no code (the proxy would be a Worker anyway) |
| Cloudflare R2 (+ Workers) | 10 GB, 10M reads/mo, egress free; Workers 100k req/day on free `<name>.workers.dev` | $0.015/GB-mo; Workers $5/mo | no file-count cap; same account as a Worker | a production public URL needs a Worker in front or a custom domain (`r2.dev` is dev-only, rate-limited) |
| GitHub Pages / Releases | Pages 1 GB site, 100 GB/month soft; Releases 2 GB/asset | free | zero setup | soft limits, fair-use; no cache control |
| Apple-hosted assets | free for App Store/TestFlight builds | free | no account beyond Apple | On-Demand Resources is deprecated (iOS 27); managed Background Assets need an App Store submission per metro rebuild — not for our dev loop |
| Backblaze B2 + Cloudflare | 10 GB; egress free via Cloudflare | $6/TB-mo | cheapest at scale | two accounts |
| AWS S3 + CloudFront | CloudFront 1 TB/mo always free; S3 5 GB for 12 months | $0.085/GB past 1 TB | the standard | IAM/moving parts |
| Small VPS (Hetzner ~€4/mo) | none | €4–10/mo | one box runs tiles, proxy, GOES job | someone babysits it |

### 1.3 Which route — the sun ↔ speed slider

The corridor is a *set* of edges (`Corridor.edges` + per-edge `excess`,
`Engine/Sources/LikeWaterEngine/CorridorEngine.swift:22–44`); no path is ever extracted,
there are no predecessor arrays, and there is no walking speed anywhere in the repo. The
route must stay **inside the corridor and its bound** `D·(1+slack)`, otherwise a sun-greedy
search chains two half-slack detours into a 30 %-longer walk. The slack setting
("Direct…Wander", default 0.10) stays the envelope; the slider chooses *within* it; the
readout shows the price ("+2 min vs fastest").

Cost of an edge reached `τ` seconds after departure, with `w = 0.9·λ` (λ = slider 0…1):
`seconds·(1 − w·sun(edge, slot(τ)))`. λ = 0 → shortest (fastest) path; λ = 1 → minimum
shade-seconds; the 0.9 keeps time counting so no edge is free (free edges tie and
flicker). Search: Dijkstra over corridor edges with **Pareto labels (cost, distance)** per
node, pruned by `distance + dTo[v] ≤ bound` (so the destination is always reachable and the
bound always holds), dominance only between labels in the same time slot (time-dependent
costs are non-FIFO), ≤ 16 labels per node as a safety valve. < 2 ms release on 5,000
corridor edges. Slider: continuous λ with 5 detents (XCUITest can drive detents; it could
not drive the continuous scrubber reliably — LEARNINGS §7), default **Balanced (0.5)**.
Not "snap to the k-th Pareto route": the Pareto set is recomputed every 5 m and changes
size as forks pass, so detent k would silently change meaning. λ = 0 and λ = 1 runs give
the labels "fastest 24 min · 48 % sun … sunniest 26 min · 71 %". Hysteresis: keep the
previous route when the walker is on it and its remaining cost is within 5 % of the new
optimum. A `Prefer: Sun / Shade` setting flips `sun` → `1 − sun` (LA in July).

### 1.4 Loading data wherever the user looks

Already true since the last round *when a server is reachable*: both apps re-score the
visible screen on pan and download the tiles the box needs. What stops it on a real phone
and at edges: (1) no base URL configured; (2) coverage is decided by the box **centre
only** (`Apps/Shared/CityStore.swift:94–100` use `points.first`) — a screen half outside a
city fails outright; (3) nothing is ever refreshed or evicted, tiles are "file exists",
and node ids are row numbers of one pipeline build, so a server rebuild would mis-stitch
with old tiles on the phone; (4) a stale "No map data where you are — showing SoMa" after
panning into coverage. Part 2 C fixes all four, prefetches the neighbouring tile ring on
Wi-Fi, and caps the on-disk cache (400 MB).

### 1.5 Sun at the time of arrival (routing only; the ambient map stays single-instant)

`CorridorService.update` scores every corridor edge at one `Solar.position` and one sky
value at departure (`Apps/LikeWater/CorridorService.swift:139–153`). The sky model already
answers for any 15-minute time (`SkyField.condition(at:)`, DNI every 15 min, ~4 days per
fetch); missing are a pace and per-edge arrival times.

Design: **15-minute slots on the absolute clock** (`floor(t/900)`, matching the scrubber's
900 s steps and Open-Meteo's DNI step). The corridor sweep already has, per edge, the
earliest metres from the origin (`g[u]`) and the latest on any admissible path
(`bound − L − dTo[v]`) → exposed as `Corridor.fromOrigin` / `latestFromOrigin`. Each edge is
scored only for the slots its window can fall in (`latest − from = D·s − excess` ≤ 756 m
≈ 9 min at slack 0.1 → ≤ 2 slots per edge): 5,000 edges × 90-min walk = ≤ 10k edge-scores
≈ 23 ms release instead of 113 ms for all slots. Scores are cached by (absolute slot,
edge), so the next GPS fix 10 s later re-scores ~55 edges (~0.1 ms) and scrubbing the
departure time hits the cache. Beam per slot is read from the sky field at
`origin + (k+½)/K · (destination − origin)` (a fog bank to the west fades the end of a
westbound walk). Corridor edges are coloured by their *earliest-arrival* slot ("the sun
you'd find heading straight there"); route edges by their *actual* arrival slot; the scrub
label becomes "Leave 4:30 PM → arrive 4:54 PM"; a sun strip under the slider shows
sun/shade in walking order with a sunset marker ("Sun sets 7:07 PM, 17 min into your
walk"). Per-edge seconds come from the pace model in §1.7.8, so routing cost and the
displayed ETA are the same minutes.

### 1.6 External pathfinding — analysed and rejected for now

| Provider | Cost | Drawable on our Apple map? | Gives | Verdict |
|---|---|---|---|---|
| Apple `MKDirections` (walking) | free, no key, on-device | yes | polyline, distance, `expectedTravelTime`, ≤ 3 alternates, worldwide; undocumented throttling; no via points | **parked** — would only serve as a yardstick for our distances/ETA and as a no-tiles fallback; the owner chose ours-only |
| Google Routes API | 10k free/month, then $5/1,000 | **no** — terms forbid Routes "with or near a non-Google map"; results must be shown on a Google map | alternates, ETA, 25 waypoints, live closures | **rejected** (would mean replacing the whole map with Google's SDK) |
| Mapbox Directions | 100k free/month, then $2/1,000 | attribution off-map; terms unclear on third-party maps | OSM-based (our data) | nothing new; rejected |
| Valhalla / GraphHopper / ORS (open source; Stadia hosts Valhalla, 200k credits/mo free, non-commercial) | self-host or free | yes | OSM pedestrian routing anywhere, tunable costing, via points, alternates | **parked** — the backend if we ever want routing in unbuilt areas |

None of them can replace our graph: the product claim is *which side of the street* is
sunny at *this quarter-hour*; external routers return 1–3 street-level polylines with no
sidewalk side and no per-15-minute cost hook. What they would add is validity (closures,
pedestrian-only passages) and an independent ETA; we accept living without that for now
and verify timings against real walks instead (§1.7.8).

### 1.7 Owner's follow-ups, answered

**1.7.1 Ours-only: what it fixes, what stays open.**

| | Ours (graph + tiles) |
|---|---|
| Which sidewalk side is sunny | **yes** — the product |
| Every admissible path (the corridor) | **yes** |
| Sun by time of arrival | **yes** (per edge, per slot) |
| Offline / private / no per-call cost | **yes** |
| Works anywhere right now | **no** — only where tiles are built (6 places). After Part 2 F: anywhere built — the top US metros up front, any other US place within minutes-to-a-day of an approved request; never *instantly* on a first visit (the banner + request button cover that) |
| Validity: closures, construction, gated/private paths, broken stairs | **no** — OSM is a static snapshot; `access=private` not yet penalised (BACKLOG) |
| Data quality where OSM is thin | **no** — 93–100 % synthesised sidewalks in Boyle Heights/Watts, kerbs guessed, no survey outside NYC/Seattle, 30 % of Seattle buildings without height, trees unmodelled (Moorpark's main error) |
| ETA | **unmodelled today** → modelled in this round (§1.7.8) |
| GPS → which sidewalk am I on | no (on-phone HMM map-matching; BACKLOG) |
| Freshness | rebuild + redistribute (pinned builds make that safe; scheduled rebuilds parked) |

**1.7.2 Why tiles must come from a host.** A metro needs 1.4 GB of OSM extracts, ~1 GB of
Overture pickles, 5 GB RAM and 6–12 min to build — the phone can't build it; shipping it
in the app is capped by size (LA alone 290 MB; 50 metros ≈ 10 GB; the three small cities
already add 49 MB to each app) and would need an app update per rebuild. "Server side"
means a *file host*, no code: Cloudflare Pages does it free with a `pages.dev` URL. The
only server *code* ever needed is the weather proxy (owner's trigger) and the GOES job.

**1.7.3 Fog from satellite: proven, so POC first.** NOAA's operational GOES-R **Fog and
Low Stratus** product (CIMSS, Pavolonis) gives IFR/MVFR probabilities from the
0.65/3.9/11 µm channels and "greatly outperforms" the classic 3.9–11 µm difference; NWS
forecasters use it; fog.today shows the same frames for the Bay Area. The FLS product is
not on the public bucket, but its inputs/intermediates are, CONUS every 5 min, anonymous:
`ABI-L2-ACMC` (clear-sky mask), `ABI-L2-ACHAC` (cloud-top height), `ABI-L2-ACTPC` (phase),
`ABI-L2-CMIPC` (per-band imagery: C02 visible, C07 3.9 µm, C14 11 µm), `ABI-L2-CODC`
(optical depth), `ABI-L2-DSRC` (downward shortwave at the surface). The open question is
not "can fog be seen from GOES" but "how well does it map onto *our 2.5 km cells* in SF,
how late does it arrive, and how often does it beat HRRR". Hence Part 2 E. A public
endpoint is then free by construction (a static JSON file): a documented format,
attribution, no uptime promise.

**1.7.4 Is a Cloudflare domain free?** A custom domain is not (~$10/yr); none is needed:
Pages gives `<project>.pages.dev`, Workers give `<name>.workers.dev`, both free and fine
for production. Only R2's `r2.dev` is dev-only.

**1.7.5 Google vs ours.** Google: valid paths worldwide, live closures, authoritative ETA,
25 waypoints — but unusable on our map (terms), $5/1,000 after 10k/month, no sidewalk
side, no "sunniest", no offline, locations go to Google. Ours: sidewalk side, corridor,
time-aware sun, offline, free — coverage-limited, ETA unmodelled until this round.

**1.7.6 Could Apple be forced through our path?** No — `MKDirections` has no via points or
avoid areas; chaining legs costs a request per leg and still draws Apple's geometry. Moot
under ours-only.

**1.7.7 Options for the route and how they are set.** Algorithm: ours — sun-weighted
Pareto Dijkstra inside the corridor. Controls: the **slider** Fastest ↔ Sunniest (5
detents, default Balanced); **Settings**: envelope = the existing slack Direct…Wander (how
much longer the sunniest route may be, default 10 %), Prefer Sun/Shade, Pace
Relaxed/Normal/Brisk; **readouts**: "26 min · 71 % sun · +2 min vs fastest",
"1.9 km · 24 min · arrive 4:54 PM" on every layer, the sun strip, the sunset note; **tests**
set them with `-uiTestSunWeight`, `-uiTestPace`, `-uiTestPrefer`.

**1.7.8 Our own timings — can they be accurate?** Yes, to about ±10 % on urban walks,
which is what nav apps achieve, because every term is known or measurable:
- *distance* — sidewalk-level graph, correct to a few %;
- *base pace* — 1.4 m/s (5 km/h, the flat-walking assumption everyone uses), settable
  Relaxed 1.1 / Normal 1.4 / Brisk 1.7;
- *slope* — the bundle has 10 m terrain, so each edge gets a grade from `TerrainGrid` at
  its two ends (2 samples, ~50 ns each) and Tobler's hiking function normalised to the base
  pace: +10 % grade → 0.70×, −5 % → 1.19× (fastest), −15 % → 0.84× (a Nob Hill block is 2× slower, a
  whole SF walk 10–20 %);
- *crossings* — `EdgeFlag.crossing` edges get a wait (default 12 s; the pipeline can later
  split signalised from unsignalised via OSM `crossing=traffic_signals`, BACKLOG);
- *stairs* — `EdgeFlag.steps` at 0.6× pace;
- *the walker* — once 300 m of the route has been covered, the measured pace (progress
  along the route ÷ elapsed) is blended 50/50 with the setting for the remaining ETA, and
  an exponential average across walks is persisted as the user's pace (this is what makes
  the ETA converge on the second walk, like any nav app).
Routing and ETA use the *same* per-edge seconds, so "+2 min vs fastest" means minutes, not
metres. Accuracy is verified against real arrivals on the owner's walks (debug line at
arrival: predicted vs actual; Part 3 #9).

**1.7.9 Does time-of-arrival depend on the router?** With our path every edge's arrival
time is exact (seconds along the route) → sidewalk-side sun at that slot. There is no
second fidelity level under ours-only.

**1.7.10 USA only for now — what would change abroad** (nothing in the design is US-bound):
map data (Geofabrik, Overture, timezones) works anywhere; terrain abroad is ~30 m SRTM
instead of 10 m, so hill shadows are coarser; sidewalk surveys (NYC, Seattle) and tree
canopy are US-only → synthesis defaults elsewhere (as LA already runs); Open-Meteo is
global but 15-minute direct-beam data comes only from HRRR (North America) and
ICON-D2/AROME (central Europe), and microclimate resolution follows the local model;
GOES covers the Americas only (Europe/Asia would be Meteosat/Himawari — same idea,
different data); Pages is a global CDN. First non-US candidate if ever: Toronto (Canada's
2.5 km HRDPS model gives real microclimate weather).

---

## Status (2026-10-01)

| Milestone | State |
|---|---|
| E — GOES POC | built + tested; logger running every 15 min on the owner's Mac; verdict after ≥ 10 daytime days (`goes_report.py`) |
| F — coverage growth | built + tested; Portland built end to end; the ten other metros not built yet (disk: ~28 GB free; run `build_places.py` when wanted) |
| A — route + ETA + slider + time-of-arrival sun | done; LEARNINGS §11 has Part 3 #1–#6; ETA vs real walks (#9) needs the owner's walks |
| C — load anywhere | done; LEARNINGS §12 |
| D — publish-ready | done and tested locally (staged Pages site, S3 layout, Worker under `wrangler dev`, auto-build dispatch against a fake GitHub); going live is the owner's step (README "Hosting") |

Deviations: the Worker lives in `Worker/` (`Server/` is gitignored); `PaceEstimator` is in
the engine (unit-testable); pace seconds are per direction (slope); crossings are not
discounted for sun (LEARNINGS §11.2); the hysteresis/route walk test uses `stepButton`
following the route; the A5 metro test is `testNewYorkTimeAwareRouteFindsMoreSun` (Times Sq →
Union Sq at 1 pm, the biggest measured effect, LEARNINGS §11.1) rather than the planned
December-sunset case; the timeline is built on every layer, not only when `sunWeight > 0`.

## Part 2 — What to build

Order: **E** (GOES POC script + logger started on day 1 so two weeks of data accrue while
the rest is built) → **F** (coverage scripts, then the new-place builds run unattended in
the background) → **A** → **C** → **D**. Rough effort: E 1 day + 2 weeks of unattended
logging, F 1 day + ~10 min of compute per new metro, A 2–3 days, C 1.5 days, D ½ day.
Parked items go to `BACKLOG.md` with why/what/trigger/effort.

### E. GOES fog proof-of-concept (decide, then build out only if it wins)

- `Pipeline/goes_poc.py` (new; deps `s3fs`/`boto3` anonymous, `xarray`, `netCDF4`,
  `pyproj`): fetch the latest `ABI-L2-ACMC`, `ABI-L2-ACHAC`, `ABI-L2-ACTPC` and `CMIPC` C02
  from `s3://noaa-goes18/` (GOES-West), crop to the Bay Area box, project the ABI
  fixed-grid coordinates to lat/lon, aggregate onto the weather lattice cells
  (`OpenMeteoSky.latticePoints`, 0.0225°), classify each cell: clear / low cloud (cloud-top
  height < 1 km, liquid phase → fog/stratus, beam ≈ 0) / mid-high cloud (beam from `CODC`
  optical depth if present, else 0.3) / unknown, with the scan time and the data latency.
- `Pipeline/goes_log.py`: every 15 min (launchd on the owner's Mac for the POC) append one
  row per cell: GOES class + beam, Open-Meteo `cloud_cover_low`/DNI-derived beam for the
  same cell and time (`lwtool sky --json` gives the app's request shape), and SFO/OAK METAR
  sky cover (NWS `api.weather.gov` observations, free) as ground truth near the coast.
- `Pipeline/goes_report.py`: after ≥ 10 days, for 9 am–5 pm: agreement rate GOES vs HRRR,
  who matches METAR when they disagree, median GOES latency, and the burn-off timing error
  of each on fog days. Decision rule (record in LEARNINGS §9.5): build the job if GOES is
  right in ≥ 70 % of disagreements and its latency ≤ 15 min.
- If it wins (later, not this round): a scheduled job (GitHub Actions cron at 30 min fits
  the free 2,000 min/month; 10-min cadence needs the Mac or a €4 VPS) writes
  `sky/goes/<city>.json` to the static host; `WeatherService` gains a `SkySource.observed`
  preferred for |now − t| ≤ 20 min; Sun Map's status says "Fog (satellite, 9:50)". The JSON
  format is documented in README as a public, best-effort endpoint.
- Pipeline test: `tests/test_goes.py` — the classifier on a saved 2-scan fixture (fog
  morning + clear afternoon) maps Ocean Beach to low cloud and the Mission to clear.

### F. Coverage growth — new US places (scheduled rebuilds stay parked)

- `Pipeline/metros.yaml`: one entry per place — `id, name, extract` (Geofabrik path),
  `places` (the `--place` names), `survey?`, `demo`, `min_component?`. Seeded with the
  three built metros plus the next ten US metros by population not yet built: Chicago
  (`north-america/us/illinois`), Houston / Dallas / Austin / San Antonio (`texas`, one
  extract), Phoenix (`arizona`), Philadelphia (`pennsylvania`), San Diego
  (`california/socal`, already cached), San Jose (`california/norcal`), Boston
  (`massachusetts`), Washington (`district-of-columbia`). The owner edits the list;
  nothing is built that isn't in it.
- `Pipeline/build_places.py`: for each entry not yet in `Server/manifest.json` (or
  `--only id`): download the extract into `cache/pbf/` if missing (resumable `curl` from the
  Geofabrik index), run `build_metro.py` with the entry's arguments under
  `/usr/bin/time -l` (as `build_metros.sh` does), append minutes / peak RAM / sizes /
  synthesis share to `cache/build_log.jsonl`, and run `publish.py` when `--publish` is
  given. Sequential (RAM), `--max-minutes` budget, resumes after a failure.
- `Pipeline/requests_to_places.py`: turns the wish-list into review-ready `metros.yaml`
  entries — input is the Worker's KV export once D's endpoint exists, or until then the
  app's debug log of requested cells; each 0.1° cell is reverse-geocoded (Nominatim,
  cached) to a city and its state extract. The human stays in the loop (the owner approves
  the entry) until volumes justify automating it.
- Scheduling: `Pipeline/launchd/com.likewater.build.plist` (nightly 02:00,
  `build_places.py --publish`), installed by the owner if wanted; a GitHub Actions workflow
  `.github/workflows/build-places.yml` (`workflow_dispatch` + weekly cron, 7 GB runner,
  `actions/cache` for extracts) written but inert until the owner adds hosting secrets.
- App side: nothing beyond C — new manifest entries just appear; the banner names the
  nearest built city.
- Verify: build Portland (`north-america/us/oregon`) end to end as the first new place; a
  `MetroUITests` case on it (`-uiTestCenter 45.5231,-122.6765` paints and shows "PDT");
  confirm the Pages limits still hold after ten more metros (file count < 20k, largest
  tile < 25 MiB; expected +1.5–2 GB).
- Measure for LEARNINGS §10's table: minutes, peak RAM, nodes, tiles, MB, stranded %, kerb
  coverage and synthesis share per new city (`lwtool coverage`); where OSM is thin, say so.

### A. Route + ETA + slider + time-of-arrival sun

**A1 — Arrival windows** — `Engine/Sources/LikeWaterEngine/CorridorEngine.swift`
- `Corridor` (L22–44): add `fromOrigin: [Double]`, `latestFromOrigin: [Double]` (parallel
  to `edges`). `CorridorScratch` (L64–82): add `edgeFrom` (init `.infinity`), `edgeLatest`
  (init `-.infinity`), reset with `edgeExcess`.
- Sweep (L201–216): after `guard total <= bound`, `edgeFrom[e] = min(edgeFrom[e], gu)`,
  `edgeLatest[e] = max(edgeLatest[e], bound - edgeLen[e] - h)`; copy out at L223–228.
- Test `CorridorTests.testArrivalWindowsBracketEveryCorridorEdge` (5×5 grid, slack 0.4):
  `from ≤ latest`, `latest − from ≥ D·s − excess − 1e-6`, shortest-path edges have
  `latest − from == D·s`. Move the private `gridGraph` helper (`CorridorTests.swift:6`) to
  `TestGraphs.swift` so the new test files can use it.

**A2 — Pace model + timeline** — new `Engine/Sources/LikeWaterEngine/SunTimeline.swift`
- `WalkingPace { metresPerSecond }` (`.relaxed 1.1`, `.normal 1.4`, `.brisk 1.7`) and
  `PaceModel { pace, crossingWaitSeconds = 12, stepsFactor = 0.6 }` with
  `edgeSeconds(graph:edges:terrain:) -> [Double]`: `len / (pace · tobler(grade))` with
  Tobler normalised to 1.0 on the flat (`exp(−3.5·|g + 0.05|) / exp(−0.175)`), grade from
  `TerrainGrid.elevation` at the edge ends (nil terrain → flat), `+ crossingWait` on
  `EdgeFlag.crossing`, `÷ stepsFactor` on `EdgeFlag.steps`. Computed once per corridor
  (≤ 5k edges, ~1 ms) and used by both the timeline and the route, so "+2 min" is minutes.
  Tests: a 10 % uphill edge takes 1/0.70 of the flat time; a crossing adds 12 s; stairs
  1/0.6.
- `SunTimeline { departure, slotSeconds = 900, firstSlot (absolute), slotCount,
  sun: [[Float]] (slot-major, corridor-local edge index, .nan = unreachable in that slot),
  beam: [Float] per slot, sunUp: [Bool], sunset: Date?, scoredPairs, cacheHits, computeMs;
  slot(atSeconds:), effectiveSun(edge:slot:) (sun×beam; nearest scored slot ±2, else 0.5) }`
  plus `init(testing:…)` for fakes.
- `SunSlotCache` (final class): `[Int64: Float]` keyed `absoluteSlot << 32 | edge`;
  `drop(before:)`, `removeAll()`.
- `SunTimelineBuilder.build(graph:corridor:origin:destination:departure:pace:slotSeconds:scorer:cache:sky:)`:
  per slot k, `Solar.position` at the slot centre at the origin; skip scoring when the sun
  is down (`sunUp[k] = false`; `SunScorer` returns zeros anyway, `SunScorer.swift:59`);
  collect the uncached edges whose `[fromOrigin, latestFromOrigin] / pace.metresPerSecond`
  window, widened by one slot on each side (per-edge seconds differ from metres/pace by
  slope and crossings), intersects slot k; one `scorer.score(graph:edges:sun:)` call per
  slot; beam from `sky?.condition(latitude:longitude:at:sunElevation:)` at the
  interpolated point; `sunset` from `Solar.daylightWindow` if inside the walk.
- Tests `SunTimelineTests`: only reachable slots scored (≤ 2 per edge at slack 0.1 with an
  empty `BuildingStore`); absolute slots reused across a 10 s later departure
  (`cacheHits == scoredPairs` of the first build); sun-down slots unscored; beam follows a
  two-cell fog-west field along the walk.

**A3 — Route** — new `Engine/Sources/LikeWaterEngine/RouteEngine.swift`
- `RoutePreference { sun, shade }`; `Route { nodes, edges, metres, seconds, sunSeconds,
  edgeSun, edgeSlot, arrivalSeconds (per node), sunWeight, labelsExpanded, maxLabelsAtANode,
  computeMs; sunFraction }`; `RouteError.noRoute`.
- `RouteEngine.maxSunWeight = 0.9`;
  `route(graph:corridor:labels:origin:timeline:edgeSeconds:sunWeight:prefer:maxLabelsPerNode: 16)`
  — local CSR over `corridor.edges` (node → local id), flat label arrays (node, cost,
  dist, seconds, pred, edge), the engine's internal `MinHeap` on cost, per-node
  non-dominated labels on (cost, dist), dominance only within the same slot of `seconds`,
  prune `dist + dTo[v] > bound`, first pop at `labels.destNode` wins; `timeline == nil` →
  cost = seconds. `edgeSeconds` comes from `PaceModel` (A2), parallel to `corridor.edges`.
- `evaluate(edges:from:…) -> Route?` (a given edge sequence's cost; nil if infeasible) —
  for hysteresis and the ladder labels.
- `ladder(…, weights: [0, 0.1, …, 1])` → dedupe by edge sequence, Pareto on
  (seconds, sunSeconds), sorted by seconds (for `lwtool` and labels; per fix only λ = 0
  and λ = 1 are run).
- `shouldKeep(previous:candidate:tolerance: 0.05)`.
- Tests `RouteTests`: λ = 0 is the shortest path (`metres == corridor.distance`); a sunny
  detour inside slack 0.5 is taken, at 0.4 it isn't; seeded random sun on a 12×12 grid for
  all λ: `edges ⊆ corridor.edges` and `metres ≤ bound`; an edge sunny only in slot 1 is
  chosen only when reached in slot 1; the ladder is Pareto and monotone; `prefer: .shade`
  flips the choice; `evaluate` matches `route`'s cost; `shouldKeep`.

**A4 — `lwtool route`** — `Engine/Sources/lwtool/main.swift` (new case beside `corridor`,
L165–186): `--from --to [--slack] [--at ISO] [--pace] [--sun-weight λ] [--prefer sun|shade]
[--ladder] [--departure-only] --out`. Prints fastest/chosen/sunniest (min, % sun), label
stats, `scoredPairs/(edges×slots)`, ms; `--departure-only` fixes every slot's sun at
departure (the Part 3 baseline). GeoJSON: one `LineString` per route with
`sunWeight, seconds, metres, sunFraction`.

**A5 — Metro test** — `MetroTests.testNewYorkTimeAwareRouteSeesTheSunset`: Times Sq →
Union Sq departing 2026-12-21 16:00 EST (sunset 16:32): the time-aware λ = 1 route differs
from the departure-only one (edges, or sunFraction by ≥ 0.1); `metres ≤ D·1.1`;
timeline < 150 ms × slow, route < 20 ms × slow.

**A6 — Service** — `Apps/LikeWater/CorridorService.swift`
- State: `slotCache = SunSlotCache()` (reset in `prepare`, L72–77, with `scorer`/`scratch`),
  `lastContext` (corridor, labels, origin, timeline, edgeSeconds, departure), `lastRoute`.
- `update(user:slack:layer:date:pace:sunWeight:prefer:)`: after `corridor` (L131–132)
  compute `edgeSeconds = PaceModel(pace…).edgeSeconds(graph:edges:terrain: city.bundle.terrain)`;
  build the timeline when `layer == .sun || sunWeight > 0` (sky fetched as at L144–149,
  passed as `SkyField?`); `RouteEngine.route`; hysteresis via `evaluate` + `shouldKeep`
  when the origin lies on `lastRoute`; λ = 0 and λ = 1 routes for the labels (only with a
  timeline); corridor edge views get `sunBucket` from
  `timeline.effectiveSun(i, slot(fromOrigin[i]/pace))` and a new `beam`;
  `try Task.checkCancellation()` after `prepare` and after the timeline.
- `reroute(sunWeight:prefer:) -> RouteView?` reuses `lastContext` (one Dijkstra, no
  labels/corridor/scoring) for slider moves.
- Types: `CorridorEdgeView.beam`; `RouteView { coordinates, edgeBuckets, edgeBeams,
  seconds, metres, sunFraction, fastestSeconds, fastestSunFraction, sunniestSeconds?,
  sunniestSunFraction?, strip: [StripSegment{start, end, bucket, beam}], sunsetSeconds?,
  sunsetAt?, kept }`; `CorridorSnapshot.route`, `.departure`, `.arrival`, `.timelineMs`,
  `.routeMs`, `.scoredPairs`.

**A7 — Model** — `Apps/LikeWater/AppModel.swift`
- `sunWeight` (UserDefaults `sunWeight`, default 0.5), `pace` (`walkingPace`, 1.4),
  `prefer` (`routePrefer`), `routeVersion` (separate from `overlayVersion`, so a slider
  move replaces only the route overlay — today `render` rebuilds everything,
  `CorridorMapView.swift:106–107`).
- `PaceEstimator` (`Apps/Shared/PaceEstimator.swift`): fed each GPS fix with the walker's
  progress along the current route (`arrivalSeconds`/metres of the nearest route node);
  after ≥ 300 m and ≥ 3 min it yields a measured pace, blended 50/50 with the setting for
  the remaining ETA; across walks an exponential average is persisted as `learnedPace`
  (UserDefaults) and becomes the default `pace` when the user hasn't picked one. Debug
  stats show "predicted 24:10 · actual 23:40" at arrival (the accuracy log for Part 3).
- Launch overrides (L110–141): `uiTestSunWeight`, `uiTestPace`, `uiTestPrefer`.
- `setSunWeight` → 60 ms debounce → `service.reroute` → `snapshot.route`, `routeVersion += 1`;
  `setPace`/`setPrefer` → `scheduleRecompute()`; `recompute` (L255–256) passes the three.
- Readouts: `routeReadout` ("26 min · 71 % sun · +2 min vs fastest"), `etaText`
  ("1.9 km · 24 min · arrive 4:54 PM", city zone, on every layer), `sunsetNote`,
  `scrubTimeText` gains "→ arrive h:mm" when a route exists.

**A8 — Map** — `Apps/LikeWater/CorridorMapView.swift`
- Replace `CorridorBand0/1/2` (L5–7) with `CorridorBand: MKMultiPolyline { band, beam }`
  (one overlay per band × beam rounded to 0.1, ≤ 30) and add `RouteLine: MKMultiPolyline
  { band: Int?, beam }` (nil band = accent colour on Crossings/Interest). `render`
  (L105–136) groups by (band, beam); `renderRoute` removes only `RouteLine` overlays and
  adds the route last, width 9, round caps; corridor colours × 0.6 alpha when a route
  exists; `rendererFor` (L199–216) fades by `overlay.beam` instead of the global beam.

**A9 — Panel** — `Apps/LikeWater/ContentView.swift`
- In `bottomControls` (L144–199): `etaText` in the readout; `routeControls` = route readout,
  `Slider(value:, in: 0...1, step: 0.25)` (`sunWeightSlider`, captions Fastest/Sunniest),
  `SunStrip` Canvas (`sunStrip`, accessibility value "sun 71 % · shade 29 % · sunset at
  17 min"), `sunsetNote`. Shown on all layers when `snapshot.route != nil`.
- `sunScrubber` (L203–233) label change (A7); legend (L245–249) gains "coloured for when
  you'd reach each street".
- `SettingsSheet` (L273–323): "Walking pace" Relaxed/Normal/Brisk (`paceSetting`),
  "Prefer" Sun/Shade (`preferSetting`).

**A10 — UI tests** — `UITests/LikeWater/RouteUITests.swift`: `testSunWeightChangesTheRoute`
(SoMa → Caltrain, Sun layer, `-uiTestDate 2026-09-23T17:30:00Z -uiTestSky clear`,
`-uiTestSunWeight 0` vs `1`: minutes ≥, sun % ≥, not both equal — else retry at
`-uiTestSlack 0.3` and record a singleton Pareto set); `testSliderDetentsMoveTheReadout`
(`adjust(toNormalizedSliderPosition: 1.0)`); `testSunsetMidWalkIsAnnounced` (depart
18:50 PDT, SF sunset 19:07 → `sunsetNote` contains "into your walk");
`testEtaIsShownOnEveryLayer`; `testRouteStaysWhileWalkingIt` (`-uiTestDebug`, `stepButton`
×6: minutes strictly decrease, `kept` true on ≥ 4 steps). Existing
`testEachLayerPaintsTheCorridor` / `testSunScrubberMovesTheSun` must still pass
(`subtitle` and `sunReadout` unchanged).

### C. Load data anywhere: coverage, pinning, eviction, prefetch, the not-built state

**C1** — move `MetroIndex` from `Apps/Shared/CityCatalog.swift:46–91` to
`Engine/Sources/LikeWaterEngine/MetroIndex.swift` (Foundation-only; `tile(containing lat:lon:)`),
adding optional `format`, `built`, `overture`, `source` (old indexes still decode);
`buildKey` ("20260930065716"), `isNewer(than:)`, `extendsBeyond(_ box:)`.
`MetroTests.stitch` (L27–38) and `lwtool.loadCity` (L90–105) switch to
`JSONDecoder().decode(MetroIndex.self)`. Test `MetroIndexTests` (decodes
`Server/seattle/metro.json` when present and an inline fixture without `built`;
`tiles(intersecting:)`, `extendsBeyond`, `isNewer`).

**C2** — `CityCatalog.swift`: `RemoteManifest.Metro.built`; `CoverageState { covered,
partial, notBuilt(nearest: String?, km: Double?), noServer }`; `MetroDescriptor.covers(box)`
/ `coverage(of box)` (partial only where the box extends **outside the metro's bbox** —
inside it, a cell without a tile is water or no streets, which counts as coverage);
`localCity(covering box:)` (bbox intersects; partial when not contained);
`metro(covering box:)` (local first, else manifest entries whose bbox intersects → index
fetched into `Cities/<id>/<buildKey>/metro.json`); `coverageState(for box:)`;
`CoverageRequest.send(cell:)` POSTs the 0.1°-rounded cell to `LWCoverageRequestURL` only
when that key is set (button hidden otherwise; nothing is sent without it). `anyCoverage`
keeps the point form.

**C3** — `CityStore.swift`: `city(covering points:)` (L89–117) decides on
`BBox.around(points)`, not `points.first`; `LoadedCity.coverage`, `.built`; stitch key
includes `buildKey` (never mixes builds); `SunService.field(in:)` passes centre + 4 corners
and `SunField.coverage`; on `.noCoverage` it fetches the sky anyway and throws
`SunServiceError.notCovered(state, sky)`.

**C4** — models/UI: 150 ms pan debounce in `SunMapModel.mapRegionChanged` (L112–120) and
`AppModel.mapRegionChanged`; `Task.checkCancellation()` at the await boundaries (the
stale-field check already exists — `SunMapModel.swift:163`, `AppModel.swift:83` — what's
wasted today is CPU); status "Only part of this screen has sun data" from
`field.coverage`; "showing SoMa" derived from `centerIsFallback && !userMovedMap` instead
of the write-once `outsideCity` (`SunMapModel.swift:173–175`, `AppModel.swift:165`);
`coverageBanner` ("No sun data here yet", nearest built city, sky line kept) +
`requestCoverageButton` in both apps. With a destination set in an unbuilt place, Like
Water shows the banner and the request button instead of a corridor (ours-only: no
fallback route).

**C5 — build pinning**: `Pipeline/build_metro.py:257` adds `built` to the manifest entry
(regenerate `Server/manifest.json`); `CityCatalog.localMetros()` (L219–238) accepts both
the flat sideload layout (`install_phone.sh` unchanged) and `Cities/<id>/<buildKey>/`,
keeping the newest `built` per id; when the manifest lists a newer build, its index is
fetched into its own directory and the old build keeps serving until a stitch from the new
one succeeds, then `removeStaleBuilds(of:keeping:)` deletes the siblings (never the
directory of the current metro).

**C6 — eviction + prefetch**: `Engine/Sources/LikeWaterEngine/CachePolicy.swift`
(`CacheEntry { key, bytes, lastUsed }`, `evictions(entries, capBytes, protected) -> [key]`,
LRU until under cap, protected never returned; unit-tested); `CityStore` keeps
`Cities/ledger.json`, touches on read/download, evicts past 400 MB protecting the current
stitch, in-flight downloads and loaded singles; `prefetchRing` after a successful stitch
(`Task.detached(priority: .background)`, a session with `allowsExpensiveNetworkAccess =
false` and `allowsConstrainedNetworkAccess = false`), counted in the ledger,
`LoadedCity.prefetched` in the debug stats.

**C7 — config**: `project.yml` → XcodeGen `info.properties` with
`LWBundleBaseURL: "$(LW_BUNDLE_BASE_URL)"` and `LWCoverageRequestURL:
"$(LW_COVERAGE_REQUEST_URL)"`, both build settings empty by default (nil at runtime, as
today); verify `GENERATE_INFOPLIST_FILE: YES` merges with `info.properties`, else move the
four `INFOPLIST_KEY_` entries into `properties`.

**C8 — tests**: `UITests/SunMap/CoverageUITests.swift` — `testUncoveredAreaShowsTheBannerAndTheSky`
(`-bundleBaseURL http://127.0.0.1:8765/ -uiTestCenter 45.5231,-122.6765 -uiTestSky clear`:
banner text, `skyStatus == "Clear sky"`, no request button without the URL key);
`testPartialCoverageAtTheMetroEdge` (Seattle north edge `47.755,-122.33`);
`testPanningIntoCoverageClearsTheDemoStatus`. `MetroUITests.testPanningOutOfSeattleSaysSo`.
Like Water: `testDestinationInAnUnbuiltPlaceShowsTheBanner`. Existing `MetroUITests` (3),
`OnDemandDownloadUITests`, `AmbientSunUITests`, `MetroCorridorUITests` must keep passing
(singles stay flat `.lwbundle` files in `Cities/`; `-uiTestFreshDownloads` still wipes
`Cities/`; eviction must protect a just-downloaded single).

### D. Publish-ready (no deploy by an agent; the owner chooses when and runs the login)

- `Pipeline/publish.py`: `--target pages` runs `wrangler pages deploy Server/ --project-name
  likewater-tiles` (free, `*.pages.dev`; a `_headers` file sets `max-age=300` for
  `manifest.json` and `*/metro.json`; tiles are under `metros/<id>/<buildKey>/` on Pages
  too, so they can be cached for a year — Pages' own default is `must-revalidate`);
  `--target s3` uploads to any S3-compatible bucket (R2 or AWS) under
  `metros/<id>/<buildKey>/…` with explicit `Cache-Control`; writes the manifest last;
  `--dry-run` lists what it would do; credentials from the environment only.
- `Server/worker/` skeleton (`wrangler.toml`, `src/index.ts`): `GET /sky?cells=…` (per-cell
  cache, 15 min, upstream Open-Meteo with an optional key — **not enabled**; the owner's
  scaling trigger), `POST /coverage-request` (KV counter per 0.1° cell), `GET /health`.
- README "Hosting": the §1.2 table, the three commands to go live on Pages (create project
  → `publish.py --target pages` → set `LW_BUNDLE_BASE_URL`), and the triggers. `.gitignore`
  keeps `Server/` out.

### Parked in `BACKLOG.md` (write each with why/what/trigger/effort)

Apple `MKDirections` as a distance/ETA yardstick and a no-tiles fallback (dropped by the
ours-only decision; trigger: users stuck in unbuilt places, or ETA disputes) · non-US
metros (first candidate Toronto; §1.7.10) · weather proxy + paid key (trigger ~300 daily
users or ads/subscription) · GOES job build-out (after the POC verdict) · scheduled
rebuilds for freshness (OSM daily, Overture monthly; safe thanks to pinned builds; trigger:
a user-reported stale street) · fully automatic build-on-request (no human approval;
trigger: the wish-list outgrows nightly review) · stable node ids (bundle v4) for per-tile
incremental builds · signalised-vs-unsignalised crossing waits from OSM
`crossing=traffic_signals` · Pareto tick marks / 3-stop picker if measured Pareto sets are
tiny · turn hints along the route · Valhalla for routing in unbuilt areas · GPS
map-matching to the sidewalk side · penalise `access=private` in the corridor.

### Docs (same turn as the code, per `CLAUDE.md`)

`README.md`: "The route" (cost, bound, Pareto labels, hysteresis, pace model), "Coverage,
builds and eviction", "Hosting", "Satellite fog (POC)", "New places" (`metros.yaml`,
`build_places.py`); test table rows; counts. `LEARNINGS.md`: §9.5/§9.6 the GOES POC
numbers; §11 "A route inside the corridor" with the Part 3 numbers; §12 "External routers"
(why ours-only: Google's non-Google-map clause, Apple's limits, what we gave up); §10
table rows for each new metro; §10.8 bullets for coverage-by-box, build pinning, eviction,
the stale SoMa status, the ETA-vs-PRD reversal. `BACKLOG.md`: the parked list.
`CLAUDE.md` ground rules: "the route never leaves the corridor or its bound;
`lwtool route --departure-only` is the baseline"; "ours-only: no external routing APIs;
the pipeline builds places, the app never routes outside built tiles"; "the forecast is
the sky unless an observation is younger than 20 min" (once GOES ships).

---

## Part 3 — Verification and measurements

**Run after each milestone** (all must pass): `cd Engine && swift test` (54 → ~68 with
A/C tests); `xcodegen generate`, then `xcodebuild test -scheme LikeWater` (14 → ~20) and
`-scheme SunMap` (12 → ~16) on the simulator with `cd Server && python3 -m http.server 8765`
running for the metro/coverage tests; `cd Pipeline && pytest` (13 → 15 with the manifest
`built` field and the GOES fixture). Then `./install_phone.sh` (phone unlocked) and one
real SoMa → Caltrain walk on the phone late in the afternoon, slider at Sunniest.

**Record in `LEARNINGS.md`** (via `lwtool`, release build):

1. Time-aware vs departure-time route (`lwtool route --sun-weight 1` vs `--departure-only`)
   on 5 walks × 3 departures (9 am, 1 pm, 60 min before sunset): share of cases where the
   edge sequence differs, and the sun-fraction gap. Walks: SoMa→Caltrain, Union Sq→Ferry
   Building, Times Sq→Union Sq, Pike Place→Capitol Hill, Downtown LA→Arts District.
2. Pareto set size (`--ladder`, 11 λ values) at slack 0.1 and 0.3 — decides slider vs a
   3-stop picker.
3. Timeline cost: `scoredPairs/(edges×slots)` and ms at slack 0.1/0.3/0.6; cache hit rate
   on the second fix of a simulated walk.
4. Route cost: ms, labels expanded, max labels at a node, cap hits.
5. Hysteresis: route changes per km on a simulated walk (`stepForward`), tolerance 0 vs
   0.05.
6. Price of sun: minutes paid per +10 % sun along the ladder, per walk.
7. Slot size: bucket flips per edge at slot roll-over for 10 vs 15 min (decides whether
   `slotSeconds` stays 900).
8. Coverage: bytes on disk after visiting all built places with/without the 400 MB cap;
   prefetch hit rate on a one-tile pan; time-to-banner in Portland before it is built;
   stale scores avoided by the 150 ms debounce over a 5-swipe pan.
9. ETA accuracy: predicted vs actual arrival on the owner's real walks (debug line at
   arrival), split by flat vs hilly and by number of crossings; target ±10 %.
10. GOES POC (after ≥ 10 days): agreement GOES vs HRRR 9 am–5 pm, who matches METAR on
    disagreement, median latency, burn-off timing error — the build-out decision.
11. New places (F): per-metro build minutes, peak RAM, MB, stranded %, synthesis share;
    total `Server/` size and file count against the Pages limits.
