#!/usr/bin/env python
"""Turn "Request this area" counts into review-ready metros.yaml entries (PLAN.md §2 F).

    .venv/bin/python requests_to_places.py requests.json [--min-requests 3] [--out proposals.yaml]

Input: JSON {"cells": {"45.5,-122.7": 12, ...}} — the coverage-request Worker's KV export
(Server/worker, `GET /coverage-requests`), or the same shape assembled by hand from the
apps' debug log. Cells are 0.1° (what the app sends). Each cell with enough requests is
reverse-geocoded (Nominatim, cached, 1 request/s per its usage policy) to a city and its
state, mapped to the state's Geofabrik extract, and merged per city. Places already in
metros.yaml are skipped. Nothing is appended automatically: the owner reviews the output
and copies entries into metros.yaml (USA only for now; other countries are reported and
skipped).
"""
import argparse, json, re, sys, time
from pathlib import Path

import requests
import yaml

HERE = Path(__file__).resolve().parent
CACHE = HERE / "cache" / "nominatim_reverse.json"
USER_AGENT = "LikeWater pipeline (github.com/MonkeyBonez/LikeWater)"

# Geofabrik splits two states; everything else is north-america/us/<slug>.
SPLIT = {"California": lambda lat, lon: "north-america/us/california/" + ("socal" if lat < 35.8 else "norcal")}


def state_extract(state: str, lat: float, lon: float) -> str:
    if state in SPLIT:
        return SPLIT[state](lat, lon)
    return "north-america/us/" + re.sub(r"[^a-z]+", "-", state.lower()).strip("-")


def slug(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", name.lower())


def reverse(lat: float, lon: float, cache: dict, session=requests) -> dict:
    key = f"{lat:.1f},{lon:.1f}"
    if key not in cache:
        r = session.get("https://nominatim.openstreetmap.org/reverse",
                        params={"lat": lat, "lon": lon, "zoom": 10, "format": "jsonv2"},
                        headers={"User-Agent": USER_AGENT}, timeout=30)
        r.raise_for_status()
        cache[key] = r.json().get("address", {})
        time.sleep(1.1)
    return cache[key]


def proposals(cells: dict, known_ids: set, min_requests: int, geocode) -> tuple[list, list]:
    by_place, skipped = {}, []
    for key, count in sorted(cells.items(), key=lambda kv: -kv[1]):
        if count < min_requests:
            continue
        lat, lon = (float(v) for v in key.split(","))
        a = geocode(lat, lon)
        if a.get("country_code") != "us":
            skipped.append((key, count, a.get("country", "unknown"), "outside the USA")); continue
        city = a.get("city") or a.get("town") or a.get("village") or a.get("county")
        state = a.get("state")
        if not city or not state:
            skipped.append((key, count, str(a)[:80], "no city/state")); continue
        pid = slug(city)
        if pid in known_ids:
            skipped.append((key, count, city, "already in metros.yaml")); continue
        p = by_place.setdefault(pid, {"id": pid, "name": city, "extract": state_extract(state, lat, lon),
                                      "places": [f"{city}, {state}, USA"], "demo": f"{lat:.4f},{lon:.4f}",
                                      "requests": 0})
        p["requests"] += count
    return sorted(by_place.values(), key=lambda p: -p["requests"]), skipped


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("requests", type=Path)
    ap.add_argument("--min-requests", type=int, default=3)
    ap.add_argument("--out", type=Path)
    a = ap.parse_args(argv)
    cells = json.load(open(a.requests))["cells"]
    known = {m["id"] for m in yaml.safe_load(open(HERE / "metros.yaml"))["metros"]}
    cache = json.load(open(CACHE)) if CACHE.exists() else {}
    try:
        props, skipped = proposals(cells, known, a.min_requests, lambda la, lo: reverse(la, lo, cache))
    finally:
        CACHE.parent.mkdir(parents=True, exist_ok=True)
        json.dump(cache, open(CACHE, "w"), indent=1)
    text = "# Proposed by requests_to_places.py — review, then copy into metros.yaml\n" + \
        yaml.safe_dump({"metros": props}, sort_keys=False, allow_unicode=True)
    (a.out.write_text(text) if a.out else sys.stdout.write(text))
    for s in skipped:
        print(f"skipped {s[0]} ({s[1]} requests): {s[2]} — {s[3]}", file=sys.stderr)


if __name__ == "__main__":
    main()
