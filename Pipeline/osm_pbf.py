"""Read the walking network and interest points straight from a Geofabrik .osm.pbf.

Overpass cannot serve a New York or Los Angeles walk network: one query for a
1,000 km² city exceeds every public mirror's time and memory limits. A state
extract is a 400-700 MB download that never refuses, so big cities are built
from it. The graph this returns has the same shape as osmnx's
(`graph_from_place(..., network_type="walk", simplify=False)`), so sidewalk
synthesis and everything after it is shared with the Overpass path.
"""
import math, re, time
import numpy as np
import networkx as nx
import shapely
from shapely.geometry import Point

# osmnx 2.x "walk" filter, with our access override (keep access=private, drop access=no).
_EXCLUDE_HIGHWAY = re.compile(r"abandoned|bus_guideway|construction|cycleway|motor|no|planned|"
                              r"platform|proposed|raceway|razed")
KEEP_TAGS = ("highway", "footway", "sidewalk", "crossing", "name", "surface", "width",
             "lanes", "tunnel", "bridge", "access", "foot", "service", "area",
             "sidewalk:width", "sidewalk:both:width", "sidewalk:left:width", "sidewalk:right:width")


def is_walkable(tags):
    hw = tags.get("highway")
    if hw is None or _EXCLUDE_HIGHWAY.search(hw):
        return False
    if tags.get("area") == "yes":
        return False
    if "no" in tags.get("foot", ""):
        return False
    if "private" in tags.get("service", ""):
        return False
    if "no" in tags.get("access", ""):
        return False
    return True


def _haversine(lat1, lon1, lat2, lon2):
    p = math.pi / 180
    a = (math.sin((lat2 - lat1) * p / 2) ** 2
         + math.cos(lat1 * p) * math.cos(lat2 * p) * math.sin((lon2 - lon1) * p / 2) ** 2)
    return 2 * 6_371_008.8 * math.asin(min(1.0, math.sqrt(a)))


def walk_graph(pbf_path, polygon, buffer_m=500, log=print):
    """Walkable ways with at least one node inside `polygon` (EPSG:4326) buffered by
    `buffer_m` — osmnx's truncate_by_edge semantics. Returns an nx.MultiDiGraph with
    one directed edge per OSM segment (synthesis treats edges as undirected)."""
    import osmium
    lat0 = polygon.centroid.y
    buf = polygon.buffer(buffer_m / (111_320 * math.cos(math.radians(lat0))))
    shapely.prepare(buf)
    minx, miny, maxx, maxy = buf.bounds

    t0 = time.time()
    G = nx.MultiDiGraph(crs="epsg:4326")
    ways = 0
    fp = (osmium.FileProcessor(pbf_path, osmium.osm.NODE | osmium.osm.WAY)
          .with_locations()
          .with_filter(osmium.filter.EntityFilter(osmium.osm.WAY))
          .with_filter(osmium.filter.KeyFilter("highway")))
    for w in fp:
        tags = {t.k: t.v for t in w.tags}
        if not is_walkable(tags):
            continue
        refs = []
        for n in w.nodes:
            loc = n.location
            if not loc.valid():
                refs = None
                break
            refs.append((n.ref, loc.lat, loc.lon))
        if not refs or len(refs) < 2:
            continue
        lats = np.fromiter((r[1] for r in refs), float, len(refs))
        lons = np.fromiter((r[2] for r in refs), float, len(refs))
        if lons.max() < minx or lons.min() > maxx or lats.max() < miny or lats.min() > maxy:
            continue
        inside = shapely.contains_xy(buf, lons, lats)
        if not inside.any():
            continue
        data = {k: tags[k] for k in KEEP_TAGS if k in tags}
        data["osmid"] = w.id
        for k in range(len(refs) - 1):
            if not (inside[k] or inside[k + 1]):
                continue
            (u, ulat, ulon), (v, vlat, vlon) = refs[k], refs[k + 1]
            if u == v:
                continue
            G.add_node(u, y=ulat, x=ulon)
            G.add_node(v, y=vlat, x=vlon)
            G.add_edge(u, v, length=_haversine(ulat, ulon, vlat, vlon), **data)
        ways += 1
    log(f"  pbf: {ways} walkable ways, {G.number_of_nodes()} nodes, {G.number_of_edges()} segments "
        f"in {time.time() - t0:.0f}s")
    return G


def interest_points(pbf_path, polygon, weights, buffer_m=300, log=print):
    """Points (lon, lat, weight) for every node or way matching an interest tag set.
    Ways contribute the mean of their node locations; multipolygon relations are
    skipped (the score only ever used a feature's representative point)."""
    import osmium
    lat0 = polygon.centroid.y
    buf = polygon.buffer(buffer_m / (111_320 * math.cos(math.radians(lat0))))
    shapely.prepare(buf)
    minx, miny, maxx, maxy = buf.bounds

    def weight_of(tags):
        best = 0
        for w, spec in weights:
            for key, want in spec.items():
                v = tags.get(key)
                if v is None:
                    continue
                if want is True or v in want:
                    best = max(best, w)
        return best

    keys = sorted({k for _, spec in weights for k in spec})
    t0 = time.time()
    xs, ys, ws = [], [], []
    fp = (osmium.FileProcessor(pbf_path, osmium.osm.NODE | osmium.osm.WAY)
          .with_locations()
          .with_filter(osmium.filter.KeyFilter(*keys)))
    for o in fp:
        tags = {t.k: t.v for t in o.tags}
        w = weight_of(tags)
        if not w:
            continue
        if o.is_node():
            if not o.location.valid():
                continue
            x, y = o.location.lon, o.location.lat
        else:
            pts = [(n.location.lon, n.location.lat) for n in o.nodes if n.location.valid()]
            if not pts:
                continue
            x = sum(p[0] for p in pts) / len(pts); y = sum(p[1] for p in pts) / len(pts)
        if not (minx <= x <= maxx and miny <= y <= maxy):
            continue
        xs.append(x); ys.append(y); ws.append(w)
    xs, ys, ws = np.array(xs), np.array(ys), np.array(ws, dtype=np.int64)
    keep = shapely.contains_xy(buf, xs, ys) if len(xs) else np.zeros(0, bool)
    log(f"  pbf: {int(keep.sum())} interest points in {time.time() - t0:.0f}s")
    return xs[keep], ys[keep], ws[keep]
