#!/bin/sh
# Smoke test for the Worker running under `npx wrangler dev --local --port 8787` with
# .dev.vars from .dev.vars.example. Exits non-zero on the first failed check.
set -e
U=${WORKER_URL:-http://127.0.0.1:8787}
fail() { echo "FAIL: $*"; exit 1; }
check() { echo "$2" | grep -q "$3" || fail "$1: got $2"; echo "ok  $1"; }

check health "$(curl -s $U/health)" '"ok":true'
# Fresh cells every run: the Worker counts one request per IP per cell per day.
R=$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')
CELL="$((30 + R % 15)).$((R % 10)),-$((90 + R % 30)).$((R / 10 % 10))"
CELL2="$((30 + (R + 7) % 15)).$(((R + 3) % 10)),-$((90 + (R + 11) % 30)).$(((R / 7) % 10))"
check "first request counts" "$(curl -s -X POST $U/coverage-request -d "{\"cell\":\"$CELL\"}")" '"counted":true'
check "same IP same day is not counted twice" "$(curl -s -X POST $U/coverage-request -d "{\"cell\":\"$CELL\"}")" '"counted":false'
check "bad cell is refused" "$(curl -s -w ' %{http_code}' -X POST $U/coverage-request -d '{"cell":"portland"}')" ' 400'
check "outside the USA is flagged" "$(curl -s -X POST $U/coverage-request -d '{"cell":"51.5,-0.1"}')" '"usa":false'
check "auto-build is off by default" "$(curl -s -X POST $U/coverage-request -d "{\"cell\":\"$CELL2\"}")" '"autoBuild":"off"'
check "export needs the token" "$(curl -s -w ' %{http_code}' $U/coverage-requests)" ' 401'
check "export lists the cell" "$(curl -s -H 'authorization: Bearer local-export-token' $U/coverage-requests)" "\"$CELL\":1"
check "weather proxy is off" "$(curl -s -w ' %{http_code}' "$U/sky?latitude=37.77&longitude=-122.42")" ' 404'
echo "all Worker checks passed"
