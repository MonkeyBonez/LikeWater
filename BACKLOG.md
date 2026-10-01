# Backlog

Things we have decided to do later, with enough context to pick them up cold.
Newest at the bottom. Move an item to `LEARNINGS.md` when it is done and taught us something.

## Fog from satellite, not forecast (GOES-West observation server)

**Why:** the sky layer uses the HRRR forecast via Open-Meteo. It resolves the SF fog
gradient (LEARNINGS §9.3) but it is a *prediction*, rerun hourly; when the marine layer
burns off at 11:20 instead of the forecast noon, the map says "fog, shade doesn't matter"
for 40 minutes of full sun.

**What:** a small scheduled job (every 5–10 min) that
1. pulls the latest GOES-West visible + IR frame over the Bay Area from the public AWS
   bucket (`noaa-goes18`, ABI L1b/L2, ~2 km/px, 5-min cadence);
2. classifies each of our weather lattice cells as fog / cloud / clear (visible vs IR
   channel comparison to separate low fog from high cloud and bright ground) and
   estimates a beam strength per cell;
3. writes a few-KB JSON next to the city bundles on the same static host.

The app fetches it like the forecast, prefers it for "now", and keeps HRRR for any
scrubbed future time (a satellite can't see ahead). Same shape as the map data: compute
once server-side, ship a small file, never make the phone do science.

**Trigger:** SF users saying the fog timing is wrong often enough to notice. Elsewhere
the forecast is probably fine.

**Effort:** 1–2 days; the classification is the fiddly part. Validate by logging satellite
vs forecast side by side for two weeks of SF mornings and measuring who was right.

**Reference:** fog.today shows the same frames cropped to the Bay Area.

## Tree canopy

Moorpark's dominant midday error is trees, not houses or hills (LEARNINGS §3.7). NLCD
Tree Canopy Cover (30 m, US-only) as a per-edge shade factor is the cheap first step;
LiDAR-derived canopy height where a city publishes it is the real one.

## Corridor should not route through private tracts

`access=private` streets are in the graph and flagged (LEARNINGS §3.5) so they render in
Sun Map, but the corridor engine still treats them as walkable. Penalise or exclude
`EdgeFlag.privateAccess` in `CorridorEngine` unless the user's start or destination is
inside the tract.

## A public bundle server

The metros live in `Server/` (64 + 175 + 290 MB). Phones get them today by sideloading
(`devicectl device copy to`). A static host (S3/CloudFront, R2) serving `Server/` and the
`LWBundleBaseURL` Info.plist key is all the app needs; publishing is an outward-facing step
the owner has to choose.

## Open-Meteo proxy before scale

Nine points per request against the 10k-points/day free tier is ~1,100 requests/day: fine
for one user, not for a thousand. A caching proxy (one fetch per lattice cell per 30 min,
shared by everyone) or a paid key is needed before any public release.
