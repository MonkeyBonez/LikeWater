"""Synthesise per-side sidewalk edges for streets where OSM has not drawn them.

For every qualifying street segment, offset it to the left and right by half the
roadway width plus half the sidewalk width, join consecutive offsets at each node
into corner nodes (standard polyline offsetting), add a crossing across each
street at every intersection, and link the centreline node to its corners so the
rest of the pedestrian network stays connected. The centreline edge itself is
removed where both sides now have a sidewalk.

Presence and widths come from DataSF's 2014 sidewalk survey when a street matches
one; otherwise a per-class default. Streets that already have OSM sidewalks on a
side are left alone on that side.
"""
import math, collections
import numpy as np
import geopandas as gpd
from shapely.geometry import LineString, Point
from shapely.strtree import STRtree

STREET = {"residential", "tertiary", "secondary", "primary", "unclassified",
          "living_street", "service", "tertiary_link", "secondary_link", "primary_link"}
NO_SIDEWALK_SERVICE = {"driveway", "parking_aisle", "drive-through", "emergency_access"}

# Roadway width (kerb to kerb) by DataSF Better Streets Plan class, metres.
ROADWAY_BY_CLASS = {
    "Downtown Commercial": 18.0, "Commercial Throughway": 16.0, "Residential Throughway": 14.0,
    "Neighborhood Commercial": 12.0, "Mixed-use": 12.0, "Neighborhood Residential": 11.0,
    "Industrial": 14.0, "Park Edge": 12.0, "Parkway": 16.0, "Alley": 6.0,
}
ROADWAY_BY_HIGHWAY = {"primary": 18.0, "secondary": 16.0, "tertiary": 14.0, "residential": 11.0,
                      "unclassified": 11.0, "living_street": 8.0, "service": 6.0}
DEFAULT_SIDEWALK_M = 3.0
FT = 0.3048


def _bearing(dx, dy):
    return math.atan2(dy, dx)


def _compass_side_matches(named, nx, ny):
    """Does the outward normal (nx, ny) point toward the compass side DataSF named?"""
    named = named.upper()
    want = {"N": (0, 1), "S": (0, -1), "E": (1, 0), "W": (-1, 0),
            "NE": (0.7, 0.7), "NW": (-0.7, 0.7), "SE": (0.7, -0.7), "SW": (-0.7, -0.7)}.get(named)
    if want is None:
        return True
    return nx * want[0] + ny * want[1] > 0


def synthesise(G, datasf_widths_path=None, log=print, enabled=True, survey=None):
    """Returns (nodes: {id: (lat, lon)}, edges: [(u, v, length_m, flags)], stats).

    `flags` is a dict with keys crossing/sidewalk/synthetic/steps/tagged for the
    caller to map onto bundle bits; `nodes` includes every original node plus the
    new corner nodes; `edges` is the full undirected edge list after synthesis.
    """
    from bundle_format import (FLAG_CROSSING, FLAG_SIDEWALK, FLAG_STEPS, FLAG_STREET_SIDEWALK_TAG,
                               FLAG_SYNTHETIC, FLAG_STREET, FLAG_PRIVATE)

    # --- local metre plane ---------------------------------------------------
    lats = np.array([d["y"] for _, d in G.nodes(data=True)])
    lat0 = float(lats.mean())
    mlat = 111_132.92 - 559.82 * math.cos(2 * math.radians(lat0))
    mlon = 111_412.84 * math.cos(math.radians(lat0)) - 93.5 * math.cos(3 * math.radians(lat0))
    node_xy = {n: ((d["x"]) * mlon, (d["y"]) * mlat) for n, d in G.nodes(data=True)}

    def to_latlon(x, y):
        return (y / mlat, x / mlon)

    # --- classify original edges -------------------------------------------
    seen = {}
    base_edges = []          # (u, v, data)
    for u, v, d in G.edges(data=True):
        if u == v:
            continue
        key = (u, v) if u < v else (v, u)
        if key in seen:
            continue
        seen[key] = len(base_edges)
        base_edges.append((key[0], key[1], d))

    def is_street(d):
        hw = str(d.get("highway", ""))
        if hw not in STREET or "sidewalk" in str(d.get("footway", "")):
            return False
        if hw == "service" and str(d.get("service", "")) in NO_SIDEWALK_SERVICE:
            return False
        # Alleys: without a survey to say otherwise, assume none. Seattle's survey had
        # sidewalks on 8% of alley length; defaulting to two was most of the gap
        # between survey and no-survey kerb coverage on Capitol Hill.
        if (hw == "service" and str(d.get("service", "")) == "alley"
                and survey is None and not datasf_widths_path):
            return False
        if str(d.get("sidewalk", "")) in ("separate",):
            return False
        return True

    def is_osm_sidewalk(d):
        return "sidewalk" in str(d.get("footway", ""))

    street_idx = [i for i, (_, _, d) in enumerate(base_edges) if is_street(d)] if enabled else []
    log(f"  synthesis candidates: {len(street_idx)} street segments" + ("" if enabled else " (synthesis disabled)"))

    # --- DataSF widths + presence, joined by nearest centreline -------------
    datasf = None
    if datasf_widths_path:
        sw = gpd.read_file(datasf_widths_path)
        sw = sw[sw.geometry.notna()].copy()
        sw["sidewalk_m"] = sw["sidewalk_f"].astype(float) * FT
        geoms = [LineString([(node_xy[base_edges[i][0]]), (node_xy[base_edges[i][1]])]) for i in street_idx]
        sw_xy = sw.copy()
        sw_xy["geometry"] = sw_xy.geometry.apply(
            lambda g: LineString([(x * mlon, y * mlat) for x, y in g.coords]) if g.geom_type == "LineString"
            else LineString([(x * mlon, y * mlat) for x, y in list(g.geoms)[0].coords]))
        tree = STRtree(list(sw_xy.geometry))
        datasf = {}
        for i, g in zip(street_idx, geoms):
            mid = g.interpolate(0.5, normalized=True)
            hits = tree.query(mid.buffer(12))
            best, best_d = None, 12.0
            for h in hits:
                dd = sw_xy.geometry.iloc[h].distance(mid)
                if dd < best_d:
                    best, best_d = h, dd
            if best is not None:
                row = sw_xy.iloc[best]
                datasf[i] = (str(row["side"] or "Both"), float(row["sidewalk_m"]), str(row["class"] or ""))
        log(f"  DataSF match: {len(datasf)} of {len(street_idx)} streets")

    # --- a city survey (NYC polygons, Seattle lines), per side ----------------
    survey_sides = {}
    if survey is not None and street_idx:
        mids, dirs, normals, lengths = [], [], [], []
        for i in street_idx:
            u, v, _ = base_edges[i]
            (ux, uy), (vx, vy) = node_xy[u], node_xy[v]
            dx, dy = vx - ux, vy - uy
            L = max(math.hypot(dx, dy), 1e-6)
            mids.append(((ux + vx) / 2, (uy + vy) / 2)); dirs.append((dx / L, dy / L))
            normals.append((-dy / L, dx / L)); lengths.append(L)
        lon_lat = np.array([[G.nodes[base_edges[i][0]]["x"], G.nodes[base_edges[i][0]]["y"]] for i in street_idx])
        survey.load(mlat, mlon, bounds_lonlat=(lon_lat[:, 0].min() - 0.01, lon_lat[:, 1].min() - 0.01,
                                               lon_lat[:, 0].max() + 0.01, lon_lat[:, 1].max() + 0.01), log=log)
        answers = survey.lookup(np.array(mids), np.array(dirs), np.array(normals), np.array(lengths), log=log)
        from survey import aggregate_by_way
        def way_of(i):
            w = base_edges[i][2].get("osmid")
            return (w[0] if isinstance(w, list) and w else w)
        answers = aggregate_by_way(answers, [way_of(i) for i in street_idx], dirs, lengths)
        survey_sides = {i: a for i, a in zip(street_idx, answers) if a[0] is not None or a[1] is not None}
        log(f"  survey covers {len(survey_sides)} of {len(street_idx)} streets")

    def _metres(raw):
        try:
            v = float(str(raw).split(";")[0].replace("m", "").strip())
            return v if math.isfinite(v) else None
        except ValueError:
            return None

    # --- per street: offsets and which sides get a sidewalk -----------------
    # Pass 1 decides offsets; pass 2 (vectorised) checks for OSM sidewalks already there.
    plan = {}    # edge index -> dict(off_L, off_R, left, right, private)
    counts = collections.Counter()
    cand = []    # (i, mx, my, nx, ny, off_L, off_R, left, right)
    for i in street_idx:
        u, v, d = base_edges[i]
        (ux, uy), (vx, vy) = node_xy[u], node_xy[v]
        dx, dy = vx - ux, vy - uy
        L = math.hypot(dx, dy)
        if L < 1.0:
            continue
        nx, ny = -dy / L, dx / L                     # left normal (u->v)
        side, sw_m, cls = datasf.get(i, (None, None, None)) if datasf else (None, None, None)
        if side == "None":
            counts["no sidewalk (DataSF)"] += 1
            continue
        hw = str(d.get("highway", ""))
        sv = survey_sides.get(i)
        if str(d.get("sidewalk", "")) in ("no", "none") and side is None and sv is None:
            counts["no sidewalk (OSM tag)"] += 1
            continue
        roadway = ROADWAY_BY_CLASS.get(cls) or ROADWAY_BY_HIGHWAY.get(hw, 12.0)
        tagged_width = _metres(d.get("width", ""))
        if tagged_width is not None and 4.0 <= tagged_width <= 40.0:
            roadway = tagged_width
        else:
            lanes = str(d.get("lanes", ""))
            if lanes not in ("", "nan"):
                try:
                    roadway = max(roadway, float(lanes.split(";")[0]) * 3.2 + 4.4)
                except ValueError:
                    pass
        tag_sw = None
        for key in ("sidewalk:both:width", "sidewalk:width"):
            tag_sw = tag_sw or _metres(d.get(key, ""))
        sidewalk = sw_m if (sw_m is not None and sw_m > 0.5) else (tag_sw if tag_sw and tag_sw > 0.5 else DEFAULT_SIDEWALK_M)
        off_L = off_R = roadway / 2 + sidewalk / 2

        left = right = True
        if side and side not in ("Both", "None", "", "nan"):
            left = _compass_side_matches(side, nx, ny)
            right = _compass_side_matches(side, -nx, -ny)
        if sv is not None:
            for which, info in (("L", sv[0]), ("R", sv[1])):
                if info is None:
                    continue
                if not info.present:
                    if which == "L": left = False
                    else: right = False
                    counts[f"no sidewalk (survey)"] += 1
                    continue
                w = info.width if info.width else sidewalk
                off = info.offset if info.offset else roadway / 2 + w / 2
                off = min(max(off, 2.0), 30.0)
                if which == "L": off_L = off
                else: off_R = off
            counts["positioned by survey"] += 1
        if not (left or right):
            continue
        mx, my = (ux + vx) / 2, (uy + vy) / 2
        cand.append((i, mx, my, nx, ny, off_L, off_R, left, right, str(d.get("access", "")) == "private"))

    # Existing OSM sidewalks within 5 m of where ours would go: that side is drawn already.
    osm_sw_geoms = [LineString([node_xy[u], node_xy[v]]) for u, v, d in base_edges if is_osm_sidewalk(d)]
    osm_left = np.zeros(len(cand), bool); osm_right = np.zeros(len(cand), bool)
    if osm_sw_geoms and cand:
        import shapely
        tree = STRtree(osm_sw_geoms)
        arr = np.array([(c[1], c[2], c[3], c[4], c[5], c[6]) for c in cand])
        lp = shapely.points(arr[:, 0] + arr[:, 2] * arr[:, 4], arr[:, 1] + arr[:, 3] * arr[:, 4])
        rp = shapely.points(arr[:, 0] - arr[:, 2] * arr[:, 5], arr[:, 1] - arr[:, 3] * arr[:, 5])
        hit, _ = tree.query(lp, predicate="dwithin", distance=5); osm_left[hit] = True
        hit, _ = tree.query(rp, predicate="dwithin", distance=5); osm_right[hit] = True

    # Streets whose kerbs are all accounted for by OSM's own sidewalks: nothing to
    # synthesise, but the centreline must still go, or it stays a third, side-less path
    # down the middle (this was 40% of Seattle's "bare street" metres).
    # `sidewalk=separate` says the same thing in the tag: both sidewalks are their own
    # ways. Those streets are never synthesis candidates, and were never removed either —
    # 16 km of side-less centreline in 600 m of Park Slope.
    osm_complete = {i for i, (_, _, d) in enumerate(base_edges)
                    if enabled and str(d.get("highway", "")) in STREET
                    and str(d.get("sidewalk", "")) == "separate"
                    and "sidewalk" not in str(d.get("footway", ""))}
    counts["sidewalk=separate centrelines"] = len(osm_complete)
    for k, (i, mx, my, nx, ny, off_L, off_R, left, right, private) in enumerate(cand):
        ol, orr = bool(osm_left[k]), bool(osm_right[k])
        if left and ol:
            left = False; counts["left already in OSM"] += 1
        if right and orr:
            right = False; counts["right already in OSM"] += 1
        if not (left or right):
            if ol and orr:
                osm_complete.add(i)
                counts["both sides already in OSM"] += 1
            continue
        plan[i] = dict(off_L=off_L, off_R=off_R, left=left, right=right, osm_left=ol, osm_right=orr,
                       private=private)
        counts["synthesised"] += 1
        if left and right:
            counts["both sides"] += 1
    log(f"  plan: {dict(counts)}")

    # --- corner nodes per (node, edge, outward side) --------------------------
    incident = collections.defaultdict(list)     # node -> [(bearing, edge idx, other node)]
    for i in plan:
        u, v, _ = base_edges[i]
        (ux, uy), (vx, vy) = node_xy[u], node_xy[v]
        incident[u].append((_bearing(vx - ux, vy - uy), i, v))
        incident[v].append((_bearing(ux - vx, uy - vy), i, u))

    # Edges at each node that synthesis will NOT replace: footways, crossings, and
    # streets that were skipped. Wherever one of these meets a synthesised street the
    # centreline node must stay linked to the new corners, or it is stranded.
    unplanned_at = collections.defaultdict(int)
    for idx, (u, v, d) in enumerate(base_edges):
        if idx not in plan:
            unplanned_at[u] += 1
            unplanned_at[v] += 1

    new_nodes = {}                 # new id -> (x, y)
    corner = {}                    # (node, edge idx, 'L'|'R' outward) -> new node id
    next_id = [10 ** 12]

    def new_node(x, y):
        nid = next_id[0]; next_id[0] += 1
        new_nodes[nid] = (x, y)
        return nid

    def offset_point(n, i, side):
        """Outward-left/right offset of node n along edge i, plus the unit direction."""
        u, v, _ = base_edges[i]
        other = v if u == n else u
        (nx0, ny0), (ox, oy) = node_xy[n], node_xy[other]
        dx, dy = ox - nx0, oy - ny0
        L = math.hypot(dx, dy)
        dx, dy = dx / L, dy / L
        lx, ly = -dy, dx                       # left of outward direction
        s = 1 if side == "L" else -1
        # Left of the outward direction is the street's left at u and its right at v.
        street_side = side if n == u else ("R" if side == "L" else "L")
        off = plan[i]["off_L"] if street_side == "L" else plan[i]["off_R"]
        return (nx0 + s * lx * off, ny0 + s * ly * off, dx, dy)

    def line_intersection(p, d, q, e):
        cross = d[0] * e[1] - d[1] * e[0]
        if abs(cross) < 1e-6:
            return None
        t = ((q[0] - p[0]) * e[1] - (q[1] - p[1]) * e[0]) / cross
        return (p[0] + d[0] * t, p[1] + d[1] * t, t)

    new_edges = []                 # (a, b, length, flags)
    links = 0; crossings = 0; wraps = 0

    for n, lst in incident.items():
        lst.sort()
        k = len(lst)
        if k == 1:
            _, i, _ = lst[0]
            lx, ly, dx, dy = offset_point(n, i, "L")
            rx, ry, _, _ = offset_point(n, i, "R")
            a = new_node(lx, ly); b = new_node(rx, ry)
            corner[(n, i, "L")] = a; corner[(n, i, "R")] = b
            new_edges.append((a, b, math.hypot(lx - rx, ly - ry), FLAG_SIDEWALK | FLAG_SYNTHETIC))
            (nx0, ny0) = node_xy[n]
            for c, (cx, cy) in ((a, (lx, ly)), (b, (rx, ry))):
                new_edges.append((n, c, math.hypot(nx0 - cx, ny0 - cy), FLAG_SYNTHETIC))
                links += 1
            wraps += 1
            continue
        for j in range(k):
            _, i, _ = lst[j]
            _, i2, _ = lst[(j + 1) % k]
            px, py, dx, dy = offset_point(n, i, "L")
            qx, qy, ex, ey = offset_point(n, i2, "R")
            hit = line_intersection((px, py), (dx, dy), (qx, qy), (ex, ey))
            # Sharp angles fling the intersection far away; parallel edges have none.
            reach = max(plan[i]["off_L"], plan[i]["off_R"], plan[i2]["off_L"], plan[i2]["off_R"])
            if hit is None or hit[2] < -2 or hit[2] > 4 * reach:
                cx, cy = (px + qx) / 2, (py + qy) / 2
            else:
                cx, cy = hit[0], hit[1]
            c = new_node(cx, cy)
            corner[(n, i, "L")] = c
            corner[(n, i2, "R")] = c

        # Crossings across every street at a real intersection; links from the
        # centreline node to its corners wherever something else attaches there.
        street_deg = k
        if street_deg >= 3:
            for _, i, _ in lst:
                a = corner[(n, i, "L")]; b = corner[(n, i, "R")]
                (ax, ay), (bx, by) = new_nodes[a], new_nodes[b]
                new_edges.append((a, b, math.hypot(ax - bx, ay - by), FLAG_CROSSING | FLAG_SYNTHETIC))
                crossings += 1
        if street_deg >= 3 or unplanned_at.get(n, 0) > 0:
            (nx0, ny0) = node_xy[n]
            for c in {corner[(n, i, s)] for _, i, _ in lst for s in ("L", "R")}:
                cx, cy = new_nodes[c]
                new_edges.append((n, c, math.hypot(nx0 - cx, ny0 - cy), FLAG_SYNTHETIC))
                links += 1

    # --- sidewalk edges along each street --------------------------------------
    sidewalks = 0
    removed = set()
    for i, p in plan.items():
        u, v, _ = base_edges[i]
        pflag = FLAG_PRIVATE if p.get("private") else 0
        if p["left"]:
            a = corner[(u, i, "L")]; b = corner[(v, i, "R")]
            (ax, ay), (bx, by) = new_nodes[a], new_nodes[b]
            new_edges.append((a, b, math.hypot(ax - bx, ay - by), FLAG_SIDEWALK | FLAG_SYNTHETIC | pflag))
            sidewalks += 1
        if p["right"]:
            a = corner[(u, i, "R")]; b = corner[(v, i, "L")]
            (ax, ay), (bx, by) = new_nodes[a], new_nodes[b]
            new_edges.append((a, b, math.hypot(ax - bx, ay - by), FLAG_SIDEWALK | FLAG_SYNTHETIC | pflag))
            sidewalks += 1
        # The centreline goes once BOTH kerbs have a sidewalk, whether OSM drew it or
        # we did; keeping it would leave a third, side-less path down the middle.
        if (p["left"] or p["osm_left"]) and (p["right"] or p["osm_right"]):
            removed.add(i)
    removed |= osm_complete

    # Where an alley, path or driveway met a centreline OSM had fully sidewalked, the
    # centreline is gone and that junction would strand everything behind it (5% of
    # Seattle's nodes). Link the junction to the nearest OSM sidewalk node on each side,
    # as synthesis links its own corners.
    osm_links = 0
    if osm_complete:
        from scipy.spatial import cKDTree
        sw_nodes = sorted({n for u, v, d in base_edges if is_osm_sidewalk(d) for n in (u, v)})
        if sw_nodes:
            sw_xy = np.array([node_xy[n] for n in sw_nodes])
            kd = cKDTree(sw_xy)
            attach = collections.defaultdict(int)       # node -> non-street, non-crossing edges
            street_dir = {}
            for idx, (u, v, d) in enumerate(base_edges):
                if idx in removed:
                    continue
                fw = str(d.get("footway", "")); hw = str(d.get("highway", ""))
                if "crossing" in fw or hw == "crossing" or "sidewalk" in fw:
                    continue
                attach[u] += 1; attach[v] += 1
            for i in osm_complete:
                u, v, _ = base_edges[i]
                (ux, uy), (vx, vy) = node_xy[u], node_xy[v]
                L = max(math.hypot(vx - ux, vy - uy), 1e-6)
                for n in (u, v):
                    street_dir.setdefault(n, ((vx - ux) / L, (vy - uy) / L))
            for n, (dx, dy) in street_dir.items():
                # Something still hangs off this junction: an alley or path, or a street
                # we synthesised sidewalks for (its corners link to this node) — without
                # a link to OSM's sidewalks it becomes an island (5% of LA's nodes).
                if attach.get(n, 0) == 0 and n not in incident:
                    continue
                x0, y0 = node_xy[n]
                dist, idx = kd.query((x0, y0), k=12, distance_upper_bound=25)
                best = {}
                for dd, k in zip(np.atleast_1d(dist), np.atleast_1d(idx)):
                    if not np.isfinite(dd) or k >= len(sw_nodes):
                        continue
                    sx, sy = sw_xy[k]
                    side = "L" if (-(dy) * (sx - x0) + dx * (sy - y0)) > 0 else "R"
                    if side not in best:
                        best[side] = (dd, sw_nodes[k])
                for dd, m in best.values():
                    new_edges.append((n, m, float(dd), FLAG_SYNTHETIC))
                    osm_links += 1
    counts_links = osm_links

    # --- assemble ----------------------------------------------------------------
    nodes = {n: (d["y"], d["x"]) for n, d in G.nodes(data=True)}
    for nid, (x, y) in new_nodes.items():
        nodes[nid] = to_latlon(x, y)

    edges = []
    for i, (u, v, d) in enumerate(base_edges):
        if i in removed:
            continue
        flags = 0
        fw = str(d.get("footway", "")); hw = str(d.get("highway", ""))
        if "crossing" in fw or hw == "crossing":
            flags |= FLAG_CROSSING
        if "sidewalk" in fw:
            flags |= FLAG_SIDEWALK
        elif str(d.get("sidewalk", "")) not in ("", "nan", "no", "none", "None", "separate"):
            flags |= FLAG_STREET_SIDEWALK_TAG
        if hw == "steps":
            flags |= FLAG_STEPS
        if hw in STREET and "sidewalk" not in fw:
            flags |= FLAG_STREET
        if str(d.get("access", "")) == "private":
            flags |= FLAG_PRIVATE
        length = float(d.get("length", 0.0))
        if length > 0:
            edges.append((u, v, length, flags))
    edges.extend(new_edges)

    stats = dict(candidates=len(street_idx), synthesised=counts["synthesised"],
                 both_sides=counts["both sides"], sidewalk_edges=sidewalks,
                 crossings=crossings, links=links, dead_end_wraps=wraps,
                 centrelines_removed=len(removed), osm_complete=len(osm_complete),
                 osm_junction_links=counts_links, new_nodes=len(new_nodes))
    log(f"  synthesised {sidewalks} sidewalk edges, {crossings} crossings, {links} links, "
        f"{len(new_nodes)} corner nodes; removed {len(removed)} centrelines "
        f"({len(osm_complete)} already sidewalked in OSM, {counts_links} junction links to them)")
    return nodes, edges, stats
