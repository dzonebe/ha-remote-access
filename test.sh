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
# --- Home Assistant HTTP settings ---------------------------------------------
# scenario <name> <stable config json> [extra option] [mode]
# Starts the app next to tests/fake_ha_ws.sh, a stand-in for Home Assistant's
# websocket API that keeps the HTTP config the way Home Assistant does.
DEFAULTS='"cors_allowed_origins":[],"login_attempts_threshold":-1,"ip_ban_enabled":true,"ssl_profile":"intermediate_v6","use_x_frame_options":true,"created_at":"t","error":null,"error_message":null'
scenario() {
  docker rm -f "dzt-ws-$1" >/dev/null 2>&1 || true
  docker run -d --name "dzt-ws-$1" --entrypoint sh -e ENROLL_URL=http://127.0.0.1:9/ \
    -e CORE_WS=ws://127.0.0.1:8099 -e HA_WAIT=1 -e MODE="${4:-}" -e FAKE="$(cat tests/fake_ha_ws.sh)" \
    -e STATE="{\"stable\":{$2,$DEFAULTS},\"pending\":null,\"revert_at\":null,\"active_config_type\":\"stable\",\"default\":{}}" \
    -e OPTS="{\"subdomain\":\"klant1\",\"servers\":[\"t1.example.test\"]${3:-}}" "$IMG" -c '
      mkdir -p /data
      printf %s "$OPTS" > /data/options.json
      printf %s "$STATE" > /tmp/state.json
      printf "%s\n" "$FAKE" > /tmp/fake.sh
      touch /tmp/ws_requests
      websocat -t -E ws-l:127.0.0.1:8099 cmd:"bash /tmp/fake.sh" 2>/dev/null &
      sleep 1
      exec /init /run.sh' >/dev/null
  sleep 16
}
state() { docker exec "dzt-ws-$1" jq -c "$2" /tmp/state.json; }
sent() { docker exec "dzt-ws-$1" sh -c "grep -c '\"type\":\"$2\"' /tmp/ws_requests || true"; }
check() { if eval "$2"; then :; else echo "FAIL: $1"; docker logs "dzt-ws-$3" 2>&1 | tail -8; exit 1; fi; }
trap 'docker rm -f "$id" dzt-ws-fresh dzt-ws-done dzt-ws-merge dzt-ws-off dzt-ws-old >/dev/null 2>&1' EXIT

scenario fresh '"server_port":80'
check "the tunnel is not trusted after a fresh start" '[ "$(state fresh ".stable | [.use_x_forwarded_for, .trusted_proxies, .server_port, .ip_ban_enabled]")" = "[true,[\"127.0.0.1\",\"172.30.33.0/24\"],80,true]" ]' fresh
check "the change was not confirmed" '[ "$(state fresh .pending)" = "null" ] && [ "$(sent fresh http/config/promote)" -eq 1 ]' fresh
check "metadata was sent back to Home Assistant" '! docker exec dzt-ws-fresh grep configure /tmp/ws_requests | grep -q created_at' fresh
check "the tunnel does not use the Home Assistant port" 'docker exec dzt-ws-fresh grep -q "localPort = 80" /tmp/frpc-t1.example.test.toml' fresh

scenario done '"server_port":8123,"use_x_forwarded_for":true,"trusted_proxies":["172.30.33.0/24","127.0.0.1"]'
check "settings that were already right were changed" '[ "$(sent done http/config/configure)" -eq 0 ]' done
check "port 8123 was not kept" 'docker exec dzt-ws-done grep -q "localPort = 8123" /tmp/frpc-t1.example.test.toml' done

scenario merge '"server_port":8123,"use_x_forwarded_for":true,"trusted_proxies":["10.0.0.5"]'
check "an existing trusted proxy was dropped" '[ "$(state merge ".stable.trusted_proxies")" = "[\"10.0.0.5\",\"127.0.0.1\",\"172.30.33.0/24\"]" ]' merge

scenario off '"server_port":8123' ',"configure_home_assistant":false'
check "the opt-out was ignored" '[ "$(sent off http/config/configure)" -eq 0 ] && [ "$(state off ".stable.use_x_forwarded_for")" = "null" ]' off

scenario old '"server_port":8123' '' old
check "no manual instruction on an older Home Assistant" 'docker logs dzt-ws-old 2>&1 | grep -q "Trust X-Forwarded-For"' old
check "the tunnel did not start on an older Home Assistant" 'docker exec dzt-ws-old grep -q "localPort = 8123" /tmp/frpc-t1.example.test.toml' old

echo "OK"
