"""GOES-West fog / low-cloud proof of concept (PLAN.md §2 E).

Fetches the latest CONUS scan of four public GOES-18 L2 products (anonymous HTTPS from
the `noaa-goes18` bucket), crops them to a box, and classifies each cell of the apps'
weather lattice (`OpenMeteoSky.latticePoints`, 0.0225°) as

    clear | low (fog / stratus: liquid top below LOW_TOP_M) | mid_high | unknown

with an estimated direct-beam fraction, the scan time and the data latency. This is the
observation the forecast (HRRR via Open-Meteo) can't give: whether the fog is there *now*.

    .venv/bin/python goes_poc.py                     # latest scan, Bay Area, prints a table
    .venv/bin/python goes_poc.py --json out.json     # same, as JSON (what goes_log.py stores)
    .venv/bin/python goes_poc.py --at 2026-09-30T16:00Z --save-fixture tests/fixtures/goes_x.nc

Products (CONUS, every 5 min, ~1 min latency):
  ABI-L2-ACMC   clear-sky mask, 2 km        (ACM: 0 clear … 3 cloudy)
  ABI-L2-ACHAC  cloud-top height, 10 km     (HT, metres)
  ABI-L2-ACTPC  cloud-top phase, 2 km       (Phase: 0 clear, 1 liquid, 2 supercooled, 3 mixed, 4 ice)
  ABI-L2-CODC   cloud optical depth, 2 km   (COD; daytime algorithm only)
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

import numpy as np
import requests
import xarray as xr

BUCKET = "https://noaa-goes18.s3.amazonaws.com"
PRODUCTS = {"acm": "ABI-L2-ACMC", "height": "ABI-L2-ACHAC", "phase": "ABI-L2-ACTPC",
            "cod": "ABI-L2-CODC"}
CACHE = Path(__file__).parent / "cache" / "goes"

# lat_min, lon_min, lat_max, lon_max
BOXES = {
    "bayarea": (37.40, -122.70, 38.00, -122.05),
}

LOW_TOP_M = 2000.0        # "low cloud" as Open-Meteo means it (< 2 km); GOES tops of the marine layer read 0.4–1.9 km
CLOUDY_CLEAR_MAX = 0.25   # cloudy share of a cell below this → clear


# --- the apps' weather lattice (Engine/Sources/LikeWaterEngine/Sky.swift) -------------

LATTICE_STEP_LAT = 0.0225


def lattice_step_lon(lat: float) -> float:
    # Swift rounds half away from zero; Python's round() is banker's — use floor(x+0.5).
    return 0.0225 / max(0.2, math.cos(math.floor(lat + 0.5) * math.pi / 180))


def lattice_cells(box) -> list[tuple[float, float]]:
    """Every lattice point inside the box, rounded like the app rounds them."""
    lat0, lon0, lat1, lon1 = box
    d_lon = lattice_step_lon((lat0 + lat1) / 2)
    out = []
    i = math.ceil(lat0 / LATTICE_STEP_LAT)
    while i * LATTICE_STEP_LAT <= lat1:
        j = math.ceil(lon0 / d_lon)
        while j * d_lon <= lon1:
            out.append((round(i * LATTICE_STEP_LAT, 5), round(j * d_lon, 5)))
            j += 1
        i += 1
    return out


# --- ABI fixed grid ---------------------------------------------------------------------

def scan_angles(ds: xr.Dataset, lat, lon):
    """Latitude/longitude (degrees) → ABI scan angles x, y (radians), GOES-R PUG §4.2.8."""
    p = ds["goes_imager_projection"].attrs
    req = float(p["semi_major_axis"]); rpol = float(p["semi_minor_axis"])
    H = float(p["perspective_point_height"]) + req
    lon0 = math.radians(float(p["longitude_of_projection_origin"]))
    lat = np.radians(np.asarray(lat, dtype=float)); lon = np.radians(np.asarray(lon, dtype=float))
    e2 = (req**2 - rpol**2) / req**2
    phi_c = np.arctan((rpol**2 / req**2) * np.tan(lat))
    rc = rpol / np.sqrt(1 - e2 * np.cos(phi_c) ** 2)
    sx = H - rc * np.cos(phi_c) * np.cos(lon - lon0)
    sy = -rc * np.cos(phi_c) * np.sin(lon - lon0)
    sz = rc * np.sin(phi_c)
    y = np.arctan(sz / sx)
    x = np.arcsin(-sy / np.sqrt(sx**2 + sy**2 + sz**2))
    return x, y


def crop(ds: xr.Dataset, box, pad_deg: float = 0.1) -> xr.Dataset:
    lat0, lon0, lat1, lon1 = box
    lats = [lat0 - pad_deg, lat0 - pad_deg, lat1 + pad_deg, lat1 + pad_deg]
    lons = [lon0 - pad_deg, lon1 + pad_deg, lon0 - pad_deg, lon1 + pad_deg]
    x, y = scan_angles(ds, lats, lons)
    xs = ds["x"].values; ys = ds["y"].values
    xsel = (xs >= x.min()) & (xs <= x.max())
    ysel = (ys >= y.min()) & (ys <= y.max())
    return ds.isel(x=np.where(xsel)[0], y=np.where(ysel)[0])


def _cell_values(ds: xr.Dataset, var: str, lat: float, lon: float, half_lat: float,
                 half_lon: float) -> np.ndarray:
    """Pixel values whose centres fall inside the cell (nearest pixel if none do)."""
    x0, y0 = scan_angles(ds, [lat - half_lat, lat + half_lat], [lon - half_lon, lon + half_lon])
    xs = ds["x"].values; ys = ds["y"].values
    xi = np.where((xs >= min(x0)) & (xs <= max(x0)))[0]
    yi = np.where((ys >= min(y0)) & (ys <= max(y0)))[0]
    if len(xi) == 0 or len(yi) == 0:
        cx, cy = scan_angles(ds, [lat], [lon])
        xi = [int(np.abs(xs - cx[0]).argmin())]; yi = [int(np.abs(ys - cy[0]).argmin())]
    v = ds[var].isel(x=xi, y=yi).values.astype(float).ravel()
    return v[np.isfinite(v)]


# --- classification ---------------------------------------------------------------------

@dataclass
class CellSky:
    lat: float
    lon: float
    cls: str            # clear | low | mid_high | unknown
    beam: float | None  # estimated fraction of the clear-sky direct beam reaching the ground
    cloudy: float | None
    top_m: float | None
    phase: str | None
    cod: float | None


PHASES = {0: "clear", 1: "liquid", 2: "supercooled", 3: "mixed", 4: "ice"}


def classify(scan: dict[str, xr.Dataset], cells, sun_elevation_deg: float | None = None) -> list[CellSky]:
    """Classify each lattice cell from the cropped products of one scan."""
    out = []
    for lat, lon in cells:
        half_lat = LATTICE_STEP_LAT / 2; half_lon = lattice_step_lon(lat) / 2
        acm = _cell_values(scan["acm"], "ACM", lat, lon, half_lat, half_lon)
        if len(acm) == 0:
            out.append(CellSky(lat, lon, "unknown", None, None, None, None, None)); continue
        cloudy = float(np.mean(acm >= 2))
        top = phase = cod = None
        if "height" in scan:
            h = _cell_values(scan["height"], "HT", lat, lon, half_lat * 2, half_lon * 2)
            top = float(np.median(h)) if len(h) else None
        if "phase" in scan:
            ph = _cell_values(scan["phase"], "Phase", lat, lon, half_lat, half_lon)
            ph = ph[ph > 0]
            if len(ph):
                vals, counts = np.unique(ph.astype(int), return_counts=True)
                phase = PHASES.get(int(vals[counts.argmax()]), "unknown")
        if "cod" in scan:
            c = _cell_values(scan["cod"], "COD", lat, lon, half_lat, half_lon)
            cod = float(np.median(c)) if len(c) else None

        if cloudy < CLOUDY_CLEAR_MAX:
            cls = "clear"; cloud_beam = 0.0
        elif top is None and phase is None:
            cls = "unknown"; cloud_beam = None
        else:
            low = top is not None and top < LOW_TOP_M and phase in (None, "liquid", "supercooled")
            cls = "low" if low else "mid_high"
            if cod is not None and sun_elevation_deg is not None and sun_elevation_deg > 0:
                # Direct-beam transmittance through the cloud: exp(-τ · air mass).
                am = min(10.0, 1 / max(0.1, math.sin(math.radians(sun_elevation_deg))))
                cloud_beam = math.exp(-cod * am)
            else:
                # No optical depth (night, or COD missing): fog/stratus passes no beam,
                # higher cloud is assumed broken.
                cloud_beam = 0.0 if low else 0.3
        beam = None if cloud_beam is None else round((1 - cloudy) + cloudy * cloud_beam, 3)
        out.append(CellSky(lat, lon, cls, beam, round(cloudy, 3),
                           None if top is None else round(top), phase,
                           None if cod is None else round(cod, 2)))
    return out


# --- fetching ---------------------------------------------------------------------------

_KEY = re.compile(r"<Key>([^<]+)</Key><LastModified>([^<]+)</LastModified>")


def _list(prefix: str) -> list[tuple[str, str]]:
    r = requests.get(BUCKET, params={"list-type": "2", "prefix": prefix}, timeout=30)
    r.raise_for_status()
    return _KEY.findall(r.text)


def scan_start(key: str) -> datetime:
    m = re.search(r"_s(\d{4})(\d{3})(\d{2})(\d{2})(\d{2})", key)
    y, doy, hh, mm, ss = map(int, m.groups())
    return datetime(y, 1, 1, hh, mm, ss, tzinfo=timezone.utc) + timedelta(days=doy - 1)


def scan_end(key: str) -> datetime:
    m = re.search(r"_e(\d{4})(\d{3})(\d{2})(\d{2})(\d{2})", key)
    y, doy, hh, mm, ss = map(int, m.groups())
    return datetime(y, 1, 1, hh, mm, ss, tzinfo=timezone.utc) + timedelta(days=doy - 1)


def find_scan(at: datetime | None = None) -> dict[str, tuple[str, str]]:
    """Keys (and upload times) of one scan for every product: the latest scan all four
    products have, or the one starting closest to `at`."""
    when = at or datetime.now(timezone.utc)
    hours = [when - timedelta(hours=h) for h in (0, 1)] if at is None else [when]
    by_product = {}
    for name, product in PRODUCTS.items():
        keys = []
        for t in hours:
            keys += _list(f"{product}/{t:%Y}/{t.timetuple().tm_yday:03d}/{t:%H}/")
        by_product[name] = {re.search(r"_s(\d+)", k).group(1): (k, mod) for k, mod in keys}
    common = set.intersection(*(set(v) for v in by_product.values() if v)) if all(by_product.values()) else set()
    if not common:
        # COD is daytime-only and may lag; fall back to the three that always exist.
        core = {k: v for k, v in by_product.items() if k != "cod"}
        common = set.intersection(*(set(v) for v in core.values()))
        by_product = core
    if not common:
        raise RuntimeError(f"no complete GOES scan near {when:%Y-%m-%d %H:%M}Z")
    if at is None:
        pick = max(common)
    else:
        pick = min(common, key=lambda s: abs((scan_start("_s" + s) - at).total_seconds()))
    return {name: v[pick] for name, v in by_product.items()}


def fetch(key: str) -> Path:
    CACHE.mkdir(parents=True, exist_ok=True)
    path = CACHE / key.rsplit("/", 1)[1]
    if not path.exists():
        r = requests.get(f"{BUCKET}/{key}", timeout=120)
        r.raise_for_status()
        tmp = path.with_suffix(".part"); tmp.write_bytes(r.content); tmp.rename(path)
    return path


def load_scan(keys: dict[str, tuple[str, str]], box) -> dict[str, xr.Dataset]:
    return {name: crop(xr.open_dataset(fetch(key)), box).load() for name, (key, _) in keys.items()}


def prune_cache(keep_hours: float = 6) -> None:
    if not CACHE.exists():
        return
    cutoff = time.time() - keep_hours * 3600
    for p in CACHE.glob("*.nc"):
        if p.stat().st_mtime < cutoff:
            p.unlink()


def sun_elevation(lat: float, lon: float, when: datetime) -> float:
    """NOAA's low-precision solar elevation, degrees (good to ~0.5°, enough for air mass)."""
    d = (when - datetime(2000, 1, 1, 12, tzinfo=timezone.utc)).total_seconds() / 86400
    g = math.radians((357.529 + 0.98560028 * d) % 360)
    q = (280.459 + 0.98564736 * d) % 360
    L = math.radians((q + 1.915 * math.sin(g) + 0.020 * math.sin(2 * g)) % 360)
    e = math.radians(23.439 - 0.00000036 * d)
    dec = math.asin(math.sin(e) * math.sin(L))
    ra = math.atan2(math.cos(e) * math.sin(L), math.cos(L))
    gmst = (18.697374558 + 24.06570982441908 * d) % 24
    ha = math.radians(gmst * 15 + lon) - ra
    la = math.radians(lat)
    return math.degrees(math.asin(math.sin(la) * math.sin(dec) + math.cos(la) * math.cos(dec) * math.cos(ha)))


def observe(box_name: str = "bayarea", at: datetime | None = None) -> dict:
    box = BOXES[box_name]
    keys = find_scan(at)
    scan = load_scan(keys, box)
    start = scan_start(keys["acm"][0]); end = scan_end(keys["acm"][0])
    uploaded = max(datetime.fromisoformat(mod.replace("Z", "+00:00")) for _, mod in keys.values())
    lat_c = (box[0] + box[2]) / 2; lon_c = (box[1] + box[3]) / 2
    cells = classify(scan, lattice_cells(box), sun_elevation(lat_c, lon_c, end))
    return {
        "source": "GOES-18 ABI L2 (ACM, ACHA, ACTP, COD) via noaa-goes18",
        "box": box_name,
        "scan_start": start.isoformat(), "scan_end": end.isoformat(),
        "available": uploaded.isoformat(),
        "latency_s": round((uploaded - end).total_seconds()),
        "fetched": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "products": sorted(keys),
        "cells": [asdict(c) for c in cells],
    }


def save_fixture(keys, box, path: Path) -> None:
    """One small NetCDF group per product, cropped to the box — the test fixture."""
    scan = load_scan(keys, box)
    for i, (name, ds) in enumerate(scan.items()):
        keep = [v for v in ds.data_vars if v in ("ACM", "HT", "Phase", "COD", "goes_imager_projection")]
        ds[keep].to_netcdf(path, group=name, mode="w" if i == 0 else "a")


def load_fixture(path: Path) -> dict[str, xr.Dataset]:
    import netCDF4
    with netCDF4.Dataset(path) as nc:
        groups = list(nc.groups)
    return {g: xr.open_dataset(path, group=g).load() for g in groups}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--box", default="bayarea", choices=sorted(BOXES))
    ap.add_argument("--at", help="ISO time (UTC); default: latest scan")
    ap.add_argument("--json", type=Path, help="write the observation as JSON")
    ap.add_argument("--save-fixture", type=Path, help="write the cropped scan as a NetCDF fixture")
    a = ap.parse_args(argv)
    at = datetime.fromisoformat(a.at.replace("Z", "+00:00")) if a.at else None
    if a.save_fixture:
        save_fixture(find_scan(at), BOXES[a.box], a.save_fixture)
        print(f"wrote {a.save_fixture} ({a.save_fixture.stat().st_size // 1024} KB)")
        return
    obs = observe(a.box, at)
    if a.json:
        a.json.write_text(json.dumps(obs, indent=1))
    counts = {}
    for c in obs["cells"]:
        counts[c["cls"]] = counts.get(c["cls"], 0) + 1
    print(f"scan {obs['scan_start']} → available {obs['available']} (latency {obs['latency_s']} s)")
    print(f"{len(obs['cells'])} cells: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())))
    prune_cache()


if __name__ == "__main__":
    sys.exit(main())
