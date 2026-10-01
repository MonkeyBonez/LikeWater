#!/usr/bin/env python
"""Build the places in metros.yaml that aren't built yet (PLAN.md §2 F).

    .venv/bin/python build_places.py --dry-run           # what would be built
    .venv/bin/python build_places.py --only portland     # one place (rebuilds if built)
    .venv/bin/python build_places.py --max-minutes 120   # stop starting builds after 2 h
    .venv/bin/python build_places.py --publish           # then run publish.py --target pages

For each entry: download the Geofabrik extract into cache/pbf/ if missing (resumable
curl), run build_metro.py under /usr/bin/time -l, append minutes / peak RAM / sizes /
synthesis share to cache/build_log.jsonl. Sequential (each build peaks at 2–5 GB RAM).
A failure is logged and the next entry still runs; the failed one is retried next time
because it never reached the manifest.
"""
import argparse, json, re, subprocess, sys, time
from datetime import datetime, timezone
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
SERVER = HERE.parent / "Server"
PBF = HERE / "cache" / "pbf"
LOGS = HERE / "cache" / "build_logs"
BUILD_LOG = HERE / "cache" / "build_log.jsonl"
GEOFABRIK = "https://download.geofabrik.de"


def load_places(path=HERE / "metros.yaml"):
    return yaml.safe_load(open(path))["metros"]


def built_ids(server=SERVER):
    m = server / "manifest.json"
    return {e["id"] for e in json.load(open(m)).get("metros", [])} if m.exists() else set()


def extract_path(entry) -> Path:
    return PBF / (entry["extract"].rsplit("/", 1)[1] + ".osm.pbf")


def newest_dated_url(extract: str) -> str:
    """The newest dated snapshot (<name>-YYMMDD.osm.pbf) listed on the region's page.
    Preferred over -latest: reproducible, and on 2026-10-01 Geofabrik's proxy served the
    -latest aliases as an endless 301 to themselves while dated files answered 200."""
    import urllib.request
    name = extract.rsplit("/", 1)[1]
    try:
        html = urllib.request.urlopen(f"{GEOFABRIK}/{extract}.html", timeout=30).read().decode()
        dated = sorted(set(re.findall(rf'href="({re.escape(name)}-(\d{{6}})\.osm\.pbf)"', html)), key=lambda m: m[1])
        if dated:
            return f"{GEOFABRIK}/{extract.rsplit('/', 1)[0]}/{dated[-1][0]}"
    except Exception:
        pass
    return f"{GEOFABRIK}/{extract}-latest.osm.pbf"


def download(entry, log=print) -> Path:
    path = extract_path(entry)
    if path.exists():
        return path
    PBF.mkdir(parents=True, exist_ok=True)
    url = newest_dated_url(entry["extract"])
    part = path.with_suffix(".part")
    log(f"  downloading {url}")
    subprocess.run(["curl", "-fsSL", "--retry", "5", "--max-redirs", "5", "-C", "-", "-o", str(part), url], check=True)
    part.rename(path)
    return path


def build_args(entry, pbf: Path) -> list[str]:
    args = ["--id", entry["id"], "--name", entry["name"], "--pbf", str(pbf)]
    for p in entry["places"]:
        args += ["--place", p]
    if entry.get("survey"):
        args += ["--survey", entry["survey"]]
    if entry.get("demo"):
        args += ["--demo", str(entry["demo"]).replace(" ", "")]
    if entry.get("min_component"):
        args += ["--min-component", str(entry["min_component"])]
    return args


def peak_rss_gb(log_text: str):
    m = re.search(r"(\d+)\s+maximum resident set size", log_text)
    return round(int(m.group(1)) / 1e9, 2) if m else None


def build(entry, log=print) -> dict:
    t0 = time.time()
    record = {"id": entry["id"], "started": datetime.now(timezone.utc).isoformat(timespec="seconds")}
    try:
        pbf = download(entry, log)
        LOGS.mkdir(parents=True, exist_ok=True)
        log_path = LOGS / f"{entry['id']}.log"
        cmd = ["/usr/bin/time", "-l", sys.executable, str(HERE / "build_metro.py")] + build_args(entry, pbf)
        log(f"  {' '.join(cmd[3:])}")
        with open(log_path, "w") as f:
            rc = subprocess.run(cmd, cwd=HERE, stdout=f, stderr=subprocess.STDOUT).returncode
        text = log_path.read_text()
        record.update(ok=rc == 0, returncode=rc, peak_ram_gb=peak_rss_gb(text), log=str(log_path))
        index = SERVER / entry["id"] / "metro.json"
        if rc == 0 and index.exists():
            m = json.load(open(index))
            st = m.get("stats", {})
            record.update(built=m["built"], tiles=len(m["tiles"]), mb=st.get("total_mb"),
                          nodes=st.get("nodes"), edges=st.get("edges"), buildings=st.get("buildings"),
                          tile_mb_max=st.get("tile_mb_max"), synthesis=st.get("synthesis"))
        else:
            record["tail"] = text[-1500:]
    except Exception as e:
        record.update(ok=False, error=str(e)[:500])
    record["minutes"] = round((time.time() - t0) / 60, 1)
    BUILD_LOG.parent.mkdir(parents=True, exist_ok=True)
    with open(BUILD_LOG, "a") as f:
        f.write(json.dumps(record) + "\n")
    return record


def pending(places, built, only=None):
    if only:
        return [p for p in places if p["id"] in only]
    return [p for p in places if p["id"] not in built]


def server_limits(server=SERVER):
    """Cloudflare Pages free tier: 20,000 files per deploy, 25 MiB per file."""
    files = [p for p in server.rglob("*") if p.is_file() or p.is_symlink()]
    biggest = max((p.resolve().stat().st_size for p in files), default=0)
    total = sum(p.resolve().stat().st_size for p in files)
    return {"files": len(files), "largest_mib": round(biggest / 2**20, 1),
            "total_gb": round(total / 1e9, 2),
            "fits_pages": len(files) < 20_000 and biggest < 25 * 2**20}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", action="append", help="build (or rebuild) just these ids")
    ap.add_argument("--max-minutes", type=float, default=None, help="don't start a build after this budget")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--publish", action="store_true", help="run publish.py --target pages afterwards")
    a = ap.parse_args(argv)

    places = load_places()
    todo = pending(places, built_ids(), set(a.only) if a.only else None)
    if a.only and len(todo) != len(set(a.only)):
        sys.exit(f"unknown id in --only: {sorted(set(a.only) - {p['id'] for p in todo})}")
    print(f"{len(todo)} to build: {', '.join(p['id'] for p in todo) or 'nothing'}")
    if a.dry_run:
        for p in todo:
            have = "cached" if extract_path(p).exists() else "download"
            print(f"  {p['id']:14s} {p['extract']} ({have})  build_metro.py {' '.join(build_args(p, extract_path(p)))}")
        print("Server/:", server_limits())
        return 0
    t0 = time.time(); failures = 0
    for p in todo:
        if a.max_minutes is not None and (time.time() - t0) / 60 > a.max_minutes:
            print(f"budget of {a.max_minutes} min spent; stopping before {p['id']}"); break
        print(f"== {p['id']}")
        r = build(p)
        failures += not r["ok"]
        print(f"   {'ok' if r['ok'] else 'FAILED'} in {r['minutes']} min"
              + (f", {r.get('tiles')} tiles, {r.get('mb')} MB, peak {r.get('peak_ram_gb')} GB" if r["ok"] else f": {r.get('error') or r.get('log')}"))
    subprocess.run([sys.executable, str(HERE / "sync_server.py")], check=True)
    print("Server/:", server_limits())
    if a.publish:
        subprocess.run([sys.executable, str(HERE / "publish.py"), "--target", "pages"], check=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
