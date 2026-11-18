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

# The token is this installation's own secret. It is generated once, kept in
# /data (part of Home Assistant backups) and only ever sent to the tunnel
# servers; DZone's website receives just its hash.
if ! grep -Eqx '[a-f0-9]{64}' "$TOKEN_FILE" 2>/dev/null; then
  (umask 077; head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$TOKEN_FILE")
fi
TOKEN="$(cat "$TOKEN_FILE")"
TOKEN_HASH="$(printf %s "$TOKEN" | sha256sum | cut -d' ' -f1)"
CODE="$(printf %s "${TOKEN_HASH:0:6}" | tr a-f A-F)"

# Ask where we stand. The website being unreachable must never keep an already
# approved installation offline, so anything but a clear refusal carries on.
STATUS="$(curl -s -m 20 -A 'Mozilla/5.0 (compatible; dzone-ha-app)' \
  -H 'Content-Type: application/json' \
  -d "{\"subdomain\":\"${SUBDOMAIN}\",\"token_hash\":\"${TOKEN_HASH}\"}" \
  "$ENROLL_URL" | jq -r '.status // ""' 2>/dev/null || true)"
case "$STATUS" in
  active)  bashio::log.info "Approved for ${SUBDOMAIN}.ha.dzone.be" ;;
  pending) bashio::log.warning "Waiting for approval by DZone. Pairing code: ${CODE}" ;;
  blocked) bashio::log.warning "Remote access is blocked. Contact DZone. Pairing code: ${CODE}" ;;
  expired) bashio::log.warning "Remote access has expired. Contact DZone. Pairing code: ${CODE}" ;;
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
