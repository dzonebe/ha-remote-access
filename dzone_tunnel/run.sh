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

# --- Home Assistant must trust the tunnel as a proxy -------------------------
# Without these lines Home Assistant answers every tunnelled request with
# "400: Bad Request". They can only be set in configuration.yaml, so the app
# adds them itself when that is safe: no http: section yet, a backup is kept,
# and the result is validated by Home Assistant before it is restarted.
HA_CONFIG="${HA_CONFIG:-/homeassistant/configuration.yaml}"
CORE_API="${CORE_API:-http://supervisor/core/api}"
MARKER="# Added by DZone Remote Access"

core_api() {
  curl -s -m 60 -X POST -H "Authorization: Bearer ${SUPERVISOR_TOKEN:-}" \
    -H 'Content-Type: application/json' "${CORE_API}/$1"
}

manual_config_hint() {
  bashio::log.warning "$1 Add this to configuration.yaml yourself and restart Home Assistant:"
  bashio::log.warning "  http:"
  bashio::log.warning "    use_x_forwarded_for: true"
  bashio::log.warning "    trusted_proxies:"
  bashio::log.warning "      - 172.30.33.0/24"
  bashio::log.warning "      - 127.0.0.1"
}

configure_home_assistant() {
  [ "$(jq -r '.configure_home_assistant' "$OPTIONS")" != "false" ] || return 0
  if [ ! -w "$HA_CONFIG" ]; then
    manual_config_hint "Cannot write to configuration.yaml."
    return 0
  fi
  if grep -qF "$MARKER" "$HA_CONFIG"; then
    return 0
  fi
  if grep -Eq '^http:' "$HA_CONFIG"; then
    if grep -q 'use_x_forwarded_for' "$HA_CONFIG" && grep -qF '172.30.33.0/24' "$HA_CONFIG" \
      && grep -qF '127.0.0.1' "$HA_CONFIG"; then
      return 0
    fi
    manual_config_hint "configuration.yaml already has an http: section, so it was left untouched."
    return 0
  fi

  cp -p "$HA_CONFIG" "${HA_CONFIG}.dzone-backup"
  {
    [ -z "$(tail -c1 "$HA_CONFIG")" ] || echo
    printf '\n%s: lets Home Assistant accept requests that arrive through the tunnel.\n' "$MARKER"
    printf 'http:\n  use_x_forwarded_for: true\n  trusted_proxies:\n    - 172.30.33.0/24\n    - 127.0.0.1\n'
  } >> "$HA_CONFIG"

  local result
  result="$(core_api config/core/check_config | jq -r '.result // ""' 2>/dev/null || true)"
  if [ "$result" != "valid" ]; then
    cp -p "${HA_CONFIG}.dzone-backup" "$HA_CONFIG"
    manual_config_hint "Home Assistant did not accept the change, so configuration.yaml was restored."
    return 0
  fi
  bashio::log.info "Added the proxy settings to configuration.yaml (backup: configuration.yaml.dzone-backup). Restarting Home Assistant once to apply them."
  core_api services/homeassistant/restart >/dev/null 2>&1 || true
}
configure_home_assistant

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
localPort = 8123
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
