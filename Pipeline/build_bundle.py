#!/usr/bin/env python
"""Build a Like Water city bundle from OpenStreetMap.

    python build_bundle.py "San Francisco, California" -o ../Resources/sanfrancisco.lwbundle

The place name is the only parameter; nothing here is specific to one city.
Each stage caches to Pipeline/cache/ so a failed run resumes cheaply.
"""
import argparse, json, os, pickle, sys, time
from pathlib import Path

import numpy as np
import osmnx as ox
import geopandas as gpd
from shapely.geometry import LineString

import bundle_format as bf
import sidewalks
import overture
import terrain as terrain_mod

CACHE = Path(__file__).parent / "cache"
GLOBAL_DEFAULT_HEIGHT = False
CACHE.mkdir(exist_ok=True)

INTEREST_WEIGHTS = [
    (3, {"historic": True,
         "tourism": ["attraction", "viewpoint", "artwork"],
         "amenity": ["place_of_worship"]}),
    (2, {"leisure": ["park", "garden"], "natural": ["water"]}),
    (1, {"amenity": ["cafe", "marketplace"], "shop": True}),
]


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


_CACHE_NS = [""]

def cached(name, fn):
    path = CACHE / f"{_CACHE_NS[0]}{name}.pkl"
    if path.exists():
        log(f"cache hit: {name}")
        with open(path, "rb") as f:
            return pickle.load(f)
    value = fn()
    with open(path, "wb") as f:
        pickle.dump(value, f, protocol=4)
    return value


def configure():
    ox.settings.use_cache = True
    # osmnx drops access=private by default, which removes every gated tract and HOA
    # street — exactly where a suburban user lives and walks. Keep access=no out.
    ox.settings.default_access = '["access"!~"no"]'
    # overpass-api.de rate-limits hard; the Kumi mirror is faster and rarely refuses.
    ox.settings.overpass_url = os.environ.get("OVERPASS_URL", "https://overpass.private.coffee/api/interpreter")
    ox.settings.cache_folder = str(CACHE / "osmnx")
    ox.settings.requests_timeout = 180
    ox.settings.overpass_rate_limit = True
    ox.settings.log_console = False
    ox.settings.useful_tags_way = list(set(ox.settings.useful_tags_way) | {
        "highway", "footway", "sidewalk", "crossing", "name", "surface",
        "width", "lanes", "tunnel", "bridge", "access", "foot",
    })


MIRRORS = [
    "https://overpass.private.coffee/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass-api.de/api/interpreter",
]


def fetch_graph(place):
    """The big query. Same mirror rotation as the features, with a longer timeout
    because a whole city's walk network is a heavier ask than a tag lookup."""
    log(f"downloading walk network for {place!r} (this is the slow one)")
    original = ox.settings.overpass_url
    saved_timeout = ox.settings.requests_timeout
    ox.settings.requests_timeout = 420
    mirrors = [original] + [m for m in MIRRORS if m != original]
    try:
        for mirror in mirrors:
            ox.settings.overpass_url = mirror
            try:
                G = ox.graph_from_place(place, network_type="walk", simplify=False,
                                        retain_all=False, truncate_by_edge=True)
                log(f"graph: {G.number_of_nodes()} nodes, {G.number_of_edges()} edges"
                    + ("" if mirror == original else f" (via {mirror.split('/')[2]})"))
                return G
            except Exception as exc:                   # noqa: BLE001
                log(f"  graph failed on {mirror.split('/')[2]}: {str(exc)[:90]}")
        raise RuntimeError("walk network download failed on every Overpass mirror")
    finally:
        ox.settings.overpass_url = original
        ox.settings.requests_timeout = saved_timeout


def fetch_features(place, tags, label):
    """One Overpass query, trying each mirror in turn: public instances hang and refuse
    unpredictably, and a 3-minute timeout on a hung socket beats a 20-minute one."""
    log(f"downloading {label}")
    original = ox.settings.overpass_url
    mirrors = [original] + [m for m in MIRRORS if m != original]
    for mirror in mirrors:
        ox.settings.overpass_url = mirror
        try:
            gdf = ox.features_from_place(place, tags=tags)
            log(f"  {label}: {len(gdf)} features" + ("" if mirror == original else f" (via {mirror.split('/')[2]})"))
            return gdf
        except Exception as exc:                       # noqa: BLE001
            log(f"  {label} failed on {mirror.split('/')[2]}: {str(exc)[:90]}")
    ox.settings.overpass_url = original
    log(f"  {label}: giving up, no features")
    return gpd.GeoDataFrame({"geometry": []}, crs="EPSG:4326")


def edge_flags_for(data):
    """Flag an edge by what it physically is, not by what it is annotated with.

    footway=sidewalk means a line drawn down one side of a street: two of them per
    street, which is what lets the sun layer colour the sides differently. A street
    centreline tagged sidewalk=both is a different thing entirely -- one line down
    the middle -- and gets its own flag so the two are never confused.
    """
    flags = 0
    footway = str(data.get("footway", ""))
    highway = str(data.get("highway", ""))
    if "crossing" in footway or highway == "crossing":
        flags |= bf.FLAG_CROSSING
    if "sidewalk" in footway:
        flags |= bf.FLAG_SIDEWALK
    elif str(data.get("sidewalk", "")) not in ("", "nan", "no", "none", "None", "separate"):
        flags |= bf.FLAG_STREET_SIDEWALK_TAG
    if highway == "steps":
        flags |= bf.FLAG_STEPS
    return flags


def build_topology(G, sidewalk_widths=None, synthesise=True, survey=None, min_component=None):
    """Node/edge arrays after sidewalk synthesis.

    Keeps the largest connected component, plus any other component with at least
    `min_component` nodes: Staten Island and Roosevelt-Island-like places are islands
    for a walker only because the ferry is not a footway, and must not vanish.
    """
    from scipy.sparse import coo_matrix
    from scipy.sparse.csgraph import connected_components
    nodes, edges, synth = sidewalks.synthesise(G, sidewalk_widths, log=log, enabled=synthesise,
                                               survey=survey)

    ids = np.fromiter(nodes.keys(), dtype=np.int64, count=len(nodes))
    order = np.argsort(ids)
    ids_sorted = ids[order]
    eu = np.fromiter((e[0] for e in edges), dtype=np.int64, count=len(edges))
    ev = np.fromiter((e[1] for e in edges), dtype=np.int64, count=len(edges))
    elen = np.fromiter((e[2] for e in edges), dtype=np.float64, count=len(edges))
    eflag = np.fromiter((e[3] for e in edges), dtype=np.int64, count=len(edges))
    ia = order[np.searchsorted(ids_sorted, eu)]
    ib = order[np.searchsorted(ids_sorted, ev)]
    n = len(ids)
    A = coo_matrix((np.ones(len(ia)), (ia, ib)), shape=(n, n))
    ncomp, label = connected_components(A, directed=False)
    degree = np.bincount(np.concatenate([ia, ib]), minlength=n)
    has_edge = degree > 0
    sizes = np.bincount(label[has_edge], minlength=ncomp)
    largest = int(np.argmax(sizes))
    keep_comp = sizes >= (min_component if min_component else sizes[largest])
    keep_comp[largest] = True
    keep = has_edge & keep_comp[label]
    connected = int(has_edge.sum())
    stranded = connected - int(keep.sum())
    kept_islands = int(keep_comp.sum()) - 1
    log(f"  {int((~has_edge).sum())} obsolete shape nodes; keeping {int(keep.sum())} of {connected} connected "
        f"nodes in {int(keep_comp.sum())} component(s) (largest {int(sizes[largest])}"
        + (f", +{kept_islands} islands of >= {min_component}" if kept_islands else "")
        + f"; stranded {stranded}, {100 * stranded / max(connected, 1):.2f}%)")
    synth["obsolete_shape_nodes"] = int((~has_edge).sum())
    synth["stranded_nodes"] = stranded
    synth["components_kept"] = int(keep_comp.sum())

    new_index = np.full(n, -1, dtype=np.int64)
    new_index[keep] = np.arange(int(keep.sum()))
    lat = np.fromiter((nodes[k][0] for k in ids), dtype=np.float64, count=n)
    lon = np.fromiter((nodes[k][1] for k in ids), dtype=np.float64, count=n)
    node_lat, node_lon = lat[keep], lon[keep]

    ok = keep[ia] & keep[ib] & (ia != ib)
    a, b = new_index[ia[ok]], new_index[ib[ok]]
    lo, hi = np.minimum(a, b), np.maximum(a, b)
    elen, eflag = elen[ok], eflag[ok]
    # Duplicate undirected edges: keep the first length, OR the flags together.
    key = lo * (len(node_lat) + 1) + hi
    uniq, first, inverse = np.unique(key, return_index=True, return_inverse=True)
    flags = np.zeros(len(uniq), dtype=np.int64)
    np.bitwise_or.at(flags, inverse, eflag)
    return (node_lat, node_lon, lo[first], hi[first], elen[first], flags, synth)


def build_csr(node_count, edge_a, edge_b):
    """CSR adjacency, vectorised: each undirected edge appears once from each end."""
    edge_a = np.asarray(edge_a, dtype=np.int64); edge_b = np.asarray(edge_b, dtype=np.int64)
    m = len(edge_a)
    src = np.concatenate([edge_a, edge_b])
    dst = np.concatenate([edge_b, edge_a])
    eid = np.concatenate([np.arange(m), np.arange(m)])
    order = np.argsort(src, kind="stable")
    degree = np.bincount(src, minlength=node_count)
    start = np.zeros(node_count + 1, dtype=np.int64)
    np.cumsum(degree, out=start[1:])
    return start, dst[order], eid[order]


def interest_scores(place, node_lat, node_lon, edge_a, edge_b, buildings_gdf):
    """Weighted count of tagged features within 30 m of each edge."""
    lines = gpd.GeoSeries(
        [LineString([(node_lon[a], node_lat[a]), (node_lon[b], node_lat[b])])
         for a, b in zip(edge_a, edge_b)],
        crs="EPSG:4326")
    utm = lines.estimate_utm_crs()
    lines_m = lines.to_crs(utm)
    edges_gdf = gpd.GeoDataFrame({"edge": np.arange(len(lines_m))}, geometry=lines_m, crs=utm)

    score = np.zeros(len(lines_m), dtype=np.float64)
    for weight, tags in INTEREST_WEIGHTS:
        gdf = cached(f"interest_w{weight}", lambda t=tags, w=weight: fetch_features(place, t, f"interest w={w}"))
        if len(gdf) == 0:
            continue
        pts = gdf.to_crs(utm).geometry.representative_point()
        pts = gpd.GeoDataFrame(geometry=pts.buffer(30), crs=utm)
        joined = gpd.sjoin(edges_gdf, pts, how="inner", predicate="intersects")
        counts = joined.groupby("edge").size()
        score[counts.index.to_numpy()] += weight * counts.to_numpy()
        log(f"  weight {weight}: {len(joined)} edge-feature hits")

    if len(buildings_gdf):
        named = buildings_gdf[buildings_gdf.get("name").notna()] if "name" in buildings_gdf else buildings_gdf.iloc[:0]
        if len(named):
            pts = named.to_crs(utm).geometry.representative_point()
            pts = gpd.GeoDataFrame(geometry=pts.buffer(30), crs=utm)
            joined = gpd.sjoin(edges_gdf, pts, how="inner", predicate="intersects")
            counts = joined.groupby("edge").size()
            score[counts.index.to_numpy()] += 2 * counts.to_numpy()
            log(f"  named buildings: {len(joined)} edge-feature hits")

    return np.clip(score, 0, 255).astype(np.uint8)


def building_heights(gdf):
    def height_of(row):
        for key in ("height", "building:height"):
            raw = row.get(key)
            if raw not in (None, "") and not (isinstance(raw, float) and np.isnan(raw)):
                try:
                    return float(str(raw).split()[0].replace("m", ""))
                except ValueError:
                    pass
        for key in ("building:levels", "levels"):
            raw = row.get(key)
            if raw not in (None, "") and not (isinstance(raw, float) and np.isnan(raw)):
                try:
                    return float(str(raw).split(";")[0]) * 3.5
                except ValueError:
                    pass
        return 10.0
    return np.array([height_of(row) for _, row in gdf.iterrows()], dtype=np.float64)


def flatten_buildings(gdf, simplify_m=0.5):
    """Exterior rings only, lightly simplified, as a flat vertex list + offsets.
    Vectorised with shapely 2: ~2M footprints (Los Angeles) in seconds, not an hour."""
    import shapely
    if len(gdf) == 0:
        return np.zeros(1, dtype=np.int64), np.zeros(0), np.zeros(0), np.zeros(0)
    gdf = gdf[gdf.geometry.type.isin(["Polygon", "MultiPolygon"])]
    heights = (overture.heights(gdf, local_default=not GLOBAL_DEFAULT_HEIGHT)
               if "height" in gdf and "num_floors" in gdf else building_heights(gdf))
    parts, owner = shapely.get_parts(gdf.geometry.values, return_index=True)
    rings = shapely.get_exterior_ring(parts)
    lat0 = float(np.nanmean(shapely.get_coordinates(rings[: min(len(rings), 5000)])[:, 1]))
    kx = 111_320.0 * np.cos(np.radians(lat0)); ky = 110_540.0
    plane = shapely.transform(rings, lambda c: np.column_stack([c[:, 0] * kx, c[:, 1] * ky]))
    simple = shapely.simplify(plane, simplify_m)
    counts = shapely.get_num_coordinates(simple)
    ok = (counts >= 4) & ~shapely.is_empty(simple)          # >= 3 distinct + closing point
    simple, owner, counts = simple[ok], owner[ok], counts[ok]
    coords = shapely.get_coordinates(simple)
    # Drop each ring's repeated closing point.
    ends = np.cumsum(counts) - 1
    mask = np.ones(len(coords), bool); mask[ends] = False
    coords = coords[mask]
    n_per = counts - 1
    starts = np.zeros(len(n_per) + 1, dtype=np.int64); np.cumsum(n_per, out=starts[1:])
    return (starts, coords[:, 1] / ky, coords[:, 0] / kx, np.asarray(heights, dtype=np.float64)[owner])


def building_centroids(bld_start, bld_lat, bld_lon):
    counts = np.diff(bld_start)
    if len(counts) == 0:
        return np.zeros(0), np.zeros(0)
    lat = np.add.reduceat(bld_lat, bld_start[:-1]) / counts
    lon = np.add.reduceat(bld_lon, bld_start[:-1]) / counts
    return lat, lon


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("place")
    parser.add_argument("-o", "--out", required=True)
    parser.add_argument("--sidewalk-widths", default=None,
                        help="GeoJSON of surveyed sidewalk widths (DataSF format); optional, city-specific data")
    parser.add_argument("--buildings", choices=["overture", "osm"], default="overture")
    parser.add_argument("--no-sidewalk-synthesis", action="store_true",
                        help="keep OSM as-is (baseline for measuring what synthesis adds)")
    parser.add_argument("--terrain-margin-m", type=float, default=3000.0,
                        help="how far beyond the street network to fetch terrain, so hills outside the city can shade into it")
    parser.add_argument("--global-default-height", action="store_true",
                        help="unknown building heights get 10 m instead of the local median (baseline)")
    args = parser.parse_args()

    global GLOBAL_DEFAULT_HEIGHT
    GLOBAL_DEFAULT_HEIGHT = args.global_default_height
    configure()
    # Cache per place so two cities never read each other's downloads.
    import re
    _CACHE_NS[0] = re.sub(r"[^a-z0-9]+", "_", args.place.lower()).strip("_") + "__priv__"
    G = cached("graph", lambda: fetch_graph(args.place))

    log("building topology (with sidewalk synthesis)")
    node_lat, node_lon, edge_a, edge_b, edge_len, edge_flags, synth = build_topology(
        G, args.sidewalk_widths, synthesise=not args.no_sidewalk_synthesis)
    log(f"  {len(node_lat)} nodes, {len(edge_a)} undirected edges, "
        f"{int((edge_flags & bf.FLAG_CROSSING).astype(bool).sum())} crossings, "
        f"{int((edge_flags & bf.FLAG_SIDEWALK).astype(bool).sum())} sidewalk edges "
        f"({int(((edge_flags & bf.FLAG_SIDEWALK).astype(bool) & (edge_flags & bf.FLAG_SYNTHETIC).astype(bool)).sum())} synthesised), "
        f"{int((edge_flags & bf.FLAG_STREET_SIDEWALK_TAG).astype(bool).sum())} tagged centrelines")

    log("building CSR adjacency")
    adj_start, adj_node, adj_edge = build_csr(len(node_lat), edge_a, edge_b)

    bbox_nodes = (float(node_lat.min()), float(node_lon.min()), float(node_lat.max()), float(node_lon.max()))
    buildings = None
    if args.buildings == "overture":
        try:
            buildings = cached("buildings_overture", lambda: overture.fetch_buildings(bbox_nodes, log=log))
        except Exception:                              # noqa: BLE001
            import traceback
            log("  Overture failed; falling back to OSM buildings:\n" + traceback.format_exc())
    if buildings is None:
        buildings = cached("buildings", lambda: fetch_features(args.place, {"building": True}, "buildings"))
    log(f"  buildings source: {'Overture' if 'source' in buildings else 'OSM'}, {len(buildings)} footprints")
    log("scoring interest")
    # Keyed on the edge set: any topology change must invalidate the per-edge scores.
    interest = cached(f"interest_v2_{len(edge_a)}_{int(edge_len.sum())}",
                      lambda: interest_scores(args.place, node_lat, node_lon, edge_a, edge_b, buildings))

    log(f"fetching terrain (+{args.terrain_margin_m:.0f} m margin)")
    m_lat = args.terrain_margin_m / 111_320.0
    m_lon = args.terrain_margin_m / (111_320.0 * np.cos(np.radians((bbox_nodes[0] + bbox_nodes[2]) / 2)))
    bbox_terrain = (bbox_nodes[0] - m_lat, bbox_nodes[1] - m_lon, bbox_nodes[2] + m_lat, bbox_nodes[3] + m_lon)
    terrain = cached(f"terrain_m{int(args.terrain_margin_m)}",
                     lambda: terrain_mod.fetch_grid(bbox_terrain, step_m=10.0, log=log))

    log("flattening building footprints")
    bld_start, bld_lat, bld_lon, bld_height = flatten_buildings(buildings)
    # Ground level under each footprint, so a building's top is ground + height.
    cent_lat, cent_lon = building_centroids(bld_start, bld_lat, bld_lon)
    bld_ground = terrain_mod.sample(terrain, cent_lat, cent_lon) if len(bld_height) else np.zeros(0)
    log(f"  {len(bld_height)} polygons, {len(bld_lat)} vertices, "
        f"median height {np.median(bld_height) if len(bld_height) else 0:.1f} m")

    bbox = (float(node_lat.min()), float(node_lon.min()),
            float(node_lat.max()), float(node_lon.max()))

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    stats = bf.write_bundle(
        out, node_lat=node_lat, node_lon=node_lon,
        adj_start=adj_start, adj_node=adj_node, adj_edge=adj_edge,
        edge_a=edge_a, edge_b=edge_b, edge_len=edge_len,
        edge_flags=edge_flags, edge_interest=interest,
        bld_start=bld_start, bld_lat=bld_lat, bld_lon=bld_lon, bld_height=bld_height,
        bbox=bbox, bld_ground=bld_ground, terrain=terrain)
    size_mb = out.stat().st_size / 1e6
    stats["size_mb"] = round(size_mb, 1)
    stats["bbox"] = bbox
    stats["synthesis"] = synth
    log(f"wrote {out} — {size_mb:.1f} MB")

    # Manifest next to the bundles: what an app downloads to find out which city covers
    # a location it has no data for. One entry per bundle file, keyed by file name.
    manifest_path = out.parent / "manifest.json"
    manifest = {"cities": []}
    if manifest_path.exists():
        try:
            manifest = json.load(open(manifest_path))
        except Exception:                      # noqa: BLE001
            pass
    try:
        from timezonefinder import TimezoneFinder
        tz = TimezoneFinder().timezone_at(lng=(bbox[1] + bbox[3]) / 2, lat=(bbox[0] + bbox[2]) / 2)
    except Exception:                          # noqa: BLE001
        tz = None
    entry = {"name": args.place.split(",")[0].strip(), "file": out.name, "timezone": tz,
             "minLat": bbox[0], "minLon": bbox[1], "maxLat": bbox[2], "maxLon": bbox[3],
             "bytes": out.stat().st_size, "nodes": stats["nodes"], "edges": stats["edges"]}
    manifest["cities"] = [c for c in manifest.get("cities", []) if c.get("file") != out.name] + [entry]
    json.dump(manifest, open(manifest_path, "w"), indent=2)
    log(f"manifest: {len(manifest['cities'])} cities in {manifest_path}")
    print(json.dumps(stats, indent=2))
    if size_mb > 40:
        log("WARNING: bundle exceeds the 40 MB target")


if __name__ == "__main__":
    main()
