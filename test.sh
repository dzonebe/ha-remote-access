#!/usr/bin/env bash
# Builds the image, starts it with sample options and checks that it creates its
# own token, that every generated frpc config is valid and that bad input is
# rejected. Enrollment is pointed at a dead address so no real request is made.
set -euo pipefail
cd "$(dirname "$0")"
export MSYS_NO_PATHCONV=1 # Git Bash on Windows: leave container paths alone

IMG=dzone-tunnel-test
docker build -q -t "$IMG" dzone_tunnel >/dev/null

# run_app <subdomain> [docker run flags...]: starts the app as Supervisor would.
run_app() {
  local subdomain=$1; shift
  docker run "$@" --rm --entrypoint sh -e ENROLL_URL=http://127.0.0.1:9/ \
    -e OPTS="{\"subdomain\":\"$subdomain\",\"servers\":[\"t1.example.test\",\"t2.example.test\"]}" \
    "$IMG" -c 'mkdir -p /data && printf %s "$OPTS" > /data/options.json && exec /init /run.sh'
}

id=$(run_app klant1 -d)
trap 'docker rm -f "$id" >/dev/null 2>&1' EXIT
sleep 5
docker exec "$id" grep -Eqx '[a-f0-9]{64}' /data/token || { echo "FAIL: no token was generated"; exit 1; }
n=$(docker exec "$id" sh -c 'for f in /tmp/frpc-*.toml; do frpc verify -c "$f" >&2 || exit 1; echo; done | wc -l')
[ "$n" -eq 2 ] || { echo "FAIL: expected 2 valid configs, got $n"; exit 1; }

# A subdomain that could break out of the TOML string must stop the app.
out=$(run_app 'x\"\nserverAddr = \"evil' 2>&1 || true)
grep -q "Invalid subdomain" <<<"$out" || { echo "FAIL: invalid subdomain was not rejected"; echo "$out"; exit 1; }
echo "OK"
