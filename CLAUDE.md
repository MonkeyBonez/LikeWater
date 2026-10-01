# Like Water

iOS walking app: paints the corridor of streets to a destination and colours it by
crossings, interest, or sun. Two app targets (`LikeWater`, `SunMap`) share one Swift
engine (`Engine/`, a SwiftPM package) and per-city binary bundles built by the Python
pipeline in `Pipeline/`. See `README.md` for architecture and how to run.

## Keep `LEARNINGS.md` current

`LEARNINGS.md` is the running record of what we have learned building this — data-source
verdicts, measured effects, wrong assumptions we had to unlearn, and the process we ended
up needing beyond "download OSM". It has been written up through three cities (San
Francisco, Berkeley, Moorpark), the weather layer (§9) and the tiled metros — New York,
Los Angeles, Seattle (§10).

**Whenever you learn something new here — a data source that did or didn't pan out, a
measured effect, a bug that came from a bad assumption, a difference between places —
add it to `LEARNINGS.md` in the same turn.** Prefer a measured number over an opinion;
say what tool produced it (`lwtool …`, a `--no-*` baseline diff, a test). Update the
urban-vs-suburban table and the "process we needed" table when a new step or city changes
them. Don't move things out of it into chat; the doc is the memory.

## `BACKLOG.md` is where deferred work goes

When we decide to do something later, write it into `BACKLOG.md` with enough context to
pick it up cold (why, what, trigger, effort). When an item is done, delete it from there and
record what it taught in `LEARNINGS.md`.

## Ground rules that came from experience

- Big cities are metros: `Pipeline/build_metros.sh [seattle|nyc|la]` writes tiles to
  `Server/`; `lwtool … --metro Server/<id>` stitches them like the app does. Serve with
  `cd Server && python3 -m http.server 8765` for the metro UI tests.
- Phone: `./install_phone.sh` installs both apps and sideloads `Server/` metros into each
  app's Application Support (no public server yet). The phone must be unlocked, or the
  developer disk image won't mount (error 0xE80000E2).
- Measure, don't eyeball: `Engine/.build/release/lwtool {coverage,sun,sunbias,corridor}`,
  the pipeline's `--no-sidewalk-synthesis` / `--global-default-height` /
  `--terrain-margin-m 0` baselines, `--max-height 100` / `--no-far` / `--no-terrain` for
  shadow reach, and diffing two bundles' GeoJSON.
- A tag named after what you want is not evidence you have it. Classify edges by the
  physical thing.
- Any global default in per-place data is a bug waiting for the place it doesn't fit.
- A fast-passing UI test is a smell; dump the accessibility tree.
- Nothing map-shaped is fetched at runtime by the apps. Cities are bundles; the pipeline
  builds them. The one runtime fetch is the live sky (Open-Meteo, `WeatherService`),
  because weather cannot be built ahead of time; it must always degrade to the clear-sky
  map when it fails.

- The route never leaves the corridor or its bound; crossings are never discounted for sun.
  `lwtool route --compare` (time-aware vs departure-only) is the baseline.
- Ours-only: no external routing APIs; the pipeline builds places, the apps never route
  outside built tiles (an unbuilt place is a banner, not a fallback route).
- Never stitch tiles of two builds; never evict files a configured server can't give back.
- Publishing (Pages, Worker deploy) is the owner's step. Agents stage and test locally
  (`publish.py --dry-run`, `wrangler dev`) and stop there.

## Current plan

`PLAN.md` is the approved plan for the current round (route + ETA inside the corridor,
time-of-arrival sun, load-anywhere fixes, free static hosting, US coverage growth, GOES fog
POC) and records the owner's standing decisions: ours-only pathfinding (no Apple/Google
routing), USA only for now, the owner owns scaling plans. Work from it; when a milestone
lands, tick it off there and move what it taught into `LEARNINGS.md`.
