"""GOES fog POC classifier on two saved, cropped scans (PLAN.md §2 E)."""
from pathlib import Path

import goes_poc as g

FIX = Path(__file__).parent / "fixtures"
OCEAN_BEACH = (37.7625, -122.5063)
MISSION = (37.7600, -122.4180)


def cell_at(cells, point):
    return min(cells, key=lambda c: (c.lat - point[0]) ** 2 + (c.lon - point[1]) ** 2)


def classify_fixture(name, when):
    scan = g.load_fixture(FIX / name)
    box = (37.72, -122.52, 37.80, -122.40)
    return g.classify(scan, g.lattice_cells(box), g.sun_elevation(37.76, -122.45, when))


def test_fog_morning_puts_ocean_beach_under_low_cloud_and_the_mission_in_sun():
    from datetime import datetime, timezone
    cells = classify_fixture("goes_fog_20260916T1500Z.nc", datetime(2026, 9, 16, 15, tzinfo=timezone.utc))
    ob, mission = cell_at(cells, OCEAN_BEACH), cell_at(cells, MISSION)
    assert ob.cls == "low" and ob.phase == "liquid" and ob.beam < 0.05
    assert mission.cls == "clear" and mission.beam > 0.9


def test_clear_afternoon_is_clear_everywhere():
    from datetime import datetime, timezone
    cells = classify_fixture("goes_clear_20260925T2100Z.nc", datetime(2026, 9, 25, 21, tzinfo=timezone.utc))
    assert {c.cls for c in cells} == {"clear"}
    assert min(c.beam for c in cells) > 0.9


def test_lattice_matches_the_apps_rounding():
    # Sky.swift: OpenMeteoSky.latticePoints(around: 37.7749, -122.4194) centre cell.
    step_lon = g.lattice_step_lon(37.7749)
    assert abs(step_lon - 0.0225 / __import__("math").cos(38 * __import__("math").pi / 180)) < 1e-12
    cells = g.lattice_cells((37.77, -122.45, 37.78, -122.39))
    assert (37.7775, round(round(-122.4194 / step_lon) * step_lon, 5)) in cells


def test_scan_angles_hit_the_projection_origin():
    import numpy as np
    import xarray as xr
    ds = xr.Dataset(coords={"x": [0.0], "y": [0.0]})
    ds["goes_imager_projection"] = xr.DataArray(0, attrs={
        "semi_major_axis": 6378137.0, "semi_minor_axis": 6356752.31414,
        "perspective_point_height": 35786023.0, "longitude_of_projection_origin": -137.0})
    x, y = g.scan_angles(ds, [0.0], [-137.0])
    assert np.allclose([x[0], y[0]], [0, 0], atol=1e-12)


def test_report_prefers_the_source_that_matches_the_metar():
    import goes_report as rep
    def rec(hour_utc, goes_beam, om_beam, sfo, minute=0, obs_minutes_off=0):
        cell = [37.62, -122.37777]
        return {"scan_end": f"2026-09-16T{hour_utc:02d}:{minute:02d}:00+00:00", "latency_s": 120,
                "logged": f"2026-09-16T{hour_utc + 1:02d}:{minute:02d}:00+00:00",
                "stations": {"KSFO": cell},
                "metar": {"KSFO": {"time": f"2026-09-16T{hour_utc:02d}:{minute + obs_minutes_off:02d}:00+00:00",
                                   "layers": [{"amount": sfo, "base_m": 300}]}},
                "cells": [{"lat": cell[0], "lon": cell[1], "goes": {"beam": goes_beam},
                           "om": {"beam": om_beam}}]}
    # 9 am PDT: fog (GOES right), 10 am: burnt off, GOES sees it, the forecast doesn't.
    s = rep.score([rec(16, 0.0, 0.9, "OVC"), rec(17, 1.0, 0.1, "FEW"), rec(18, 1.0, 1.0, "FEW")])
    assert s["station_disagreements"] == 2 and s["goes_right_share"] == 1.0
    assert s["median_latency_min"] == 2.0 and s["median_delivery_min"] == 60.0
    assert s["fog_mornings"] == 1 and s["burnoff_error_min"]["goes"] == 0
    assert s["decision"] == "build the GOES job"
    # A METAR 40 min from the scan is not ground truth for it.
    s2 = rep.score([rec(16, 0.0, 0.9, "OVC", obs_minutes_off=40)])
    assert s2["station_disagreements"] == 0
    # A log that only starts at 10 am cannot claim a fog morning.
    s3 = rep.score([rec(17, 1.0, 0.1, "FEW"), rec(18, 1.0, 1.0, "FEW")])
    assert s3["fog_mornings"] == 0
