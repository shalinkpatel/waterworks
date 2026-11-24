#!/usr/bin/env bash
# Live fleet dashboard: lists every registered endpoint (agents and tools), online
# first. Registers one dashboard endpoint, then re-renders it whenever the fleet
# changes (unchanged state sends nothing, so mailbox history stays small).
# Needs WW_ADMIN_TOKEN; optional WW_URL, FLEET_INTERVAL (seconds, default 5).
set -euo pipefail
base="${WW_URL:-http://127.0.0.1:7420}"
: "${WW_ADMIN_TOKEN:?WW_ADMIN_TOKEN is required}"

reg="$(curl -fsS -X POST "$base/v1/endpoints" -H "x-ww-admin-token: $WW_ADMIN_TOKEN" \
  -H 'content-type: application/json' -d '{
    "kind":"tool","name":"fleet",
    "accepts":["dashboard.render.v1","dashboard.reply.v1","dashboard.clear.v1"],
    "emits":["dashboard.render.v1","core.error.v1"]}')"
id="$(jq -r .endpoint.id <<<"$reg")"
token="$(jq -r .token <<<"$reg")"
auth=(-H "x-ww-endpoint: $id" -H "authorization: Bearer $token")
url="$base/dashboard#endpoint=$id&token=$token"
echo "fleet dashboard: $url"
[ "$(uname -s)" = Darwin ] && [ "${WW_OPEN_BROWSER:-1}" != 0 ] && open "$url"

last=""
while true; do
  payload="$(curl -fsS "${auth[@]}" "$base/v1/endpoints" | jq -c '
    (.endpoints | map(select(.id != "'"$id"'"))) as $e
    | ($e | sort_by(.online | not)) as $s
    | {title: "Waterworks fleet", panels: [
        {id:"total",   kind:"stat", title:"Registered", value:($e|length), width:1},
        {id:"online",  kind:"stat", title:"Online",     value:($e|map(select(.online))|length), width:1},
        {id:"agents",  kind:"stat", title:"Agents",     value:($e|map(select(.kind=="agent"))|length), width:1},
        {id:"tools",   kind:"stat", title:"Tools",      value:($e|map(select(.kind=="tool"))|length), width:1},
        {id:"fleet",   kind:"table", title:"Endpoints (online first, max 100)", width:4,
         columns:["name","kind","status","id","cwd","accepts"],
         rows:($s[:100] | map([.name, .kind, (if .online then "online" else "offline" end), .id,
                               (.metadata.cwd // ""), (.accepts|join(", "))]))}]}')"
  if [ "$payload" != "$last" ]; then
    jq -nc --arg to "$id" --argjson p "$payload" \
      '{to:$to, type:"dashboard.render.v1", payload:$p}' \
    | curl -fsS -X POST "$base/v1/messages" "${auth[@]}" -H 'content-type: application/json' -d @- >/dev/null
    last="$payload"
  fi
  sleep "${FLEET_INTERVAL:-5}"
done
