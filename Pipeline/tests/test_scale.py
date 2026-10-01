"""Pipeline pieces added to build New York, Los Angeles and Seattle."""
import math, sys
from pathlib import Path
import numpy as np
import geopandas as gpd
import shapely
from shapely.geometry import Polygon, box

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_bundle as bb
import survey as sv
import terrain as tm


def test_build_csr_matches_a_python_loop():
    rng = np.random.default_rng(1)
    n, m = 200, 600
    a = rng.integers(0, n, m); b = rng.integers(0, n, m)
    start, adj_node, adj_edge = bb.build_csr(n, a, b)
    assert start[-1] == 2 * m
    for u in range(n):
        got = sorted(zip(adj_node[start[u]:start[u + 1]].tolist(), adj_edge[start[u]:start[u + 1]].tolist()))
        want = sorted([(int(b[i]), i) for i in range(m) if a[i] == u] + [(int(a[i]), i) for i in range(m) if b[i] == u])
        assert got == want


def test_flatten_buildings_drops_closing_points_and_keeps_heights():
    polys = [box(-122.40, 37.78, -122.3999, 37.7801), Polygon([(-122.41, 37.78), (-122.4099, 37.78), (-122.4099, 37.7801)])]
    gdf = gpd.GeoDataFrame({"height": [30.0, 12.0], "num_floors": [np.nan, np.nan]}, geometry=polys, crs="EPSG:4326")
    start, lat, lon, h = bb.flatten_buildings(gdf)
    assert list(np.diff(start)) == [4, 3]
    assert list(h) == [30.0, 12.0]
    assert abs(lat[0] - 37.78) < 1e-5 or abs(lat[0] - 37.7801) < 1e-5
    clat, clon = bb.building_centroids(start, lat, lon)
    assert abs(clat[0] - 37.78005) < 1e-5 and abs(clon[0] + 122.39995) < 1e-5


def _plane_street(n=1, length=100.0, y=0.0):
    mids = np.array([[length / 2, y]] * n); dirs = np.array([[1.0, 0.0]] * n)
    normals = np.array([[0.0, 1.0]] * n); lengths = np.full(n, length)
    return mids, dirs, normals, lengths


def test_polygon_survey_reads_kerb_offset_and_width_from_geometry():
    s = sv.PolygonSurvey.__new__(sv.PolygonSurvey); s.ray_m = 35.0
    # Sidewalk strip on the left from 6 m to 10 m; nothing on the right.
    s.polys = np.array([box(-50, 6, 150, 10)]); s.tree = shapely.STRtree(s.polys)
    (left, right), = s.lookup(*_plane_street())
    assert left.present and abs(left.width - 4) < 1e-6 and abs(left.offset - 8) < 1e-6
    assert right is not None and not right.present, "covered area, no polygon on that side: no sidewalk"


def test_polygon_survey_has_no_opinion_from_inside_a_plaza():
    s = sv.PolygonSurvey.__new__(sv.PolygonSurvey); s.ray_m = 35.0
    s.polys = np.array([box(-50, -20, 150, 20)]); s.tree = shapely.STRtree(s.polys)
    (left, right), = s.lookup(*_plane_street())
    assert left is None and right is None


def test_aggregate_by_way_overrules_short_segments_near_corners():
    yes = sv.SideInfo(True, 4.0, 9.0); no = sv.SideInfo(False)
    # One 80 m block split into a 70 m middle and two 5 m ends that look into cross streets.
    answers = [(no, no), (yes, yes), (no, no)]
    dirs = [(1, 0), (1, 0), (1, 0)]
    out = sv.aggregate_by_way(answers, ["w", "w", "w"], dirs, [5.0, 70.0, 5.0])
    assert all(o[0].present and o[1].present and o[0].offset == 9.0 for o in out)


def test_aggregate_by_way_handles_reversed_segments():
    yes = sv.SideInfo(True, 4.0, 9.0); no = sv.SideInfo(False)
    # Second segment drawn the other way: its "right" is the way's left.
    answers = [(yes, no), (no, yes)]
    out = sv.aggregate_by_way(answers, ["w", "w"], [(1, 0), (-1, 0)], [50.0, 50.0])
    assert out[0][0].present and not out[0][1].present
    assert out[1][1].present and not out[1][0].present


def test_line_survey_matches_per_side_and_honours_absent_rows():
    s = sv.LineSurvey.__new__(sv.LineSurvey); s.search_m = 25.0
    s.lines = np.array([shapely.LineString([(-10, 8), (110, 8)]), shapely.LineString([(-10, -8), (110, -8)])])
    s.width = np.array([1.8, np.nan]); s.present = np.array([True, False]); s.side = np.array(["N", "S"])
    s.tree = shapely.STRtree(s.lines)
    (left, right), = s.lookup(*_plane_street())
    assert left.present and abs(left.offset - 8) < 1e-6 and abs(left.width - 1.8) < 1e-6
    assert not right.present


def test_terrain_lattice_is_shared_between_neighbouring_tiles():
    sl, so = tm.lattice(40.7, 10)
    r = lambda lat: lat / sl
    # Origins are integer multiples of the step, so two tiles align cell for cell.
    a = math.floor(40.70 / sl) * sl; b = math.floor(40.74 / sl) * sl
    assert abs(r(a) - round(r(a))) < 1e-6 and abs(r(b) - round(r(b))) < 1e-6
