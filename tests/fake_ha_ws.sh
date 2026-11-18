#!/bin/bash
# Stand-in for Home Assistant's websocket API, one process per connection
# (started by websocat in test.sh). Keeps the HTTP config in /tmp/state.json
# the way Home Assistant does (stable / pending / promote) and records every
# message it receives in /tmp/ws_requests. MODE=old answers like a Home
# Assistant version that does not know the http/config commands.
echo '{"type":"auth_required"}'
while read -r line; do
  echo "$line" >> /tmp/ws_requests
  type="$(jq -r '.type' <<<"$line")"
  id="$(jq -r '.id // 0' <<<"$line")"
  ok() { echo "{\"id\":$id,\"type\":\"result\",\"success\":true,\"result\":${1:-null}}"; }
  if [ "$type" = "auth" ]; then
    echo '{"type":"auth_ok"}'
  elif [ "${MODE:-}" = "old" ]; then
    echo "{\"id\":$id,\"type\":\"result\",\"success\":false,\"error\":{\"code\":\"unknown_command\",\"message\":\"Unknown command.\"}}"
  elif [ "$type" = "http/config" ]; then
    ok "$(jq -c . /tmp/state.json)"
  elif [ "$type" = "http/config/configure" ]; then
    jq -c --argjson c "$(jq -c '.config' <<<"$line")" \
      '.pending = ($c + {created_at: "now", error: null, error_message: null}) | .active_config_type = "pending"' \
      /tmp/state.json > /tmp/state.new && mv /tmp/state.new /tmp/state.json
    ok '{"restart":true}'
  elif [ "$type" = "http/config/promote" ]; then
    jq -c '.stable = .pending | .pending = null | .active_config_type = "stable"' \
      /tmp/state.json > /tmp/state.new && mv /tmp/state.new /tmp/state.json
    ok
  fi
done
