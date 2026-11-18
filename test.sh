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
# --- configuration.yaml handling ---------------------------------------------
# scenario <name> <initial configuration.yaml> <check_config result> [extra option]
# Starts the app with a config folder and a stand-in for the Home Assistant API
# (it answers every call with the given result and records the calls).
ORIGINAL='default_config:
automation: !include automations.yaml
'
scenario() {
  docker rm -f "dzt-conf-$1" >/dev/null 2>&1 || true
  docker run -d --name "dzt-conf-$1" --entrypoint sh -e ENROLL_URL=http://127.0.0.1:9/ \
    -e CORE_API=http://127.0.0.1:8099 -e CONF="$2" -e API="{\"result\":\"$3\"}" \
    -e OPTS="{\"subdomain\":\"klant1\",\"servers\":[\"t1.example.test\"]${4:-}}" "$IMG" -c '
      mkdir -p /data /homeassistant
      printf %s "$OPTS" > /data/options.json
      [ -f /homeassistant/configuration.yaml ] || printf %s "$CONF" > /homeassistant/configuration.yaml
      ( while true; do
          printf "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s" "${#API}" "$API" \
            | nc -l -p 8099 >> /tmp/requests 2>/dev/null
        done ) &
      exec /init /run.sh' >/dev/null
  sleep 7
}
conf() { docker exec "dzt-conf-$1" cat /homeassistant/configuration.yaml; }
calls() { docker exec "dzt-conf-$1" sh -c "grep -ac '$2' /tmp/requests 2>/dev/null || true"; }
check() { if eval "$2"; then :; else echo "FAIL: $1"; exit 1; fi; }
trap 'docker rm -f "$id" dzt-conf-add dzt-conf-http dzt-conf-invalid dzt-conf-off >/dev/null 2>&1' EXIT

scenario add "$ORIGINAL" valid
check "proxy settings were not added" '[ "$(conf add | grep -c "Added by DZone Remote Access")" -eq 1 ] && conf add | grep -q "172.30.33.0/24"'
check "original content was not kept" 'conf add | grep -q "automation: !include automations.yaml"'
check "no backup was made" '[ "$(docker exec dzt-conf-add cat /homeassistant/configuration.yaml.dzone-backup)" = "$(printf %s "$ORIGINAL")" ]'
check "Home Assistant was not restarted exactly once" '[ "$(calls add services/homeassistant/restart)" -eq 1 ]'
docker restart dzt-conf-add >/dev/null; sleep 7
check "settings were added twice" '[ "$(conf add | grep -c "^http:")" -eq 1 ]'
check "Home Assistant was restarted again" '[ "$(calls add services/homeassistant/restart)" -eq 1 ]'

WITH_HTTP='default_config:
http:
  ssl_certificate: /ssl/fullchain.pem
'
scenario http "$WITH_HTTP" valid
check "an existing http: section was modified" '[ "$(conf http)" = "$(printf %s "$WITH_HTTP")" ] && [ "$(calls http POST)" -eq 0 ]'
check "no manual instruction was logged" 'docker logs dzt-conf-http 2>&1 | grep -q "already has an http: section"'

scenario invalid "$ORIGINAL" invalid
check "a rejected change was not rolled back" '[ "$(conf invalid)" = "$(printf %s "$ORIGINAL")" ]'
check "Home Assistant was restarted after a rejected change" '[ "$(calls invalid services/homeassistant/restart)" -eq 0 ]'

scenario off "$ORIGINAL" valid ',"configure_home_assistant":false'
check "the opt-out was ignored" '[ "$(conf off)" = "$(printf %s "$ORIGINAL")" ] && [ "$(calls off POST)" -eq 0 ]'

echo "OK"
