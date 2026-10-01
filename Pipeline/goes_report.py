"""Scores the GOES fog POC log (PLAN.md §2 E) and applies the decision rule.

    .venv/bin/python goes_report.py [--days 14] [--min-days 10]

Daytime only (09:00–17:00 Pacific). Each source says "sun" when its beam ≥ 0.5:
  agreement      share of cell-times where GOES and Open-Meteo say the same thing
  disagreements  at the SFO/OAK cells, who matches the METAR (no BKN/OVC/VV layer = sun)
  latency        median minutes from scan end to the data being on the bucket
  burn-off       on mornings METAR reports fog/stratus, minutes between each source's
                 first "sun" at SFO and the METAR's first sun
Decision: build the GOES job if GOES is right in ≥ 70 % of disagreements and the median
latency ≤ 15 min (record the numbers in LEARNINGS §9.5 either way).
"""
from __future__ import annotations

import argparse
import json
import statistics
from collections import defaultdict
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

from goes_log import LOG_DIR, metar_sunny

PACIFIC = ZoneInfo("America/Los_Angeles")


def load(days: int, log_dir: Path = LOG_DIR) -> list[dict]:
    rows = []
    for p in sorted(log_dir.glob("*.jsonl"))[-days - 1:]:
        rows += [json.loads(l) for l in p.read_text().splitlines() if l.strip()]
    return rows


def sunny(beam) -> bool | None:
    return None if beam is None else beam >= 0.5


def score(records: list[dict]) -> dict:
    agree = total = 0
    dis_goes = dis_om = dis_n = 0
    latencies = []
    first_sun = defaultdict(dict)      # day → source → minutes after midnight
    days = set()
    for r in records:
        t = datetime.fromisoformat(r["scan_end"]).astimezone(PACIFIC)
        if not (9 <= t.hour < 17):
            continue
        days.add(t.date())
        latencies.append(r["latency_s"] / 60)
        for c in r["cells"]:
            gs, os_ = sunny(c["goes"]["beam"]), sunny((c.get("om") or {}).get("beam"))
            if gs is None or os_ is None:
                continue
            total += 1; agree += gs == os_
        for station, cell in r.get("stations", {}).items():
            truth = metar_sunny((r.get("metar") or {}).get(station))
            c = next((c for c in r["cells"] if [c["lat"], c["lon"]] == cell), None)
            if truth is None or c is None:
                continue
            gs, os_ = sunny(c["goes"]["beam"]), sunny((c.get("om") or {}).get("beam"))
            if gs is not None and os_ is not None and gs != os_:
                dis_n += 1; dis_goes += gs == truth; dis_om += os_ == truth
            if station == "KSFO":
                minute = t.hour * 60 + t.minute
                for name, s in (("metar", truth), ("goes", gs), ("om", os_)):
                    if s and name not in first_sun[t.date()]:
                        first_sun[t.date()][name] = minute
    fog_days = [d for d, f in first_sun.items() if f.get("metar", 0) > 9 * 60 + 30]
    burn = {src: [abs(first_sun[d][src] - first_sun[d]["metar"]) for d in fog_days if src in first_sun[d]]
            for src in ("goes", "om")}
    out = {
        "days": len(days),
        "cell_times": total,
        "agreement": agree / total if total else None,
        "station_disagreements": dis_n,
        "goes_right_share": dis_goes / dis_n if dis_n else None,
        "om_right_share": dis_om / dis_n if dis_n else None,
        "median_latency_min": statistics.median(latencies) if latencies else None,
        "fog_mornings": len(fog_days),
        "burnoff_error_min": {k: statistics.median(v) if v else None for k, v in burn.items()},
    }
    out["decision"] = (
        "insufficient data" if out["goes_right_share"] is None or out["median_latency_min"] is None
        else "build the GOES job" if out["goes_right_share"] >= 0.7 and out["median_latency_min"] <= 15
        else "do not build (forecast is good enough)")
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--days", type=int, default=14)
    ap.add_argument("--min-days", type=int, default=10)
    a = ap.parse_args(argv)
    s = score(load(a.days))
    print(json.dumps(s, indent=1, default=str))
    if s["days"] < a.min_days:
        print(f"only {s['days']} daytime days logged; the decision needs ≥ {a.min_days}")


if __name__ == "__main__":
    main()
