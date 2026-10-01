#!/usr/bin/env python
"""Publish Server/ to a static host (PLAN.md §2 D). The owner runs this; an agent never does.

    .venv/bin/python publish.py --dry-run                 # stage, check limits, print what would happen
    .venv/bin/python publish.py --target pages            # Cloudflare Pages (free, <project>.pages.dev)
    .venv/bin/python publish.py --target s3               # any S3-compatible bucket (R2, AWS)
    .venv/bin/python publish.py --pull https://likewater-tiles.pages.dev/   # mirror the live site into Server/ (CI)

Pages: stages build/publish/ (hard links into Server/, no copies), drops any file over
Pages' 25 MiB limit together with its manifest entry (today: sanfrancisco.lwbundle, which
also ships inside the apps), writes a `_headers` file (manifest and metro indexes cache 5
minutes; tiles are immutable per build), checks the 20,000-file limit, then runs
`npx wrangler pages deploy build/publish --project-name $LW_PAGES_PROJECT`. Credentials
come from the environment (CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID, or `wrangler
login` on the owner's Mac); nothing is stored here.

S3: uploads under metros/<id>/<buildKey>/… (a rebuild never overwrites tiles a phone may be
using), singles at the root, explicit Cache-Control, and the manifest last, pointing each
metro at its build directory. Needs boto3 and S3_BUCKET (+ S3_ENDPOINT_URL for R2,
AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY).
"""
import argparse, json, os, shutil, subprocess, sys, urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SERVER = ROOT / "Server"
STAGE = ROOT / "build" / "publish"
PAGES_MAX_FILE = 25 * 2**20
PAGES_MAX_FILES = 20_000
INDEX_TTL = 300

HEADERS = f"""/manifest.json
  Cache-Control: public, max-age={INDEX_TTL}
/*/metro.json
  Cache-Control: public, max-age={INDEX_TTL}
/*.lwbundle
  Cache-Control: public, max-age=86400
/*/*.lwbundle
  Cache-Control: public, max-age=31536000, immutable
"""


def build_key(built):
    if not built:
        return "legacy"
    digits = "".join(c for c in built[:19] if c.isdigit())
    return digits or "legacy"


def stage(server=SERVER, out=STAGE, log=print):
    """Pages layout: Server/ as is, minus oversize files and their manifest entries."""
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    manifest = json.load(open(server / "manifest.json"))
    dropped = []
    for city in list(manifest.get("cities", [])):
        f = (server / city["file"]).resolve()
        if not f.exists() or f.stat().st_size >= PAGES_MAX_FILE:
            dropped.append(city["file"])
            manifest["cities"].remove(city)
    files = 0
    for src in sorted(server.rglob("*")):
        rel = src.relative_to(server)
        if src.is_dir() or rel.name == "manifest.json" or rel.parts[0] in ("worker",) or rel.name.startswith("."):
            continue
        real = src.resolve()
        if str(rel) in dropped or real.stat().st_size >= PAGES_MAX_FILE:
            if str(rel) not in dropped:
                dropped.append(str(rel))
            continue
        dest = out / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        try:
            os.link(real, dest)
        except OSError:
            shutil.copy2(real, dest)
        files += 1
    json.dump(manifest, open(out / "manifest.json", "w"), indent=1)
    (out / "_headers").write_text(HEADERS)
    files += 2
    total = sum(p.stat().st_size for p in out.rglob("*") if p.is_file())
    report = {"files": files, "total_mb": round(total / 1e6, 1), "dropped": dropped,
              "largest_mib": round(max(p.stat().st_size for p in out.rglob("*") if p.is_file()) / 2**20, 1),
              "metros": [m["id"] for m in manifest.get("metros", [])],
              "cities": [c["file"] for c in manifest.get("cities", [])]}
    report["fits_pages"] = files < PAGES_MAX_FILES and report["largest_mib"] < 25
    for d in dropped:
        log(f"  left out (over 25 MiB): {d}")
    return report


def s3_plan(server=SERVER):
    """(local path, key, cache-control) for every upload, manifest last."""
    manifest = json.load(open(server / "manifest.json"))
    uploads = []
    for city in manifest.get("cities", []):
        uploads.append((server / city["file"], city["file"], "public, max-age=86400"))
    for m in manifest.get("metros", []):
        index = json.load(open(server / m["index"]))
        prefix = f"metros/{m['id']}/{build_key(index.get('built'))}"
        for f in [t["file"] for t in index["tiles"]] + ([index["far"]["file"]] if index.get("far") else []):
            uploads.append((server / m["id"] / f, f"{prefix}/{f}", "public, max-age=31536000, immutable"))
        uploads.append((server / m["index"], f"{prefix}/metro.json", f"public, max-age={INDEX_TTL}"))
        m["index"] = f"{prefix}/metro.json"
    return uploads, manifest


def publish_pages(dry_run):
    report = stage()
    print(json.dumps(report, indent=1))
    if not report["fits_pages"]:
        sys.exit("staged site is over Cloudflare Pages' free limits")
    project = os.environ.get("LW_PAGES_PROJECT", "likewater-tiles")
    cmd = ["npx", "--yes", "wrangler@4", "pages", "deploy", str(STAGE), "--project-name", project,
           "--branch", "main", "--commit-dirty=true"]
    print("would run:" if dry_run else "running:", " ".join(cmd))
    if dry_run:
        return
    env = {k: v for k, v in os.environ.items() if k != "NODE_OPTIONS"}
    subprocess.run(cmd, check=True, env=env)


def publish_s3(dry_run, local_dir=None):
    uploads, manifest = s3_plan()
    if local_dir:
        # The S3 layout written to a folder, to serve and test the apps against it.
        out = Path(local_dir); shutil.rmtree(out, ignore_errors=True)
        for path, key, _ in uploads:
            (out / key).parent.mkdir(parents=True, exist_ok=True)
            os.link(path.resolve(), out / key)
        (out / "manifest.json").write_text(json.dumps(manifest, indent=1))
        print(f"wrote the S3 layout to {out}")
        return
    bucket = os.environ.get("S3_BUCKET")
    print(f"{len(uploads)} uploads + manifest to {bucket or '<S3_BUCKET unset>'}")
    if dry_run:
        for path, key, cc in uploads[:5]:
            print(f"  {key}  ({cc})")
        return
    if not bucket:
        sys.exit("set S3_BUCKET (and S3_ENDPOINT_URL for R2)")
    import boto3
    s3 = boto3.client("s3", endpoint_url=os.environ.get("S3_ENDPOINT_URL"))
    for path, key, cc in uploads:
        s3.upload_file(str(path.resolve()), bucket, key, ExtraArgs={"CacheControl": cc})
    s3.put_object(Bucket=bucket, Key="manifest.json", Body=json.dumps(manifest).encode(),
                  CacheControl=f"public, max-age={INDEX_TTL}", ContentType="application/json")


def pull(base: str, server=SERVER):
    """Mirror a published site into Server/ (what CI needs before deploying a new place,
    because a Pages deploy replaces the whole site)."""
    base = base.rstrip("/") + "/"
    get = lambda rel: urllib.request.urlopen(base + rel, timeout=120).read()
    server.mkdir(exist_ok=True)
    manifest = json.loads(get("manifest.json"))
    (server / "manifest.json").write_bytes(json.dumps(manifest, indent=2).encode())
    wanted = [c["file"] for c in manifest.get("cities", [])]
    for m in manifest.get("metros", []):
        index_raw = get(m["index"])
        index = json.loads(index_raw)
        d = server / m["id"]; d.mkdir(parents=True, exist_ok=True)
        (d / "metro.json").write_bytes(index_raw)
        folder = m["index"].rsplit("/", 1)[0]
        wanted += [f"{folder}/{t['file']}" for t in index["tiles"]]
        if index.get("far"):
            wanted.append(f"{folder}/{index['far']['file']}")
    got = 0
    for rel in wanted:
        dest = server / rel
        if dest.exists():
            continue
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(get(rel)); got += 1
    print(f"pulled {got} files ({len(wanted) - got} already here) from {base}")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--target", choices=["pages", "s3"], default="pages")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--pull", metavar="URL")
    ap.add_argument("--local-dir", help="with --target s3: write the bucket layout to this folder instead")
    a = ap.parse_args(argv)
    if a.pull:
        return pull(a.pull)
    if a.target == "pages":
        publish_pages(a.dry_run)
    else:
        publish_s3(a.dry_run, a.local_dir)


if __name__ == "__main__":
    main()
