#!/bin/sh
# Build the three tiled metros into ../Server (what a bundle server serves).
# Needs the Geofabrik extracts in cache/pbf/ and the surveys in data/ (see README).
set -e
cd "$(dirname "$0")"
PY=.venv/bin/python
LOG=${LOG:-/tmp}
run() { id=$1; shift; echo "== $id"; /usr/bin/time -l $PY build_metro.py --id "$id" "$@" > "$LOG/metro_$id.log" 2>&1; grep -E "keeping|wrote|maximum resident" "$LOG/metro_$id.log"; }
[ -z "$1" -o "$1" = seattle ] && run seattle --name Seattle --pbf cache/pbf/washington.osm.pbf \
  --place "Seattle, Washington, USA" --survey seattle --demo 47.6097,-122.3422
[ -z "$1" -o "$1" = nyc ] && run nyc --name "New York" --pbf cache/pbf/new-york.osm.pbf \
  --place "New York City, New York, USA" --survey nyc --demo 40.7536,-73.9832
[ -z "$1" -o "$1" = la ] && run la --name "Los Angeles" --pbf cache/pbf/socal.osm.pbf \
  --place "Los Angeles, California, USA" --place "Beverly Hills, California, USA" \
  --place "West Hollywood, California, USA" --place "Santa Monica, California, USA" \
  --place "Culver City, California, USA" --demo 34.0505,-118.2551

python3 "$(dirname "$0")/sync_server.py"
exit 0
