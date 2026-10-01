#!/usr/bin/env python
"""Make Server/ the one directory a bundle server serves: the tiled metros that
build_metro.py wrote there, plus the single-city bundles that ship in Resources/
(linked, not copied) with their manifest entries merged in."""
import json, os
from pathlib import Path

root = Path(__file__).resolve().parent.parent
server, resources = root / "Server", root / "Resources"
server.mkdir(exist_ok=True)
manifest_path = server / "manifest.json"
manifest = json.load(open(manifest_path)) if manifest_path.exists() else {"cities": [], "metros": []}
shipped = json.load(open(resources / "manifest.json"))
for city in shipped["cities"]:
    link = server / city["file"]
    if link.is_symlink() or link.exists():
        link.unlink()
    os.symlink(os.path.relpath(resources / city["file"], server), link)
manifest["cities"] = shipped["cities"]
# Every metro entry carries its build time (the app's buildKey); backfill from the index.
for m in manifest.get("metros", []):
    index = server / m["index"]
    if "built" not in m and index.exists():
        m["built"] = json.load(open(index))["built"]
json.dump(manifest, open(manifest_path, "w"), indent=2)
print(f"{len(manifest['cities'])} cities, {len(manifest.get('metros', []))} metros in {manifest_path}")
