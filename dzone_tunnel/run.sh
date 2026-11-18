#!/usr/bin/with-contenv bashio
# Enrolls this installation with DZone, then opens one outbound frp tunnel per
# configured server. Each tunnel is supervised on its own and keeps retrying
# until the installation is approved.
set -e

ENROLL_URL="${ENROLL_URL:-https://www.dzone.be/ha-enroll}"
TOKEN_FILE=/data/token

# Read with jq rather than bashio::config, which needs the Supervisor API.
OPTIONS=/data/options.json
SUBDOMAIN="$(jq -r '.subdomain // ""' "$OPTIONS")"

# Re-validated here because the value is written into a config file.
[[ "$SUBDOMAIN" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] \
  || bashio::exit.nok "Invalid subdomain: lowercase letters, digits and hyphens only."

# --- Home Assistant's HTTP settings -------------------------------------------
# Read and changed through Home Assistant's own websocket API, the same way
# Settings > System > Network does.
CORE_WS="${CORE_WS:-ws://supervisor/core/websocket}"
HA_WAIT="${HA_WAIT:-15}" # seconds between checks while Home Assistant restarts
PROXIES='["172.30.33.0/24","127.0.0.1"]'

# ws '<message with "id":1>': authenticates, sends one command, prints its reply.
ws() {
  { printf '%s\n' "{\"type\":\"auth\",\"access_token\":\"${SUPERVISOR_TOKEN:-}\"}" "$1"; sleep 3; } \
    | websocat -t "$CORE_WS" 2>/dev/null | jq -c 'select(.id == 1)' 2>/dev/null | head -n 1
}

# trusts_tunnel '<http config>': does this config already accept the tunnel?
trusts_tunnel() {
  jq -e --argjson want "$PROXIES" \
    '.use_x_forwarded_for == true and (($want - (.trusted_proxies // [])) | length == 0)' \
    <<<"$1" >/dev/null 2>&1
}

manual_config_hint() {
  bashio::log.warning "$1 In Home Assistant, open Settings > System > Network > HTTP server,"
  bashio::log.warning "turn on 'Trust X-Forwarded-For' and add the trusted proxies 172.30.33.0/24 and 127.0.0.1."
}

# Without "Trust X-Forwarded-For" and these trusted proxies Home Assistant
# answers every tunnelled request with "400: Bad Request". Home Assistant stores
# a change as a trial and restarts; the app confirms it once Home Assistant is
# reachable again. Unconfirmed, Home Assistant reverts by itself after 5 minutes.
configure_home_assistant() {
  [ "$(jq -r '.configure_home_assistant' "$OPTIONS")" != "false" ] || return 0

  local reply="$1" stable pending wanted try
  if [ "$(jq -r '.success' <<<"$reply" 2>/dev/null)" != "true" ]; then
    manual_config_hint "Could not read Home Assistant's HTTP settings."
    return 0
  fi
  stable="$(jq -c '.result.stable' <<<"$reply")"
  pending="$(jq -c '.result.pending' <<<"$reply")"

  if [ "$pending" != "null" ] && [ "$(jq -r '.error' <<<"$pending")" = "null" ]; then
    if trusts_tunnel "$pending"; then
      ws '{"id":1,"type":"http/config/promote"}' >/dev/null || true
      bashio::log.info "Confirmed Home Assistant's new HTTP settings."
    else
      manual_config_hint "Home Assistant has unconfirmed HTTP settings, so they were left untouched."
    fi
    return 0
  fi
  if trusts_tunnel "$stable"; then
    return 0
  fi
  if [ "$pending" != "null" ]; then
    manual_config_hint "An earlier change to the HTTP settings failed, so it was not tried again."
    return 0
  fi

  wanted="$(jq -c --argjson want "$PROXIES" \
    'del(.created_at, .error, .error_message)
     | .use_x_forwarded_for = true
     | .trusted_proxies = (((.trusted_proxies // []) + $want) | unique)' <<<"$stable")"
  reply="$(ws "{\"id\":1,\"type\":\"http/config/configure\",\"config\":${wanted}}" || true)"
  if [ "$(jq -r '.success' <<<"$reply" 2>/dev/null)" != "true" ]; then
    manual_config_hint "Home Assistant did not accept the HTTP settings."
    return 0
  fi
  bashio::log.info "Set Home Assistant to trust the tunnel. Home Assistant restarts once to apply this."

  # Confirm once Home Assistant is back and running on the new settings.
  for try in $(seq 1 16); do
    sleep "$HA_WAIT"
    reply="$(ws '{"id":1,"type":"http/config"}' || true)"
    [ "$(jq -r '.success' <<<"$reply" 2>/dev/null)" = "true" ] || continue
    pending="$(jq -c '.result.pending' <<<"$reply")"
    if trusts_tunnel "$(jq -c '.result.stable' <<<"$reply")"; then
      return 0
    fi
    if [ "$pending" = "null" ] || [ "$(jq -r '.error' <<<"$pending")" != "null" ]; then
      break
    fi
    if [ "$(jq -r '.result.active_config_type' <<<"$reply")" = "pending" ]; then
      ws '{"id":1,"type":"http/config/promote"}' >/dev/null || true
      bashio::log.info "Home Assistant is back; confirmed the new HTTP settings."
      return 0
    fi
  done
  manual_config_hint "The HTTP settings could not be confirmed."
}

HTTP_CONFIG="$(ws '{"id":1,"type":"http/config"}' || true)"

# The port Home Assistant listens on: 8123, or 80 on newer installations.
HA_PORT="$(jq -r '.result as $r
  | ($r[$r.active_config_type] | objects | .server_port)
    // (if $r.active_config_type == "default_legacy_port" then 8123 else null end)
    // $r.stable.server_port // empty' <<<"$HTTP_CONFIG" 2>/dev/null || true)"
[[ "$HA_PORT" =~ ^[0-9]+$ ]] || HA_PORT=8123
if [ "$(jq -r '.result.stable.ssl_certificate // empty' <<<"$HTTP_CONFIG" 2>/dev/null)" != "" ]; then
  bashio::log.warning "Home Assistant serves HTTPS itself (an SSL certificate is set under Settings > System > Network). The tunnel needs plain HTTP: remove the certificate there, DZone already provides HTTPS."
fi

# In the background: the tunnels below must not wait for a Home Assistant restart.
configure_home_assistant "$HTTP_CONFIG" &

# The token is this installation's own secret. It is generated once, kept in
# /data (part of Home Assistant backups) and only ever sent to the tunnel
# servers; DZone's website receives just its hash.
if ! grep -Eqx '[a-f0-9]{64}' "$TOKEN_FILE" 2>/dev/null; then
  (umask 077; head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$TOKEN_FILE")
fi
TOKEN="$(cat "$TOKEN_FILE")"
TOKEN_HASH="$(printf %s "$TOKEN" | sha256sum | cut -d' ' -f1)"
CODE="$(printf %s "${TOKEN_HASH:0:6}" | tr a-f A-F)"
# Where to take out or manage the subscription for this installation.
SUBSCRIBE_URL="${ENROLL_URL%/ha-enroll}/ha-subscribe?s=${SUBDOMAIN}&c=${CODE}"

# Ask where we stand. The website being unreachable must never keep an already
# approved installation offline, so anything but a clear refusal carries on.
STATUS="$(curl -s -m 20 -A 'Mozilla/5.0 (compatible; dzone-ha-app)' \
  -H 'Content-Type: application/json' \
  -d "{\"subdomain\":\"${SUBDOMAIN}\",\"token_hash\":\"${TOKEN_HASH}\"}" \
  "$ENROLL_URL" | jq -r '.status // ""' 2>/dev/null || true)"
case "$STATUS" in
  active)  bashio::log.info "Active for ${SUBDOMAIN}.ha.dzone.be. Manage your subscription: ${SUBSCRIBE_URL}" ;;
  pending) bashio::log.warning "Not active yet. Subscribe here: ${SUBSCRIBE_URL}"
           bashio::log.warning "The connection starts by itself within a few minutes after payment. Pairing code: ${CODE}" ;;
  blocked) bashio::log.warning "Remote access is blocked. Contact DZone. Pairing code: ${CODE}" ;;
  expired) bashio::log.warning "Your subscription has ended. Renew here: ${SUBSCRIBE_URL}" ;;
  taken)   bashio::exit.nok "Subdomain '${SUBDOMAIN}' belongs to another installation. Choose another one, or contact DZone if this installation was reinstalled. Pairing code: ${CODE}" ;;
  invalid) bashio::exit.nok "Subdomain '${SUBDOMAIN}' is not allowed. Choose another one." ;;
  busy)    bashio::log.warning "DZone cannot take the request right now; restart this app later. Pairing code: ${CODE}" ;;
  *)       bashio::log.warning "Could not reach DZone to check the status; connecting anyway. Pairing code: ${CODE}" ;;
esac

trap 'exit 0' TERM INT

started=0
for SERVER in $(jq -r '.servers[]?' "$OPTIONS"); do
  [[ "$SERVER" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] \
    || bashio::exit.nok "Invalid server name: ${SERVER}"

  CONF="/tmp/frpc-${SERVER}.toml"
  (umask 077; cat > "$CONF" <<EOF
serverAddr = "${SERVER}"
serverPort = 7000
user = "${SUBDOMAIN}"
metadatas.token = "${TOKEN}"
loginFailExit = false
log.disablePrintColor = true
transport.tls.useSystemCa = true
transport.tls.serverName = "${SERVER}"

[[proxies]]
name = "ha"
type = "http"
localIP = "homeassistant"
localPort = ${HA_PORT}
subdomain = "${SUBDOMAIN}"
EOF
  )

  bashio::log.info "Starting tunnel to ${SERVER}"
  (
    while true; do
      frpc -c "$CONF" || true
      bashio::log.warning "Tunnel to ${SERVER} stopped, restarting in 5 seconds"
      sleep 5
    done
  ) &
  started=$((started + 1))
done

[ "$started" -gt 0 ] || bashio::exit.nok "No servers configured."
wait
