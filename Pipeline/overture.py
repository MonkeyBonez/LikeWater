"""Building footprints with heights from Overture Maps (OSM + USGS Lidar + Microsoft ML).

Queried straight from the public GeoParquet on S3 with DuckDB; no account needed.
Falls back to None if the query fails so the caller can use OSM footprints.
"""
import time
import numpy as np
import geopandas as gpd
from shapely import wkb

RELEASE = "2026-08-19.0"
S3 = f"s3://overturemaps-us-west-2/release/{RELEASE}/theme=buildings/type=building/*"


def fetch_buildings(bbox, log=print, contained=True):
    """bbox = (min_lat, min_lon, max_lat, max_lon). Returns a GeoDataFrame in EPSG:4326
    with columns height (m, may be NaN), num_floors, source, geometry."""
    import duckdb
    min_lat, min_lon, max_lat, max_lon = bbox
    con = duckdb.connect()
    con.execute("INSTALL spatial; LOAD spatial; INSTALL httpfs; LOAD httpfs; SET s3_region='us-west-2';")
    if contained:
        where = (f"bbox.xmin >= {min_lon} AND bbox.xmax <= {max_lon} "
                 f"AND bbox.ymin >= {min_lat} AND bbox.ymax <= {max_lat}")
    else:   # anything overlapping the box: a tower just outside still shades inside
        where = (f"bbox.xmax >= {min_lon} AND bbox.xmin <= {max_lon} "
                 f"AND bbox.ymax >= {min_lat} AND bbox.ymin <= {max_lat}")
    t0 = time.time()
    df = con.execute(f"""
        SELECT id, height, num_floors, names.primary AS name,
               list_transform(sources, s -> s.dataset)[1] AS source,
               ST_AsWKB(geometry) AS wkb
        FROM read_parquet('{S3}', hive_partitioning=1)
        WHERE {where}
          AND (is_underground IS NULL OR NOT is_underground)
    """).df()
    log(f"  Overture: {len(df)} buildings in {time.time() - t0:.0f}s "
        f"({int(df['height'].notna().sum())} with height)")
    import shapely
    geoms = shapely.from_wkb(df["wkb"].map(bytes).to_numpy())
    gdf = gpd.GeoDataFrame(df.drop(columns=["wkb"]), geometry=geoms, crs="EPSG:4326")
    return gdf


def heights(gdf, default=10.0, floor_height=3.5, local_default=True, radius_m=150.0):
    """Height per footprint. Where neither height nor floors is known, use the median
    height of measured neighbours within `radius_m` — a house among houses is a house,
    a gap in downtown is downtown — falling back to the city median, then `default`."""
    h = gdf["height"].astype(float).to_numpy()
    f = gdf["num_floors"].astype(float).to_numpy() if "num_floors" in gdf else np.full(len(gdf), np.nan)
    known = np.where(np.isfinite(h) & (h > 0), h,
                     np.where(np.isfinite(f) & (f > 0), f * floor_height, np.nan))
    missing = ~np.isfinite(known)
    if not missing.any():
        return known
    if not local_default:
        return np.where(missing, default, known)          # the old behaviour: flat 10 m
    fill = np.full(len(gdf), np.nanmedian(known) if np.isfinite(known).any() else default)
    if np.isfinite(known).any():
        from scipy.spatial import cKDTree
        cent = gdf.geometry.representative_point()
        lat0 = float(cent.y.mean())
        xy = np.column_stack([cent.x.to_numpy() * 111_320 * np.cos(np.radians(lat0)),
                              cent.y.to_numpy() * 110_540])
        tree = cKDTree(xy[~missing])
        kv = known[~missing]
        miss = np.flatnonzero(missing)
        neighbours = tree.query_ball_point(xy[miss], radius_m, workers=-1)
        for i, idx in zip(miss, neighbours):
            if len(idx) >= 3:
                fill[i] = float(np.median(kv[idx]))
    return np.where(missing, fill, known)
