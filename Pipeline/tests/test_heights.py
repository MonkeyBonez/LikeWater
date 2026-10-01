"""Unknown building heights must come from the neighbourhood, not a global constant.
A flat 10 m default made every unmeasured Moorpark house twice as tall as its
neighbours and over-shaded 2-11% of sidewalk edges at low sun."""
import numpy as np
import geopandas as gpd
from shapely.geometry import box
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).parent.parent))
import overture


def _town(heights, size=0.0003):
    # A row of houses along a street, 30 m apart; None = unknown height.
    rows = []
    for i, h in enumerate(heights):
        x = -118.88 + i * size
        rows.append({"height": h, "num_floors": None, "geometry": box(x, 34.28, x + size * 0.6, 34.28 + size * 0.6)})
    return gpd.GeoDataFrame(rows, crs="EPSG:4326")


def test_unknown_house_among_houses_becomes_a_house():
    g = _town([5.0, 5.2, None, 4.8, 5.1, None, 5.0])
    h = overture.heights(g)
    assert abs(h[2] - 5.0) < 0.3
    assert abs(h[5] - 5.0) < 0.3
    assert not np.any(h == 10.0)


def test_unknown_building_downtown_becomes_downtown():
    g = _town([30.0, 42.0, None, 38.0, 35.0])
    h = overture.heights(g)
    assert 30 <= h[2] <= 42


def test_isolated_unknown_falls_back_to_city_median_not_ten():
    # Neighbours are 5 km away, outside the 150 m radius: city median (5 m) wins over 10 m.
    g = _town([5.0, 5.0, 5.0])
    far = gpd.GeoDataFrame([{"height": None, "num_floors": None,
                             "geometry": box(-118.83, 34.28, -118.8298, 34.2802)}], crs="EPSG:4326")
    g = gpd.GeoDataFrame(__import__("pandas").concat([g, far], ignore_index=True), crs="EPSG:4326")
    h = overture.heights(g)
    assert abs(h[3] - 5.0) < 1e-6


def test_floors_beat_the_default_and_known_heights_are_untouched():
    g = _town([12.0, None, None])
    g.loc[1, "num_floors"] = 3
    h = overture.heights(g)
    assert h[0] == 12.0
    assert abs(h[1] - 10.5) < 1e-6          # 3 floors x 3.5 m
    assert abs(h[2] - 11.25) < 1e-6         # median of its two neighbours (12, 10.5)


def test_old_behaviour_is_still_available_as_a_baseline():
    g = _town([5.0, None])
    assert overture.heights(g, local_default=False)[1] == 10.0
