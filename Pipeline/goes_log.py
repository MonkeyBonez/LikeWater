"""Every-15-minute logger for the GOES fog POC (PLAN.md §2 E).

One JSON line per run in cache/goes_log/<UTC date>.jsonl with, for each lattice cell of
the San Francisco box (plus the cells holding SFO and OAK):
  goes  — class / beam / cloud-top / optical depth from goes_poc.classify
  om    — what the apps would have shown: Open-Meteo's 15-min DNI turned into a beam
          fraction exactly as Sky.swift does (DNI / clear-sky DNI) plus hourly low cloud
and once per run the latest METAR sky cover at KSFO and KOAK (api.weather.gov, free) as
ground truth. goes_report.py scores the log.

    .venv/bin/python goes_log.py                   # the latest scan (launchd calls this every 15 min)
    .venv/bin/python goes_log.py --since-hours 1   # every quarter-hour scan of the past hour (GitHub Actions, hourly)
    .venv/bin/python goes_log.py --dry-run         # print the rows instead of appending them
    .venv/bin/python goes_log.py --log-dir DIR     # where the daily .jsonl files go (default cache/goes_log)

NOAA keeps every scan on the bucket, so logging an hour late loses nothing: the row's
`latency_s` is upload time minus scan end, independent of when we fetched it. A scan
already in the day's file is skipped, so overlapping runs never double-log.

Open-Meteo is fetched at most once an hour (its HRRR-based forecast updates hourly) and
cached, so the logger costs ~35 locations × 24 = ~850 of the free tier's 10,000 daily calls.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import requests

import goes_poc as g

LOG_DIR = Path(__file__).parent / "cache" / "goes_log"
OM_CACHE = Path(__file__).parent / "cache" / "goes_om.json"
SF_BOX = (37.70, -122.53, 37.82, -122.36)
STATIONS = {"KSFO": (37.6190, -122.3749), "KOAK": (37.7213, -122.2208)}
USER_AGENT = "LikeWater GOES POC (github.com/MonkeyBonez/LikeWater)"


def log_cells() -> list[tuple[float, float]]:
    cells = g.lattice_cells(SF_BOX)
    for lat, lon in STATIONS.values():
        d_lon = g.lattice_step_lon(lat)
        c = (round(round(lat / g.LATTICE_STEP_LAT) * g.LATTICE_STEP_LAT, 5),
             round(round(lon / d_lon) * d_lon, 5))
        if c not in cells:
            cells.append(c)
    return cells


# --- Open-Meteo, as the apps ask for it ------------------------------------------------

def clear_sky_dni(elevation: float) -> float:
    """Sky.swift ClearSky.directNormal (Meinel & Meinel with Kasten–Young air mass)."""
    if elevation <= 0:
        return 0.0
    am = 1 / (math.sin(math.radians(elevation)) + 0.50572 * (elevation + 6.07995) ** -1.6364)
    return 1353 * 0.7 ** (am ** 0.678)


def open_meteo(cells, now: float) -> list[dict]:
    if OM_CACHE.exists():
        cached = json.loads(OM_CACHE.read_text())
        if now - cached["fetched"] < 3600 and cached["cells"] == [list(c) for c in cells]:
            return cached["data"]
    r = requests.get("https://api.open-meteo.com/v1/forecast", timeout=60, params={
        "latitude": ",".join(f"{c[0]:.5f}" for c in cells),
        "longitude": ",".join(f"{c[1]:.5f}" for c in cells),
        "minutely_15": "direct_normal_irradiance,diffuse_radiation",
        "hourly": "cloud_cover,cloud_cover_low",
        "past_days": 1, "forecast_days": 1, "timeformat": "unixtime", "timezone": "UTC",
        "models": "best_match"})
    r.raise_for_status()
    data = r.json()
    data = data if isinstance(data, list) else [data]
    OM_CACHE.parent.mkdir(parents=True, exist_ok=True)
    OM_CACHE.write_text(json.dumps({"fetched": now, "cells": [list(c) for c in cells], "data": data}))
    return data


def interp(t: float, times, values):
    pts = [(a, b) for a, b in zip(times, values) if b is not None]
    for (t0, v0), (t1, v1) in zip(pts, pts[1:]):
        if t0 <= t <= t1:
            return v0 if t1 == t0 else v0 + (v1 - v0) * (t - t0) / (t1 - t0)
    return None


def om_at(loc: dict, t: float, elevation: float) -> dict:
    dni = interp(t, loc["minutely_15"]["time"], loc["minutely_15"]["direct_normal_irradiance"])
    low = interp(t, loc["hourly"]["time"], loc["hourly"].get("cloud_cover_low") or [])
    total = interp(t, loc["hourly"]["time"], loc["hourly"]["cloud_cover"])
    clear = clear_sky_dni(elevation)
    beam = None if dni is None or clear <= 1 else round(min(1.0, max(0.0, dni / clear)), 3)
    return {"beam": beam, "dni": None if dni is None else round(dni),
            "low": None if low is None else round(low / 100, 2),
            "total": None if total is None else round(total / 100, 2)}


# --- METAR ------------------------------------------------------------------------------

def metar(station: str) -> dict | None:
    try:
        r = requests.get(f"https://api.weather.gov/stations/{station}/observations/latest",
                         headers={"User-Agent": USER_AGENT, "Accept": "application/geo+json"},
                         timeout=30)
        r.raise_for_status()
        p = r.json()["properties"]
    except Exception as e:  # ground truth is best-effort; the row is still useful
        return {"error": str(e)[:200]}
    layers = [{"amount": l.get("amount"), "base_m": (l.get("base") or {}).get("value")}
              for l in p.get("cloudLayers") or []]
    vis = (p.get("visibility") or {}).get("value")
    return {"time": p.get("timestamp"), "layers": layers, "visibility_m": vis,
            "raw": p.get("rawMessage")}


def metar_history(station: str, start: datetime, end: datetime) -> list[dict]:
    """Every observation of a station in a window, newest first (api.weather.gov)."""
    try:
        r = requests.get(f"https://api.weather.gov/stations/{station}/observations",
                         params={"start": start.isoformat(timespec="seconds"),
                                 "end": end.isoformat(timespec="seconds"), "limit": 100},
                         headers={"User-Agent": USER_AGENT, "Accept": "application/geo+json"}, timeout=30)
        r.raise_for_status()
        out = []
        for f in r.json().get("features", []):
            p = f["properties"]
            out.append({"time": p.get("timestamp"),
                        "layers": [{"amount": l.get("amount"), "base_m": (l.get("base") or {}).get("value")}
                                   for l in p.get("cloudLayers") or []],
                        "visibility_m": (p.get("visibility") or {}).get("value"), "raw": p.get("rawMessage")})
        return out
    except Exception as e:
        return [{"error": str(e)[:200]}]


def nearest_metar(history: list[dict], t: datetime, max_minutes: float = 45) -> dict | None:
    """The observation closest to `t`, if one is within `max_minutes`."""
    best, best_dt = None, None
    for m in history:
        if "time" not in m or not m["time"]:
            continue
        dt = abs((datetime.fromisoformat(m["time"].replace("Z", "+00:00")) - t).total_seconds()) / 60
        if dt <= max_minutes and (best_dt is None or dt < best_dt):
            best, best_dt = m, dt
    return best


def metar_sunny(m: dict | None) -> bool | None:
    """Ground truth for "is there direct sun": no broken/overcast layer, no obscured sky."""
    if not m or "layers" not in m:
        return None
    amounts = {l["amount"] for l in m["layers"]}
    if not amounts:
        return None
    return not (amounts & {"BKN", "OVC", "VV"})


def quarter_hours(since_hours: float, now: datetime) -> list[datetime]:
    """Every quarter-hour mark in (now − since_hours, now − 15 min]: scans we can fetch complete."""
    first = now - timedelta(hours=since_hours)
    t = first.replace(minute=(first.minute // 15) * 15, second=0, microsecond=0)
    out = []
    while t <= now - timedelta(minutes=15):
        if t > first:
            out.append(t)
        t += timedelta(minutes=15)
    return out


def logged_scan_ends(log_dir: Path, day: str) -> set[str]:
    path = log_dir / f"{day}.jsonl"
    if not path.exists():
        return set()
    out = set()
    for line in path.read_text().splitlines():
        try:
            out.add(json.loads(line)["scan_end"])
        except Exception:
            continue
    return out


def observe(cells, at: datetime | None, om: list[dict], om_err: str | None,
            metars: dict[str, list[dict]] | None) -> dict:
    """One scan (the latest, or the one nearest `at`) classified for every cell, with the
    forecast and METAR for the same time."""
    obs_keys = g.find_scan(at)
    scan = g.load_scan(obs_keys, (SF_BOX[0] - 0.12, STATIONS["KSFO"][1] - 0.2, SF_BOX[2], STATIONS["KOAK"][1] + 0.05))
    end = g.scan_end(obs_keys["acm"][0])
    elevation = g.sun_elevation(37.76, -122.44, end)
    goes = g.classify(scan, cells, elevation)
    uploaded = max(datetime.fromisoformat(m.replace("Z", "+00:00")) for _, m in obs_keys.values())
    rows = []
    for i, c in enumerate(goes):
        row = {"lat": c.lat, "lon": c.lon,
               "goes": {"cls": c.cls, "beam": c.beam, "cloudy": c.cloudy, "top_m": c.top_m,
                        "phase": c.phase, "cod": c.cod}}
        if i < len(om):
            row["om"] = om_at(om[i], end.timestamp(), elevation)
        rows.append(row)
    if metars is None:
        metar_rows = {s: metar(s) for s in STATIONS}
    else:
        metar_rows = {s: nearest_metar(metars[s], end) for s in STATIONS}
    return {
        "logged": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "scan_end": end.isoformat(), "available": uploaded.isoformat(),
        "latency_s": round((uploaded - end).total_seconds()),
        "sun_elevation": round(elevation, 2), "om_error": om_err,
        "metar": metar_rows,
        "stations": {s: list(next(c for c in cells if abs(c[0] - p[0]) < 0.0113 and abs(c[1] - p[1]) < 0.015))
                     for s, p in STATIONS.items()},
        "cells": rows,
    }


def run(dry_run: bool = False, since_hours: float | None = None, log_dir: Path = LOG_DIR) -> list[dict]:
    cells = log_cells()
    now = datetime.now(timezone.utc)
    try:
        om = open_meteo(cells, time.time())
        om_err = None
    except Exception as e:
        om, om_err = [], str(e)[:200]
    if since_hours:
        times = quarter_hours(since_hours, now)
        metars = {s: metar_history(s, now - timedelta(hours=since_hours + 1), now) for s in STATIONS}
    else:
        times, metars = [None], None
    records = []
    for t in times:
        try:
            record = observe(cells, t, om, om_err, metars)
        except Exception as e:
            print(f"{t}: no scan ({str(e)[:120]})")
            continue
        day = record["scan_end"][:10]
        if not dry_run and record["scan_end"] in logged_scan_ends(log_dir, day):
            print(f"{record['scan_end']} already logged")
            continue
        records.append(record)
        if dry_run:
            print(json.dumps(record, indent=1)[:1500])
            continue
        log_dir.mkdir(parents=True, exist_ok=True)
        with open(log_dir / f"{day}.jsonl", "a") as f:
            f.write(json.dumps(record, separators=(",", ":")) + "\n")
        print(f"{record['scan_end'][:16]}Z latency {record['latency_s']} s, {len(record['cells'])} cells, "
              f"SFO {metar_sunny(record['metar']['KSFO'])}, OM {'ok' if not om_err else om_err}")
    g.prune_cache(keep_hours=1)
    return records


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--since-hours", type=float, help="log every quarter-hour scan of the past N hours")
    ap.add_argument("--log-dir", type=Path, default=LOG_DIR)
    a = ap.parse_args()
    run(a.dry_run, a.since_hours, a.log_dir)
