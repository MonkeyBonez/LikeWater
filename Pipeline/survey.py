"""Sidewalk surveys from city open data, reduced to one question per street side:
is there a sidewalk here, and if so how far from the centreline and how wide?

Every city publishes this differently, so each adapter answers the same question
from a different shape of data:

* `LineSurvey` — one line per sidewalk (Seattle SDOT: 46k lines with SIDE, SW_WIDTH in
  inches, SURFTYPE='UIMPRV' for "no sidewalk"). Lines are matched per side of each
  street: nearest roughly-parallel survey line on that side of the centreline.
* `PolygonSurvey` — the sidewalk surface as polygons (NYC Planimetrics: 50,865
  polygons). A ray is cast from the street midpoint along each normal; the first
  polygon it enters gives the kerb (entry) and the property line (exit), so the
  offset and the width both come from measured geometry.

Where a survey has anything within `coverage_m` of a street it is trusted, and a
side with no match means "no sidewalk". Where it has nothing nearby (outside the
survey's area), the street falls back to synthesis defaults.

All geometry is in the synthesis plane: x = lon * mlon, y = lat * mlat (metres).
"""
import math
import numpy as np
import geopandas as gpd
import shapely
from shapely.strtree import STRtree


class SideInfo:
    __slots__ = ("present", "width", "offset")

    def __init__(self, present, width=None, offset=None):
        self.present = present; self.width = width; self.offset = offset

    def __repr__(self):
        return f"SideInfo({self.present}, w={self.width}, off={self.offset})"


def _to_plane(geoms, mlat, mlon):
    return shapely.transform(np.asarray(geoms), lambda c: np.column_stack([c[:, 0] * mlon, c[:, 1] * mlat]))


class _Base:
    coverage_m = 40.0

    def load(self, mlat, mlon, bounds_lonlat=None, log=print):
        raise NotImplementedError

    def lookup(self, mids, dirs, normals, lengths, log=print):
        """mids/dirs/normals: (n, 2) arrays in the plane; returns list of
        (left: SideInfo|None, right: SideInfo|None) — None means "survey has no opinion"."""
        raise NotImplementedError


class LineSurvey(_Base):
    def __init__(self, path, width_col, width_scale, side_col=None, absent=None, search_m=25.0):
        self.path = path; self.width_col = width_col; self.width_scale = width_scale
        self.side_col = side_col; self.absent = absent or (lambda props: False)
        self.search_m = search_m

    def load(self, mlat, mlon, bounds_lonlat=None, log=print):
        gdf = gpd.read_file(self.path, bbox=bounds_lonlat) if bounds_lonlat else gpd.read_file(self.path)
        gdf = gdf[gdf.geometry.notna() & ~gdf.geometry.is_empty].copy()
        gdf = gdf.explode(index_parts=False).reset_index(drop=True)
        gdf = gdf[gdf.geometry.geom_type == "LineString"]
        self.lines = _to_plane(gdf.geometry.values, mlat, mlon)
        w = gdf[self.width_col].astype(float).to_numpy() * self.width_scale if self.width_col in gdf else np.full(len(gdf), np.nan)
        self.width = np.where(np.isfinite(w) & (w > 0.5), w, np.nan)
        self.present = ~gdf.apply(lambda r: bool(self.absent(r)), axis=1).to_numpy()
        self.side = gdf[self.side_col].astype(str).to_numpy() if self.side_col and self.side_col in gdf else np.full(len(gdf), "")
        self.tree = STRtree(self.lines)
        log(f"  survey: {len(self.lines)} lines ({int((~self.present).sum())} marked no-sidewalk)")
        return self

    def lookup(self, mids, dirs, normals, lengths, log=print):
        n = len(mids)
        out = [(None, None) for _ in range(n)]
        pts = shapely.points(mids)
        si, li = self.tree.query(pts, predicate="dwithin", distance=self.search_m)
        if len(si) == 0:
            return out
        lines = self.lines[li]
        loc = shapely.line_locate_point(lines, pts[si])
        near = shapely.get_coordinates(shapely.line_interpolate_point(lines, loc))
        # Local direction of the survey line at the nearest point.
        a = shapely.get_coordinates(shapely.line_interpolate_point(lines, np.maximum(loc - 2, 0)))
        b = shapely.get_coordinates(shapely.line_interpolate_point(lines, loc + 2))
        ld = b - a
        ln = np.hypot(ld[:, 0], ld[:, 1]); ln[ln == 0] = 1
        cosang = np.abs((ld[:, 0] * dirs[si, 0] + ld[:, 1] * dirs[si, 1]) / ln)
        v = near - mids[si]
        s = v[:, 0] * normals[si, 0] + v[:, 1] * normals[si, 1]          # + = left
        along = v[:, 0] * dirs[si, 0] + v[:, 1] * dirs[si, 1]
        ok = (cosang > 0.8) & (np.abs(along) < lengths[si] / 2 + 5)
        covered = np.zeros(n, bool); covered[si] = True

        best = {}   # (street, side) -> (|s|, line index, |s| or None)
        for k in np.flatnonzero(ok):
            street = int(si[k]); j = int(li[k]); sk = float(s[k])
            if abs(sk) <= 1.5:
                # Drawn on the centreline: the attribute says which side(s).
                side = self.side[j].upper()
                sides = []
                if side in ("", "BOTH", "B", "NAN", "NONE"):
                    sides = ["L", "R"]
                else:
                    want = {"N": (0, 1), "S": (0, -1), "E": (1, 0), "W": (-1, 0), "NE": (0.7, 0.7),
                            "NW": (-0.7, 0.7), "SE": (0.7, -0.7), "SW": (-0.7, -0.7)}.get(side)
                    if want is None:
                        sides = ["L", "R"]
                    else:
                        dot = normals[street, 0] * want[0] + normals[street, 1] * want[1]
                        sides = ["L"] if dot > 0 else ["R"]
                for sd in sides:
                    key = (street, sd)
                    if key not in best or abs(sk) < best[key][0]:
                        best[key] = (abs(sk), j, None)
            else:
                sd = "L" if sk > 0 else "R"
                key = (street, sd)
                if key not in best or abs(sk) < best[key][0]:
                    best[key] = (abs(sk), j, abs(sk))

        for street in np.flatnonzero(covered):
            res = []
            for sd in ("L", "R"):
                hit = best.get((int(street), sd))
                if hit is None:
                    res.append(SideInfo(False))
                else:
                    _, j, off = hit
                    w = self.width[j]
                    res.append(SideInfo(bool(self.present[j]), None if np.isnan(w) else float(w), off))
            out[int(street)] = tuple(res)
        return out


class PolygonSurvey(_Base):
    def __init__(self, path, ray_m=35.0):
        self.path = path; self.ray_m = ray_m

    def load(self, mlat, mlon, bounds_lonlat=None, log=print):
        gdf = gpd.read_file(self.path, bbox=bounds_lonlat) if bounds_lonlat else gpd.read_file(self.path)
        gdf = gdf[gdf.geometry.notna() & ~gdf.geometry.is_empty]
        parts = shapely.get_parts(gdf.geometry.values)
        parts = parts[shapely.get_type_id(parts) == 3]                   # Polygon
        self.polys = _to_plane(parts, mlat, mlon)
        self.tree = STRtree(self.polys)
        log(f"  survey: {len(self.polys)} sidewalk polygons")
        return self

    def lookup(self, mids, dirs, normals, lengths, log=print):
        n = len(mids)
        out = [(None, None) for _ in range(n)]
        pts = shapely.points(mids)
        ci, _ = self.tree.query(pts, predicate="dwithin", distance=self.coverage_m)
        covered = np.zeros(n, bool); covered[ci] = True
        idx = np.flatnonzero(covered)
        if len(idx) == 0:
            return out
        result = {}
        for sd, sign in (("L", 1.0), ("R", -1.0)):
            ends = mids[idx] + sign * normals[idx] * self.ray_m
            rays = shapely.linestrings(np.stack([mids[idx], ends], axis=1))
            ri, pi = self.tree.query(rays, predicate="intersects")
            if len(ri) == 0:
                continue
            inter = shapely.intersection(rays[ri], self.polys[pi])
            coords, owner = shapely.get_coordinates(inter, return_index=True)
            street = idx[ri[owner]]
            t = ((coords[:, 0] - mids[street, 0]) * normals[street, 0]
                 + (coords[:, 1] - mids[street, 1]) * normals[street, 1]) * sign
            m = len(ri)
            tmin = np.full(m, np.inf); tmax = np.full(m, -np.inf)
            np.minimum.at(tmin, owner, t); np.maximum.at(tmax, owner, t)
            # Per ray: the first polygon entered.
            order = np.lexsort((tmin, ri))
            first = order[np.r_[True, ri[order][1:] != ri[order][:-1]]]
            for k in first:
                if not np.isfinite(tmin[k]):
                    continue
                s = int(idx[ri[k]])
                a, b = float(tmin[k]), float(tmax[k])
                if a < 0.5:
                    # The ray starts inside a polygon: a plaza or a pedestrianised
                    # street, not a kerb. No positional opinion.
                    result[(s, sd)] = None
                    continue
                width = min(max(b - a, 1.0), 10.0)
                result[(s, sd)] = SideInfo(True, width, a + width / 2)
        for s in idx:
            s = int(s)
            out[s] = tuple(result[(s, sd)] if (s, sd) in result else SideInfo(False) for sd in ("L", "R"))
        return out


def aggregate_by_way(answers, way_ids, dirs, lengths, min_length=20.0, present_share=0.3):
    """Decide each side once per OSM way (a street run), not per segment.

    A segment's own answer is unreliable near an intersection: a short piece next to a
    corner looks sideways into the cross street's roadway and finds no sidewalk (in
    Midtown 88% of per-segment "no sidewalk" answers were segments under 15 m). Over a
    whole way, a side is present if at least `present_share` of the length that got an
    answer found one, and then every segment uses the way's median offset and width —
    which also keeps kerb lines straight along a block. Segment orientation within a way
    is normalised against the way's first segment, since left/right is per direction.
    """
    import collections
    groups = collections.defaultdict(list)
    ref = {}
    for k, w in enumerate(way_ids):
        if w is None:
            continue
        d = dirs[k]
        if w not in ref:
            ref[w] = d
        flip = (d[0] * ref[w][0] + d[1] * ref[w][1]) < 0
        groups[w].append((k, flip))
    out = list(answers)
    for w, members in groups.items():
        agg = []
        for side in (0, 1):
            hit_len = miss_len = 0.0
            offs, widths = [], []
            for k, flip in members:
                a = answers[k]
                if a is None:
                    continue
                info = a[1 - side] if flip else a[side]
                if info is None:
                    continue
                if info.present:
                    hit_len += lengths[k]
                    if info.offset is not None: offs.append(info.offset)
                    if info.width is not None: widths.append(info.width)
                else:
                    miss_len += lengths[k]
            if hit_len + miss_len == 0:
                agg.append(None)
            elif hit_len / (hit_len + miss_len) >= present_share:
                agg.append(SideInfo(True, float(np.median(widths)) if widths else None,
                                    float(np.median(offs)) if offs else None))
            elif hit_len + miss_len >= min_length:
                agg.append(SideInfo(False))
            else:
                agg.append(None)
        for k, flip in members:
            out[k] = (agg[1], agg[0]) if flip else (agg[0], agg[1])
    return out


SURVEYS = {
    # Seattle SDOT "Sidewalks (Active)": SW_WIDTH is inches (median 72 = 6 ft);
    # SURFTYPE UIMPRV is an unimproved shoulder, i.e. no sidewalk.
    "seattle": lambda: LineSurvey(
        "data/seattle_sdot_sidewalks.gpkg", width_col="SW_WIDTH", width_scale=0.0254,
        side_col="SIDE", absent=lambda r: str(r.get("SURFTYPE", "")) == "UIMPRV"),
    # NYC Planimetrics sidewalk polygons (NYC Open Data 52n9-sdep).
    "nyc": lambda: PolygonSurvey("data/nyc_planimetrics_sidewalk.gpkg"),
}
