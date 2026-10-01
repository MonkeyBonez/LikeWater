"""Reference sun positions from pvlib's NREL SPA implementation.

SPA is accurate to about 0.0003 degrees, so it is a genuine oracle for the
NOAA algorithm the app ships. Regenerate with:
    .venv/bin/python solar_vectors.py > ../Engine/Tests/LikeWaterEngineTests/Fixtures/solar_vectors.json
"""
import json
import pandas as pd
import pvlib

SITES = [
    ("San Francisco", 37.7749, -122.4194),
    ("Reykjavik", 64.1466, -21.9426),
    ("Singapore", 1.3521, 103.8198),
    ("Sydney", -33.8688, 151.2093),
]

STAMPS = [
    "2026-03-20 19:00", "2026-03-20 12:00",      # equinox
    "2026-06-21 20:00", "2026-06-21 13:30",      # June solstice
    "2026-09-23 17:00", "2026-09-23 23:45",
    "2026-12-21 20:00", "2026-12-21 00:10",      # December solstice
    "2026-12-04 00:00", "2026-07-15 02:30",
]

out = []
for name, lat, lon in SITES:
    index = pd.DatetimeIndex(pd.to_datetime(STAMPS)).tz_localize("UTC")
    sp = pvlib.solarposition.spa_python(index, lat, lon, altitude=0,
                                        pressure=101325, temperature=12)
    for stamp, row in sp.iterrows():
        out.append({
            "site": name, "lat": lat, "lon": lon,
            "utc": stamp.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "elevation": round(float(row["apparent_elevation"]), 6),
            "azimuth": round(float(row["azimuth"]), 6),
        })
print(json.dumps(out, indent=1))
