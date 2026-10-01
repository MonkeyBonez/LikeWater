#!/usr/bin/env python
"""Build a big city as stitchable tiles: New York, Los Angeles, Seattle.

    python build_metro.py --id seattle --name Seattle \
        --pbf cache/pbf/washington.osm.pbf --place "Seattle, Washington, USA" --survey seattle

A single bundle stops working somewhere past San Francisco's size: New York is 1.7M
buildings and ~3M graph nodes after synthesis, ~300 MB as one file. So a metro is
built once, as one graph (sidewalk synthesis and components need the whole city),
and then cut into ~4 km tiles on a fixed lat/lon lattice:

* each edge goes to the tile holding its midpoint, and its end nodes come along
  with their metro-wide ids, so the app can load any set of neighbouring tiles and
  stitch them into one graph by id;
* each building goes to the tile holding its centroid;
* terrain is cut from one shared 10 m lattice, so tiles mosaic exactly;
* one coarse 100 m terrain grid covers the metro plus 25 km, so mountains well
  outside the loaded tiles (the San Gabriels from downtown LA) still cast shadows.

Output, under --out-root (the directory a bundle server serves):
    <id>/metro.json          tile index, timezone, demo point, build stats
    <id>/far.lwbundle        coarse terrain only
    <id>/t_<row>_<col>.lwbundle
    manifest.json            gains/updates a "metros" entry pointing at <id>/metro.json
"""
import argparse, datetime, json, math, pickle, time
from pathlib import Path

import numpy as np
import shapely
from shapely.strtree import STRtree

import build_bundle as bb
import bundle_format as bf
import osm_pbf
import overture
import survey as survey_mod
import terrain as tm

TILE_LAT = 0.04        # ~4.4 km
TILE_LON = 0.05        # ~3.8-4.6 km across the US
FINE_STEP_M = 10.0
FAR_STEP_M = 100.0
FAR_MARGIN_M = 25_000.0
BUILDING_MARGIN_M = 1_000.0
log = bb.log


def cached(name, fn):
    return bb.cached(name, fn)


def boundary(places):
    import osmnx as ox
    polys = [ox.geocode_to_gdf(p).geometry.iloc[0] for p in places]
    return shapely.union_all(polys)


def tile_of(lat, lon):
    return np.floor(np.asarray(lat) / TILE_LAT).astype(np.int64), np.floor(np.asarray(lon) / TILE_LON).astype(np.int64)


def tile_bounds(i, j):
    return (i * TILE_LAT, j * TILE_LON, (i + 1) * TILE_LAT, (j + 1) * TILE_LON)


def interest(node_lat, node_lon, edge_a, edge_b, pts, named_pts):
    """Weighted count of interest points within 30 m of each edge, vectorised."""
    lat0 = float(node_lat.mean())
    kx = 111_320.0 * math.cos(math.radians(lat0)); ky = 110_540.0
    seg = np.stack([np.column_stack([node_lon[edge_a] * kx, node_lat[edge_a] * ky]),
                    np.column_stack([node_lon[edge_b] * kx, node_lat[edge_b] * ky])], axis=1)
    lines = shapely.linestrings(seg)
    tree = STRtree(lines)
    score = np.zeros(len(edge_a), dtype=np.float64)
    for (xs, ys, ws), label in ((pts, "OSM features"), (named_pts, "named buildings")):
        if len(xs) == 0:
            continue
        p = shapely.points(np.asarray(xs) * kx, np.asarray(ys) * ky)
        pi, ei = tree.query(p, predicate="dwithin", distance=30)
        np.add.at(score, ei, np.asarray(ws, dtype=np.float64)[pi])
        log(f"  interest from {label}: {len(pi)} edge-feature hits")
    return np.clip(score, 0, 255).astype(np.uint8)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--id", required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument("--pbf", required=True)
    ap.add_argument("--place", action="append", required=True,
                    help="Nominatim place; repeat to union several (LA + its enclaves)")
    ap.add_argument("--survey", choices=sorted(survey_mod.SURVEYS), default=None)
    ap.add_argument("--out-root", default=str(Path(__file__).parent.parent / "Server"))
    ap.add_argument("--min-component", type=int, default=2000,
                    help="keep disconnected pieces at least this big (Staten Island)")
    ap.add_argument("--demo", default=None, help="LAT,LON the app shows when you are elsewhere")
    ap.add_argument("--no-sidewalk-synthesis", action="store_true")
    args = ap.parse_args()

    t_start = time.time()
    bb.configure()
    bb._CACHE_NS[0] = f"metro_{args.id}__"
    out_dir = Path(args.out_root) / args.id
    out_dir.mkdir(parents=True, exist_ok=True)

    poly = cached("boundary", lambda: boundary(args.place))
    log(f"{args.name}: boundary {poly.area * 111 * 111 * math.cos(math.radians(poly.centroid.y)):.0f} km² "
        f"(approx), bounds {tuple(round(b, 3) for b in poly.bounds)}")

    # --- graph and synthesis ---------------------------------------------------
    synth_key = f"topology_v9_{args.survey or 'none'}_{'nosyn' if args.no_sidewalk_synthesis else 'syn'}_{args.min_component}"

    def topology():
        G = osm_pbf.walk_graph(args.pbf, poly, log=log)
        survey = survey_mod.SURVEYS[args.survey]() if args.survey else None
        return bb.build_topology(G, None, synthesise=not args.no_sidewalk_synthesis,
                                 survey=survey, min_component=args.min_component)

    log("walk network from the extract + sidewalk synthesis")
    node_lat, node_lon, edge_a, edge_b, edge_len, edge_flags, synth = cached(synth_key, topology)
    F = lambda bit: int(((edge_flags & bit) != 0).sum())
    log(f"  {len(node_lat)} nodes, {len(edge_a)} edges, {F(bf.FLAG_CROSSING)} crossings, "
        f"{F(bf.FLAG_SIDEWALK)} sidewalk edges ({int((((edge_flags & bf.FLAG_SIDEWALK) != 0) & ((edge_flags & bf.FLAG_SYNTHETIC) != 0)).sum())} synthesised)")

    nb = (float(node_lat.min()), float(node_lon.min()), float(node_lat.max()), float(node_lon.max()))
    mid_lat = (nb[0] + nb[2]) / 2
    m_lat = BUILDING_MARGIN_M / 111_320.0
    m_lon = BUILDING_MARGIN_M / (111_320.0 * math.cos(math.radians(mid_lat)))

    # --- buildings ------------------------------------------------------------
    log("buildings (Overture)")
    bbox_b = (nb[0] - m_lat, nb[1] - m_lon, nb[2] + m_lat, nb[3] + m_lon)
    buildings = cached("buildings_overture", lambda: overture.fetch_buildings(bbox_b, log=log, contained=False))
    log(f"  {len(buildings)} footprints; flattening")
    t0 = time.time()
    bld_start, bld_lat, bld_lon, bld_height = bb.flatten_buildings(buildings)
    cent_lat, cent_lon = bb.building_centroids(bld_start, bld_lat, bld_lon)
    log(f"  {len(bld_height)} polygons, {len(bld_lat)} vertices in {time.time() - t0:.0f}s; "
        f"median {np.median(bld_height):.1f} m, max {bld_height.max():.0f} m")

    # --- interest -----------------------------------------------------------------
    log("interest")
    pts = cached("interest_points", lambda: osm_pbf.interest_points(args.pbf, poly, bb.INTEREST_WEIGHTS, log=log))
    named = buildings[buildings["name"].notna()] if "name" in buildings else buildings.iloc[:0]
    np_pts = shapely.point_on_surface(named.geometry.values) if len(named) else np.array([])
    named_pts = (shapely.get_x(np_pts), shapely.get_y(np_pts), np.full(len(np_pts), 2)) if len(named) else ([], [], [])
    edge_interest = interest(node_lat, node_lon, edge_a, edge_b, pts, named_pts)

    # --- terrain ------------------------------------------------------------------
    log("terrain")
    ref_lat = round(mid_lat, 1)
    step_lat, step_lon = tm.lattice(ref_lat, FINE_STEP_M)
    tm.prefetch((nb[0] - m_lat, nb[1] - m_lon, nb[2] + m_lat, nb[3] + m_lon), 14, log=log)
    f_lat = FAR_MARGIN_M / 111_320.0
    f_lon = FAR_MARGIN_M / (111_320.0 * math.cos(math.radians(mid_lat)))
    far_bbox = (nb[0] - f_lat, nb[1] - f_lon, nb[2] + f_lat, nb[3] + f_lon)
    tm.prefetch(far_bbox, 10, log=log)
    far_sl, far_so = tm.lattice(ref_lat, FAR_STEP_M)
    far = tm.aligned_grid(far_bbox, far_sl, far_so, z=10)
    log(f"  far field: {far['rows']}x{far['cols']} at {FAR_STEP_M:.0f} m, "
        f"{far['elevation'].min()}..{far['elevation'].max()} m")

    # --- tiles ----------------------------------------------------------------------
    log("cutting tiles")
    mid_e_lat = (node_lat[edge_a] + node_lat[edge_b]) / 2
    mid_e_lon = (node_lon[edge_a] + node_lon[edge_b]) / 2
    ei, ej = tile_of(mid_e_lat, mid_e_lon)
    bi, bj = tile_of(cent_lat, cent_lon)
    ekey = ei * 100_000 + (ej + 50_000)
    bkey = bi * 100_000 + (bj + 50_000)
    e_order = np.argsort(ekey, kind="stable")
    b_order = np.argsort(bkey, kind="stable")
    ekeys, e_first = np.unique(ekey[e_order], return_index=True)
    e_bounds = np.r_[e_first, len(e_order)]
    bkeys_sorted = bkey[b_order]

    tiles = []
    placed_buildings = 0
    for k, key in enumerate(ekeys):
        e_idx = e_order[e_bounds[k]:e_bounds[k + 1]]
        ti = int(key // 100_000); tj = int(key % 100_000) - 50_000
        lo = np.searchsorted(bkeys_sorted, key, "left"); hi = np.searchsorted(bkeys_sorted, key, "right")
        b_idx = np.sort(b_order[lo:hi])
        placed_buildings += len(b_idx)

        a, b = edge_a[e_idx], edge_b[e_idx]
        gids = np.unique(np.concatenate([a, b]))
        la, lb = np.searchsorted(gids, a), np.searchsorted(gids, b)
        adj_start, adj_node, adj_edge = bb.build_csr(len(gids), la, lb)

        counts = bld_start[b_idx + 1] - bld_start[b_idx]
        new_start = np.zeros(len(b_idx) + 1, dtype=np.int64); np.cumsum(counts, out=new_start[1:])
        vert = (np.repeat(bld_start[b_idx], counts)
                + np.arange(int(new_start[-1])) - np.repeat(new_start[:-1], counts))
        tb = tile_bounds(ti, tj)
        pad_lat, pad_lon = step_lat, step_lon
        grid = tm.aligned_grid((tb[0] - pad_lat, tb[1] - pad_lon, tb[2] + pad_lat, tb[3] + pad_lon),
                               step_lat, step_lon, z=14)
        ground = tm.sample(grid, cent_lat[b_idx], cent_lon[b_idx]) if len(b_idx) else np.zeros(0)

        name = f"t_{ti}_{tj}.lwbundle"
        path = out_dir / name
        bf.write_bundle(
            path, node_lat=node_lat[gids], node_lon=node_lon[gids],
            adj_start=adj_start, adj_node=adj_node, adj_edge=adj_edge,
            edge_a=la, edge_b=lb, edge_len=edge_len[e_idx], edge_flags=edge_flags[e_idx],
            edge_interest=edge_interest[e_idx],
            bld_start=new_start, bld_lat=bld_lat[vert], bld_lon=bld_lon[vert], bld_height=bld_height[b_idx],
            bbox=tb, bld_ground=ground, terrain=grid, global_ids=gids, tile=(ti, tj))
        tiles.append(dict(i=ti, j=tj, file=name, bytes=path.stat().st_size,
                          nodes=int(len(gids)), edges=int(len(e_idx)), buildings=int(len(b_idx))))
        if len(tiles) % 25 == 0:
            log(f"  {len(tiles)} tiles written")

    far_path = out_dir / "far.lwbundle"
    z = np.zeros(0)
    bf.write_bundle(far_path, node_lat=z, node_lon=z, adj_start=np.zeros(1, np.int64), adj_node=z, adj_edge=z,
                    edge_a=z, edge_b=z, edge_len=z, edge_flags=z, edge_interest=z,
                    bld_start=np.zeros(1, np.int64), bld_lat=z, bld_lon=z, bld_height=z,
                    bbox=(far_bbox[0], far_bbox[1], far_bbox[2], far_bbox[3]), bld_ground=z, terrain=far)

    # --- index ----------------------------------------------------------------------
    from timezonefinder import TimezoneFinder
    rep = poly.representative_point()
    tz = TimezoneFinder().timezone_at(lng=rep.x, lat=rep.y)
    if args.demo:
        demo = [float(v) for v in args.demo.split(",")]
    else:
        k = int(np.argmin((node_lat - rep.y) ** 2 + (node_lon - rep.x) ** 2))
        demo = [float(node_lat[k]), float(node_lon[k])]
    sizes = np.array([t["bytes"] for t in tiles])
    total = int(sizes.sum()) + far_path.stat().st_size
    metro = dict(
        format=1, id=args.id, name=args.name, timezone=tz,
        built=datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        overture=overture.RELEASE, source=Path(args.pbf).name,
        tileLat=TILE_LAT, tileLon=TILE_LON,
        minLat=min(tile_bounds(t["i"], t["j"])[0] for t in tiles),
        minLon=min(tile_bounds(t["i"], t["j"])[1] for t in tiles),
        maxLat=max(tile_bounds(t["i"], t["j"])[2] for t in tiles),
        maxLon=max(tile_bounds(t["i"], t["j"])[3] for t in tiles),
        demo=demo, far=dict(file=far_path.name, bytes=far_path.stat().st_size), bytes=total,
        tiles=tiles,
        stats=dict(nodes=int(len(node_lat)), edges=int(len(edge_a)), buildings=int(len(bld_height)),
                   buildings_in_tiles=int(placed_buildings), synthesis=synth,
                   tile_mb_median=round(float(np.median(sizes)) / 1e6, 2),
                   tile_mb_max=round(float(sizes.max()) / 1e6, 2), total_mb=round(total / 1e6, 1),
                   build_minutes=round((time.time() - t_start) / 60, 1)))
    json.dump(metro, open(out_dir / "metro.json", "w"), indent=1)

    manifest_path = Path(args.out_root) / "manifest.json"
    manifest = {"cities": [], "metros": []}
    if manifest_path.exists():
        manifest = json.load(open(manifest_path))
    entry = dict(id=args.id, name=args.name, index=f"{args.id}/metro.json", timezone=tz,
                 minLat=metro["minLat"], minLon=metro["minLon"], maxLat=metro["maxLat"], maxLon=metro["maxLon"],
                 bytes=total, tiles=len(tiles), demo=demo, built=metro["built"])
    manifest["metros"] = [m for m in manifest.get("metros", []) if m["id"] != args.id] + [entry]
    manifest.setdefault("cities", [])
    json.dump(manifest, open(manifest_path, "w"), indent=2)

    log(f"wrote {len(tiles)} tiles, {total / 1e6:.0f} MB total (median tile {np.median(sizes) / 1e6:.1f} MB, "
        f"max {sizes.max() / 1e6:.1f} MB); {len(bld_height) - placed_buildings} buildings outside any tile dropped; "
        f"timezone {tz}; {(time.time() - t_start) / 60:.1f} min")
    print(json.dumps(metro["stats"], indent=1))


if __name__ == "__main__":
    main()
