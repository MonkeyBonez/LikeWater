#!/usr/bin/env python
"""Serves Server/ as if one metro had been rebuilt, to test build pinning in the apps
(PLAN.md §2 C5). Not part of the pipeline; used by SunMap's BuildPinningUITests.

    python fake_rebuild_server.py --metro seattle --port 8766            # newer build, tiles present
    python fake_rebuild_server.py --metro seattle --port 8767 --broken   # newer build, tiles 404

Writes build/rebuild-server-<port>/: every file of Server/ symlinked, except the
manifest and <metro>/metro.json, whose `built` is moved one day later. With --broken the
metro's tiles are left out, as if the new build hadn't finished uploading.
"""
import argparse, datetime, functools, http.server, json, os, shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SERVER = ROOT / "Server"


def make(metro: str, port: int, broken: bool) -> Path:
    out = ROOT / "build" / f"rebuild-server-{port}"
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    for item in SERVER.iterdir():
        if item.name in ("manifest.json", metro):
            continue
        os.symlink(item.resolve(), out / item.name)
    index = json.load(open(SERVER / metro / "metro.json"))
    newer = (datetime.datetime.fromisoformat(index["built"]) + datetime.timedelta(days=1)).isoformat()
    index["built"] = newer
    (out / metro).mkdir()
    json.dump(index, open(out / metro / "metro.json", "w"))
    if not broken:
        for f in (SERVER / metro).iterdir():
            if f.suffix == ".lwbundle":
                os.symlink(f.resolve(), out / metro / f.name)
    manifest = json.load(open(SERVER / "manifest.json"))
    for m in manifest["metros"]:
        if m["id"] == metro:
            m["built"] = newer
    json.dump(manifest, open(out / "manifest.json", "w"), indent=1)
    return out


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--metro", default="seattle")
    ap.add_argument("--port", type=int, default=8766)
    ap.add_argument("--broken", action="store_true")
    a = ap.parse_args()
    d = make(a.metro, a.port, a.broken)
    print(f"serving {d} on :{a.port}")
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(d))
    http.server.ThreadingHTTPServer(("127.0.0.1", a.port), handler).serve_forever()
