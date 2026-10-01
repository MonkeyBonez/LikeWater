"""Ground elevation grid from AWS Terrain Tiles (Mapzen 'terrarium' encoding).

Open data, no key: https://registry.opendata.aws/terrain-tiles/. Tiles are
fetched at zoom 14 (~7.6 m/px at San Francisco's latitude), mosaicked, and
resampled onto a regular lat/lon grid at `step_m` metres so the engine can
sample it with plain bilinear arithmetic.
"""
import io, math, time
from concurrent.futures import ThreadPoolExecutor
import numpy as np
import requests
from PIL import Image

URL = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"


def _tile_xy(lat, lon, z):
    """Fractional slippy-tile coordinates; works on scalars and numpy arrays."""
    n = 2 ** z
    lat_r = np.radians(lat)
    x = (np.asarray(lon) + 180) / 360 * n
    y = (1 - np.log(np.tan(lat_r) + 1 / np.cos(lat_r)) / np.pi) / 2 * n
    return x, y


def _fetch(z, x, y, session):
    r = session.get(URL.format(z=z, x=x, y=y), timeout=30)
    r.raise_for_status()
    rgb = np.asarray(Image.open(io.BytesIO(r.content)).convert("RGB"), dtype=np.float64)
    return rgb[..., 0] * 256 + rgb[..., 1] + rgb[..., 2] / 256 - 32768


def fetch_grid(bbox, z=14, step_m=10.0, log=print):
    """bbox = (min_lat, min_lon, max_lat, max_lon).
    Returns dict(rows, cols, origin_lat, origin_lon, step_lat, step_lon, elevation int16[rows, cols])."""
    min_lat, min_lon, max_lat, max_lon = bbox
    x0, y1 = _tile_xy(max_lat, min_lon, z)     # top-left tile
    x1, y0 = _tile_xy(min_lat, max_lon, z)     # bottom-right
    tx0, tx1 = int(np.floor(x0)), int(np.floor(x1))
    ty0, ty1 = int(np.floor(y1)), int(np.floor(y0))
    tiles = [(x, y) for y in range(ty0, ty1 + 1) for x in range(tx0, tx1 + 1)]
    log(f"  terrain: {len(tiles)} tiles at z{z}")

    t0 = time.time()
    with requests.Session() as session, ThreadPoolExecutor(8) as pool:
        data = list(pool.map(lambda t: _fetch(z, t[0], t[1], session), tiles))
    log(f"  terrain: fetched in {time.time() - t0:.0f}s")

    W = (tx1 - tx0 + 1) * 256
    H = (ty1 - ty0 + 1) * 256
    mosaic = np.zeros((H, W), dtype=np.float64)
    for (x, y), tile in zip(tiles, data):
        r, c = (y - ty0) * 256, (x - tx0) * 256
        mosaic[r:r + 256, c:c + 256] = tile

    # Resample onto a regular lat/lon grid.
    mid_lat = (min_lat + max_lat) / 2
    step_lat = step_m / 111_320.0
    step_lon = step_m / (111_320.0 * math.cos(math.radians(mid_lat)))
    rows = int(math.ceil((max_lat - min_lat) / step_lat)) + 1
    cols = int(math.ceil((max_lon - min_lon) / step_lon)) + 1
    lats = min_lat + np.arange(rows) * step_lat
    lons = min_lon + np.arange(cols) * step_lon
    px, py = _tile_xy(lats[:, None], lons[None, :], z)     # fractional tile coords
    px = (px - tx0) * 256 - 0.5
    py = (py - ty0) * 256 - 0.5
    px = np.clip(px, 0, W - 1.001); py = np.clip(py, 0, H - 1.001)
    ix, iy = np.floor(px).astype(int), np.floor(py).astype(int)
    fx, fy = px - ix, py - iy
    e = (mosaic[iy, ix] * (1 - fx) * (1 - fy) + mosaic[iy, ix + 1] * fx * (1 - fy)
         + mosaic[iy + 1, ix] * (1 - fx) * fy + mosaic[iy + 1, ix + 1] * fx * fy)
    e = np.where(e < -3, 0.0, e)                         # bathymetry / nodata -> sea level
    log(f"  terrain: {rows}x{cols} grid at {step_m:.0f} m, elevation {e.min():.0f}..{e.max():.0f} m")
    return dict(rows=rows, cols=cols, origin_lat=float(min_lat), origin_lon=float(min_lon),
                step_lat=float(step_lat), step_lon=float(step_lon),
                elevation=np.rint(e).astype(np.int16))


def sample(grid, lat, lon):
    """Bilinear ground elevation, metres; used for per-building ground levels."""
    r = (np.asarray(lat) - grid["origin_lat"]) / grid["step_lat"]
    c = (np.asarray(lon) - grid["origin_lon"]) / grid["step_lon"]
    r = np.clip(r, 0, grid["rows"] - 1.001); c = np.clip(c, 0, grid["cols"] - 1.001)
    r0, c0 = np.floor(r).astype(int), np.floor(c).astype(int)
    fr, fc = r - r0, c - c0
    E = grid["elevation"].astype(np.float64)
    return (E[r0, c0] * (1 - fr) * (1 - fc) + E[r0, c0 + 1] * (1 - fr) * fc
            + E[r0 + 1, c0] * fr * (1 - fc) + E[r0 + 1, c0 + 1] * fr * fc)


# --- Tiled metros ----------------------------------------------------------------
# Big cities are cut into tiles that the app stitches back together, so every tile's
# terrain must sit on one shared lattice: cell (r, c) is at (r*step_lat, c*step_lon)
# for the whole metro, and two neighbouring tiles agree exactly on their shared edge.
# Source tiles are cached on disk: a 1,300 km² city needs ~1,000 of them, and a
# failed run should not refetch any.

import os
from pathlib import Path
from functools import lru_cache

TILE_CACHE = Path(__file__).parent / "cache" / "terrain"


def lattice(ref_lat, step_m):
    """(step_lat, step_lon) for a metro: fixed per metro so tiles align."""
    return step_m / 111_320.0, step_m / (111_320.0 * math.cos(math.radians(ref_lat)))


@lru_cache(maxsize=256)
def _tile_cached(z, x, y):
    path = TILE_CACHE / str(z) / str(x) / f"{y}.png"
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        last = None
        for attempt in range(4):
            try:
                r = requests.get(URL.format(z=z, x=x, y=y), timeout=30)
                r.raise_for_status()
                path.write_bytes(r.content)
                break
            except Exception as exc:        # noqa: BLE001
                last = exc
                time.sleep(1.5 * (attempt + 1))
        else:
            raise RuntimeError(f"terrain tile {z}/{x}/{y} failed: {last}")
    rgb = np.asarray(Image.open(path).convert("RGB"), dtype=np.float32)
    return rgb[..., 0] * 256 + rgb[..., 1] + rgb[..., 2] / 256 - 32768


def prefetch(bbox, z, log=print):
    min_lat, min_lon, max_lat, max_lon = bbox
    x0, y1 = _tile_xy(max_lat, min_lon, z); x1, y0 = _tile_xy(min_lat, max_lon, z)
    tiles = [(int(x), int(y)) for y in range(int(np.floor(y1)), int(np.floor(y0)) + 1)
             for x in range(int(np.floor(x0)), int(np.floor(x1)) + 1)]
    missing = [t for t in tiles if not (TILE_CACHE / str(z) / str(t[0]) / f"{t[1]}.png").exists()]
    t0 = time.time()
    if missing:
        def get(t):
            _tile_cached.__wrapped__(z, t[0], t[1])
        with ThreadPoolExecutor(12) as pool:
            list(pool.map(get, missing))
    log(f"  terrain z{z}: {len(tiles)} source tiles ({len(missing)} fetched in {time.time() - t0:.0f}s)")


def aligned_grid(bbox, step_lat, step_lon, z=14):
    """Elevation on the shared lattice covering bbox (inclusive of both edges)."""
    min_lat, min_lon, max_lat, max_lon = bbox
    r0 = int(math.floor(min_lat / step_lat)); r1 = int(math.ceil(max_lat / step_lat))
    c0 = int(math.floor(min_lon / step_lon)); c1 = int(math.ceil(max_lon / step_lon))
    rows, cols = r1 - r0 + 1, c1 - c0 + 1
    lats = (r0 + np.arange(rows)) * step_lat
    lons = (c0 + np.arange(cols)) * step_lon
    px, py = _tile_xy(lats[:, None], lons[None, :], z)
    px, py = np.broadcast_arrays(px * 256 - 0.5, py * 256 - 0.5)
    ix, iy = np.floor(px).astype(np.int64), np.floor(py).astype(np.int64)
    fx, fy = (px - ix).astype(np.float32), (py - iy).astype(np.float32)

    def gather(gx, gy):
        tx, ty = gx // 256, gy // 256
        out = np.empty(gx.shape, dtype=np.float32)
        for key in set(zip(tx.ravel().tolist(), ty.ravel().tolist())):
            m = (tx == key[0]) & (ty == key[1])
            t = _tile_cached(z, key[0], key[1])
            out[m] = t[gy[m] - key[1] * 256, gx[m] - key[0] * 256]
        return out

    e = (gather(ix, iy) * (1 - fx) * (1 - fy) + gather(ix + 1, iy) * fx * (1 - fy)
         + gather(ix, iy + 1) * (1 - fx) * fy + gather(ix + 1, iy + 1) * fx * fy)
    e = np.where(e < -3, 0.0, e)
    return dict(rows=rows, cols=cols, origin_lat=float(r0 * step_lat), origin_lon=float(c0 * step_lon),
                step_lat=float(step_lat), step_lon=float(step_lon),
                elevation=np.rint(e).astype(np.int16))
