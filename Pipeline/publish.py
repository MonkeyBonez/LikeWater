#!/usr/bin/env python
"""Publish Server/ to a static host (PLAN.md §2 D). The owner runs this; an agent never does.

    .venv/bin/python publish.py --dry-run                 # stage, check limits, print what would happen
    .venv/bin/python publish.py --target pages            # Cloudflare Pages (free, <project>.pages.dev)
    .venv/bin/python publish.py --target s3               # any S3-compatible bucket (R2, AWS)
    .venv/bin/python publish.py --pull https://likewater-tiles.pages.dev/   # mirror the live site into Server/ (CI)

Both targets use the same layout: metros under metros/<id>/<buildKey>/… (a rebuild gets
new paths, so an HTTP cache — the phone's, a proxy's, the CDN's — can never hand a phone an
old tile under a new build's name), singles at the root, and the manifest last, pointing
each metro at its build directory.

Pages: stages build/publish/ (hard links into Server/, no copies), drops any file over
Pages' 25 MiB limit together with its manifest entry (today: sanfrancisco.lwbundle, which
also ships inside the apps), writes a `_headers` file (manifest and metro indexes cache 5
minutes, build-keyed tiles a year), checks the 20,000-file limit, refuses to publish a site
that lists fewer metros than the live one (set LW_BUNDLE_BASE_URL to compare; a partial
pull must never replace the real site), then runs `npx wrangler pages deploy build/publish
--project-name $LW_PAGES_PROJECT`. Credentials come from the environment
(CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID, or `wrangler login` on the owner's Mac);
nothing is stored here.

S3: the same uploads with explicit Cache-Control. Needs boto3 and S3_BUCKET
(+ S3_ENDPOINT_URL for R2, AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY).
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
/metros/*/*/metro.json
  Cache-Control: public, max-age={INDEX_TTL}
/*.lwbundle
  Cache-Control: public, max-age=86400
/metros/*/*/*.lwbundle
  Cache-Control: public, max-age=31536000, immutable
"""


def build_key(built):
    if not built:
        return "legacy"
    digits = "".join(c for c in built[:19] if c.isdigit())
    return digits or "legacy"


def stage(server=SERVER, out=STAGE, log=print):
    """Pages layout: the build-keyed uploads of `s3_plan`, minus oversize files and their
    manifest entries, as hard links under `out`."""
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    uploads, manifest = s3_plan(server)
    dropped = []
    for city in list(manifest.get("cities", [])):
        f = (server / city["file"]).resolve()
        if not f.exists() or f.stat().st_size >= PAGES_MAX_FILE:
            dropped.append(city["file"])
            manifest["cities"].remove(city)
    files = 0
    for path, key, _ in uploads:
        real = path.resolve()
        if key in dropped:
            continue
        if real.stat().st_size >= PAGES_MAX_FILE:
            dropped.append(key)
            continue
        dest = out / key
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


def live_metros(base: str) -> set | None:
    """Metro ids the live site lists; None when there is no site yet (404) — any other
    failure raises, because "unknown" must not be read as "empty"."""
    import urllib.error
    try:
        data = urllib.request.urlopen(base.rstrip("/") + "/manifest.json", timeout=60).read()
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise
    return {m["id"] for m in json.loads(data).get("metros", [])}


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
    base = os.environ.get("LW_BUNDLE_BASE_URL")
    if base and not os.environ.get("LW_ALLOW_REMOVALS"):
        live = live_metros(base)
        missing = sorted((live or set()) - set(report["metros"]))
        if missing:
            sys.exit(f"refusing to publish: the live site has {missing} and this one doesn't "
                     f"(a partial pull? set LW_ALLOW_REMOVALS=1 to remove places on purpose)")
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
    """Mirror a published site into Server/'s local layout (<id>/metro.json + tiles), what
    CI needs before deploying a new place, because a Pages deploy replaces the whole site.
    Returns False when there is no site yet (404 on the manifest). Any other failure
    raises: a half-pulled Server/ must never be published over the real one, so the
    manifest is written only after every file is here."""
    import urllib.error
    base = base.rstrip("/") + "/"
    try:
        manifest = json.loads(urllib.request.urlopen(base + "manifest.json", timeout=120).read())
    except urllib.error.HTTPError as e:
        if e.code == 404:
            print("no live site yet")
            return False
        raise

    def get(rel):
        for attempt in range(3):
            try:
                return urllib.request.urlopen(base + rel, timeout=120).read()
            except (urllib.error.URLError, TimeoutError) as e:
                if attempt == 2:
                    raise
                print(f"  retrying {rel}: {str(e)[:80]}")

    server.mkdir(parents=True, exist_ok=True)
    got = 0
    wanted = [(c["file"], c["file"]) for c in manifest.get("cities", [])]
    local_manifest = {"cities": manifest.get("cities", []), "metros": []}
    for m in manifest.get("metros", []):
        index_raw = get(m["index"])
        index = json.loads(index_raw)
        d = server / m["id"]; d.mkdir(parents=True, exist_ok=True)
        (d / "metro.json").write_bytes(index_raw)
        folder = m["index"].rsplit("/", 1)[0]
        for t in index["tiles"]:
            wanted.append((f"{folder}/{t['file']}", f"{m['id']}/{t['file']}"))
        if index.get("far"):
            wanted.append((f"{folder}/{index['far']['file']}", f"{m['id']}/{index['far']['file']}"))
        local_manifest["metros"].append(dict(m, index=f"{m['id']}/metro.json"))
    for remote_rel, local_rel in wanted:
        dest = server / local_rel
        if dest.exists():
            continue
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp = dest.with_suffix(dest.suffix + ".part")
        tmp.write_bytes(get(remote_rel)); tmp.rename(dest); got += 1
    (server / "manifest.json").write_text(json.dumps(local_manifest, indent=2))
    print(f"pulled {got} files ({len(wanted) - got} already here) from {base}")
    return True


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--target", choices=["pages", "s3"], default="pages")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--pull", metavar="URL")
    ap.add_argument("--local-dir", help="with --target s3: write the bucket layout to this folder instead")
    a = ap.parse_args(argv)
    if a.pull:
        pull(a.pull)
        return
    if a.target == "pages":
        publish_pages(a.dry_run)
    else:
        publish_s3(a.dry_run, a.local_dir)


if __name__ == "__main__":
    main()
