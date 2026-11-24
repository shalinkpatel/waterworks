#!/usr/bin/env bash
# Live canvas demo: a scratch daemon, a report-style page with streamed metrics, and a small
# responder that answers comments. Usage: scripts/demo.sh [stop]. Needs the release (MIX_ENV=prod mix release),
# curl, jq, and openssl. WW_DEMO_PORT (default 7470) and WW_OPEN_BROWSER=0 are optional.
set -euo pipefail
cd "$(dirname "$0")/.."

dir=tmp/demo
port=${WW_DEMO_PORT:-7470}
url="http://127.0.0.1:$port"

# ./ww runs the BEAM as a child and the responder is a pipeline, so stop whole process trees.
killtree() {
  local pid child
  for pid in "$@"; do
    for child in $(pgrep -P "$pid" 2>/dev/null); do killtree "$child"; done
    kill "$pid" 2>/dev/null || true
  done
}

if [ "${1:-}" = "stop" ]; then
  if [ -f "$dir/pids" ]; then
    killtree $(cat "$dir/pids")
    # The daemon shuts down gracefully (Mnesia flushes); wait for it, then force it.
    for _ in $(seq 1 50); do pgrep -f -- "--mnesia-dir $dir/mnesia" >/dev/null || break; sleep 0.1; done
    pkill -9 -f -- "--mnesia-dir $dir/mnesia" 2>/dev/null || true
  fi
  rm -f "$dir/pids"
  echo "demo stopped"
  exit 0
fi

for tool in curl jq openssl; do command -v "$tool" >/dev/null || { echo "demo needs $tool" >&2; exit 1; }; done
[ -x _build/prod/rel/ww/bin/ww ] || { echo "build the release first: MIX_ENV=prod mix release" >&2; exit 1; }
if curl -fsS "$url/v1/health" >/dev/null 2>&1; then
  echo "port $port is in use; run scripts/demo.sh stop or set WW_DEMO_PORT" >&2
  exit 1
fi

rm -rf "$dir"
mkdir -p "$dir"
chmod 700 "$dir"
umask 077
pids=()
cleanup() {
  trap - EXIT INT TERM
  killtree "${pids[@]}"
  rm -f "$dir/pids"
}
trap cleanup EXIT INT TERM

# A fresh local admin token for this demo only; kept in a private file, never printed.
admin=$(openssl rand -hex 24)
printf '%s' "$admin" >"$dir/admin-token"
# curl reads credentials from private header files so they never appear in process arguments.
printf 'x-ww-admin-token: %s\n' "$admin" >"$dir/admin-headers"
export WW_URL="$url" WW_ADMIN_TOKEN="$admin"

./ww serve --port "$port" --mnesia-dir "$dir/mnesia" >"$dir/server.log" 2>&1 &
pids+=($!)
for _ in $(seq 1 100); do curl -fsS "$url/v1/health" >/dev/null 2>&1 && break; sleep 0.1; done
curl -fsS "$url/v1/health" >/dev/null || { cat "$dir/server.log" >&2; exit 1; }

register() {
  curl -fsS -X POST "$url/v1/endpoints" -H @"$dir/admin-headers" -H "content-type: application/json" -d "$1"
}
agent=$(register '{"kind":"agent","name":"demo-agent","accepts":["canvas.comment.v1"]}')
agent_id=$(jq -r .endpoint.id <<<"$agent")
agent_token=$(jq -r .token <<<"$agent")
export WW_ENDPOINT="$agent_id" WW_TOKEN="$agent_token"
printf 'x-ww-endpoint: %s\nauthorization: Bearer %s\n' "$agent_id" "$agent_token" >"$dir/agent-headers"
dash=$(./ww canvas --title "Live fleet")
dash_id=$(jq -r .endpoint.id <<<"$dash")
jq -r .url <<<"$dash" >"$dir/url"

send() { # type payload [reply_to]
  jq -n --arg to "$dash_id" --arg type "$1" --argjson payload "$2" --arg reply "${3:-}" \
    '{to: $to, type: $type, payload: $payload} + (if $reply == "" then {} else {reply_to: $reply} end)' |
    curl -fsS -o /dev/null -X POST "$url/v1/messages" -H "content-type: application/json" \
      -H @"$dir/agent-headers" -d @-
}

./ww publish --to "$dash_id" --file scripts/demo/page.html --title "Live fleet" --watch 2>>"$dir/publish.log" &
pids+=($!)
sleep 1

# Simulated fleet, one tick a second; us-east-1 has a p99 incident for 10 s every minute.
(
  t=0
  while :; do
    payload=$(awk -v t="$t" -v seed="$RANDOM" 'BEGIN {
      srand(seed); incident = (t % 60 >= 30 && t % 60 < 40)
      split("us-east-1 us-west-2 eu-west-1 ap-south-1", names, " ")
      split("520 410 300 180", base, " ")
      regions = ""; total = 0; p50s = 0; p99max = 0
      for (i = 1; i <= 4; i++) {
        qps = int(base[i] * (0.9 + rand() * 0.2)); p50 = int(38 + rand() * 12)
        p99 = int(140 + rand() * 60); if (incident && i == 1) p99 = int(650 + rand() * 250)
        total += qps; p50s += p50; if (p99 > p99max) p99max = p99
        regions = regions (i > 1 ? "," : "") sprintf("{\"name\":\"%s\",\"qps\":%d,\"p50\":%d,\"p99\":%d}", names[i], qps, p50, p99)
      }
      errors = incident ? 2.5 + rand() : 0.1 + rand() * 0.3
      printf "{\"kind\":\"tick\",\"t\":%d,\"qps\":%d,\"p50\":%d,\"p99\":%d,\"errors\":%.2f,\"regions\":[%s]}", t, total, p50s / 4, p99max, errors, regions
    }')
    send canvas.data.v1 "$payload" || true
    t=$((t + 1))
    sleep 1
  done
) &
pids+=($!)

# Responder: answers each comment in the sidebar, pins a note into the page, then acks it.
(
  curl -sSN "$url/v1/endpoints/$agent_id/tail" -H @"$dir/agent-headers" |
    while IFS= read -r line; do
      [ "$(jq -r .op <<<"$line")" = "message" ] || continue
      message=$(jq -c .message <<<"$line")
      id=$(jq -r .id <<<"$message")
      if [ "$(jq -r .type <<<"$message")" = "canvas.comment.v1" ]; then
        text=$(jq -r .payload.text <<<"$message")
        about=$(jq -r '.payload.element as $e | if $e then "<\($e.tag)> in \(.payload.context.heading // "the page")" else ([.payload.context.heading, (.payload.panels // [] | map(.title) | join(", "))] | map(select(. != null and . != "")) | .[0] // "the page") end' <<<"$message")
        seen=$(jq -r '(.payload.selection // "") as $s | if $s != "" then $s else (.payload.element.text // .payload.context.text // "") end | .[0:90]' <<<"$message")
        reply="Noted on \"$about\". I saw: \"$seen\". A real agent (Pi) would now act on: $text"
        send canvas.reply.v1 "$(jq -n --arg text "$reply" '{text: $text}')" "$id" || true
        send canvas.data.v1 "$(jq -n --arg text "$text" --arg about "$about" '{kind: "note", text: $text, about: $about}')" || true
      fi
      curl -fsS -o /dev/null -X POST "$url/v1/endpoints/$agent_id/ack" -H "content-type: application/json" \
        -H @"$dir/agent-headers" -d "$(jq -n --arg id "$id" '{id: $id}')" || true
    done
) &
pids+=($!)

printf '%s\n' "${pids[@]}" >"$dir/pids"
if [ "$(uname)" = "Darwin" ] && [ "${WW_OPEN_BROWSER:-1}" != "0" ]; then open "$(cat "$dir/url")"; fi

cat <<EOF
Waterworks demo running on $url
  Canvas: opened in your browser (URL with its credentials is in $dir/url)
  Edit scripts/demo/page.html and save: the page republishes live as a delta.
  Comment: "Comment area" to drag, or "Select element" to click one (↑ widens); describe it.

Connect a real Pi agent to this daemon (it can open and publish its own canvases):
  WW_URL=$url WW_ADMIN_TOKEN="\$(cat $dir/admin-token)" pi -e "$PWD/.pi/extensions/waterworks.js"

Stop with Ctrl-C (or scripts/demo.sh stop if running in the background).
EOF
wait
