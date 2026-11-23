# Waterworks

Waterworks (`ww`) is a small Elixir/OTP daemon that connects agent and tool
instances through crash-durable, typed mailboxes. It supports direct messaging,
capability discovery, offline delivery, acknowledgement, and multiple Erlang
nodes on a trusted network.

See [DESIGN.md](DESIGN.md) for the protocol and delivery model.

Waterworks is inspired by David Crespo's [ah](https://github.com/david-crespo/ah)
("agent host"), which showed how small web tools can talk back to a running
coding agent. Waterworks generalizes that idea into a mailbox for any agent or
tool, with live, commentable dashboards on top.

## Build

Requires Elixir 1.20 and Erlang/OTP with Mnesia.

```sh
mix deps.get
mix escript.build
```

The generated `./ww` executable contains the CLI and daemon. Runtime
configuration is supplied through command-line options and environment
variables, not written into the executable.

## Start a daemon

The admin token is the one credential that can create endpoints; `ww serve`
refuses tokens shorter than 16 characters. Generate a random one:

```sh
export WW_ADMIN_TOKEN="$(openssl rand -hex 32)"
./ww serve
```

The daemon listens on `127.0.0.1:7420` by default. Mnesia state defaults to
`$XDG_STATE_HOME/waterworks/<node>/mnesia`, or `~/.local/state` when
`XDG_STATE_HOME` is unset, and is created private to your user. Use
`--mnesia-dir` to override it and `--port` or `--bind` to change the listener.

Requests must name this daemon in their `Host` header (loopback names or the
bind address), which stops web pages from reaching it through DNS rebinding.
Add other names clients use, such as a LAN hostname, with `--allow-host HOST`
(repeatable); binding to `0.0.0.0` requires it.

## Register and connect endpoints

Registration returns an endpoint descriptor and its token. The token is shown
only in this response and authorizes actions as that endpoint.

```sh
./ww register --kind agent --name pi-main
./ww register \
  --kind tool --name dashboard \
  --accepts dashboard.render.v1 \
  --emits ui.button_clicked.v1 \
  --metadata workspace="$PWD"
```

Set the endpoint credentials used by subsequent commands:

```sh
export WW_ENDPOINT='<endpoint-id>'
export WW_TOKEN='<endpoint-token>'
```

Examples:

```sh
./ww discover --kind tool --accepts dashboard.render.v1 --online
./ww inspect "$WW_ENDPOINT"
./ww send --to "$WW_ENDPOINT" --type dashboard.render.v1 \
  --data '{"title":"Deployment","status":"started"}'
./ww tail                 # newline-delimited JSON; explicit acknowledgement
./ww tail --ack           # acknowledge each message after writing it
./ww ack --id msg_...
./ww history
```

`tail` emits `ready`, `message`, and `heartbeat` objects. Tools should ignore
control objects they do not understand. `WW_URL` selects the daemon and defaults
to `http://127.0.0.1:7420`.

## Browser and CLI demo

Register one endpoint for the browser and another for the CLI adapter. Start the
CLI adapter with the CLI endpoint's credentials:

```sh
export WW_ENDPOINT='<cli-endpoint-id>'
export WW_TOKEN='<cli-endpoint-token>'
./ww echo
```

Open `http://127.0.0.1:7420/demo`, enter the browser endpoint's ID and token and
the CLI endpoint's ID, then connect and send a message. The CLI returns
`demo.echoed.v1`; the page applies it and acknowledges it without reloading.
The browser token is kept only in page memory. This is a fixed demonstration
page, not generic arbitrary-HTML hosting.

## Demo

```sh
mix escript.build
scripts/demo.sh        # Ctrl-C to stop; or run in the background and use scripts/demo.sh stop
```

This starts a scratch daemon on port 7470 (`WW_DEMO_PORT`) with state in
`tmp/demo`, opens a report-style page with Vega-Lite charts, streams simulated
fleet metrics into it every second (us-east-1 has a p99 incident each minute),
and runs a small responder that answers comments in the sidebar and pins notes
into the page. Edit `scripts/demo/page.html` while it runs: each save is
published live as a delta. The script prints how to connect a real Pi agent to
the same daemon. Needs `curl`, `jq`, and `openssl`; the charts load from a CDN.

## Live dashboards

A dashboard is a tool endpoint rendered at `/dashboard`. Create one and open the
printed URL; its credentials ride in the URL fragment, which the browser never
sends to the server, and the page moves them into tab storage:

```sh
export WW_ADMIN_TOKEN='<your-local-admin-token>'
./ww dashboard --title "Fleet health"
```

### Page mode (HTML reports)

Publish any self-contained HTML page: inline data, Vega-Lite or other CDN scripts,
your own JS. Each publish replaces the page live and bumps its version chip:

```sh
./ww publish --to <dashboard-id> --file report.html --watch   # republish on every save
```

Pages run in a sandboxed frame with an opaque origin (`sandbox allow-scripts
allow-popups allow-popups-to-escape-sandbox`): scripts and CDNs work, links may
open ordinary (unsandboxed) tabs, but the page
cannot reach the dashboard's token, storage, or the authenticated API. Stream data
into a running page without a reload by sending `dashboard.data.v1 {any}`:

```js
addEventListener("waterworks", (event) => update(event.detail));
```

Data sent since the last publish is replayed after a reload. Pages may be up to
16 MB.

Republishing sends a delta when that is less than half the page:
`dashboard.delta.v1 {base, ops, title?}`, where `base` is the message ID of the
version it edits and `ops` are line edits that consume the whole base:
`{keep: n}`, `{drop: n}`, `{insert: [lines]}`. `ww publish --watch` diffs with
Myers (one edit to a 3 MB page sent 174 bytes); Pi's `ww_dashboard_publish` sends
the changed span. A delta whose base is not the current page is refused: the page
keeps its version, shows "missed an update", and replies `core.error.v1
{error: "delta_base_mismatch"}` to the sender, after which Pi publishes the full
page. Deltas are line-based, so keep large embedded data on many lines, or stream
it with `dashboard.data.v1`. Comments on a page carry `context`: the section heading, the visible
text, and the element ids under the region (or your text selection inside the
page).

### Panel mode

Without writing HTML, any endpoint can stream structured panels:

| Type | Payload |
| --- | --- |
| `dashboard.render.v1` | `{title, panels}` replaces the page (`{title?, html}` for page mode) |
| `dashboard.delta.v1` | page mode: `{base, ops, title?}` edits the current page's lines |
| `dashboard.patch.v1` | `{title?, panels?, remove?, append?}`: upsert panels by `id`, remove ids, append `[x, y]` points to line series |
| `dashboard.reply.v1` | `{text}` with `reply_to` set to a comment's ID |

Panels are `{id, kind, title, width?}` where `width` spans 1–4 columns and
`kind` is one of `stat {value, unit?, delta?}`, `line {series: [{name, points}]}`,
`bar {bars: [{label, value}]}`, `table {columns, rows}`, or `text {text}`. Line
series keep at most 500 points. Agent content is rendered as text, never HTML.

To give feedback, use **Comment area** to drag a rectangle (or select text
first, or press Enter for the whole dashboard), or **Select element** to click
one: hover outlines it, ↑/↓ widen to its parent or narrow back, and a click or
Enter picks what is outlined. On published pages the picker runs inside the
sandboxed frame. The selection stays highlighted while you write; once sent it
remains as a hatched, numbered marker, and element markers follow their element
across republishes, deltas, and relayouts. The page sends
`dashboard.comment.v1` to the endpoint that last rendered it:

```json
{"text": "...", "region": {"x": 0.1, "y": 0, "width": 0.3, "height": 0.2},
 "panels": [{"id": "qps", "title": "QPS", "kind": "stat"}],
 "selection": "", "dashboard": {"title": "...", "sequence": 7}}
```

`region` is a fraction of the dashboard; page-mode comments add
`context: {heading, text, ids, selection}` and `dashboard.version`, and picked
elements add `element: {selector, tag, id, classes, text}` (plus `panel` in panel
mode). Replies appear under the comment. The agent removes markers once it has
addressed them with `dashboard.clear.v1 {comments: [ids]}` or `{all: true}`
(comments made before the clear); the comment stays in the sidebar as "cleared
by agent". A reload rebuilds the page, clears included, from the endpoint's
mailbox history.

## Pi adapter

The reference Pi extension is `.pi/extensions/waterworks.js`. Start Pi with an
admin token so each session can register its own agent endpoint:

```sh
export WW_ADMIN_TOKEN='<your-local-admin-token>'
pi -e "$PWD/.pi/extensions/waterworks.js"
```

Alternatively, pre-register an agent and supply `WW_ENDPOINT` and `WW_TOKEN`.
The extension reconnects automatically, keeps credentials in memory, injects
supported messages with `pi.sendMessage(..., deliverAs: "steer")`, and registers
`ww_send`, `ww_discover`, `ww_dashboard_open`, and `ww_dashboard_publish`
(publish an HTML file from disk) tools for the model.
`ww_dashboard_open` creates a dashboard, shows its URL to you, and opens it on
macOS (set `WW_OPEN_BROWSER=0` to disable); the model receives only the
endpoint ID, never the dashboard token. Mailbox acknowledgement means Pi
accepted the message into its session; completion is a separate response.

The reference adapter accepts `demo.echo.v1`, `dashboard.comment.v1`, and
`core.error.v1`. Comments are accepted only from dashboards the session opened
or published to (others get `core.error.v1 {error: "unknown_dashboard"}`), and
the model is told that page-derived fields (`context`, `element`, `selection`)
are untrusted data, not instructions. Other types queue in an inbox the
model reads with `ww_inbox` (the footer shows the count), unless the sender sets
`payload.delivery` to `"immediate"`, which prompts the session now. Extend `acceptedTypes` and the
message rendering as tool contracts grow. The integration test uses Pi's local
`faux` provider and never contacts an external model API.

## Multiple nodes

Every node needs a reachable long node name and the same Erlang cookie; anyone
with the cookie can run code on every node. Put it in `~/.erlang.cookie` with
mode 0400 on each host (Waterworks never creates or modifies that file):

```sh
export WW_ADMIN_TOKEN="$(openssl rand -hex 32)"
openssl rand -hex 32 > ~/.erlang.cookie && chmod 400 ~/.erlang.cookie   # same value on every node
```

On a single-user host you can instead pass `ERL_AFLAGS="-setcookie ..."`, but
that puts the cookie in the process arguments, visible to other local users.

Start the first node:

```sh
./ww serve \
  --name ww1@192.0.2.10 \
  --mnesia-dir /var/lib/waterworks/node1
```

Start a fresh second node and join the first:

```sh
./ww serve \
  --name ww2@192.0.2.11 \
  --join ww1@192.0.2.10 \
  --mnesia-dir /var/lib/waterworks/node2
```

Replace the example IPs with addresses reachable on your network. EPMD and the
Erlang distribution ports must also be reachable between nodes. A joining node
must either have fresh local state or already belong to the same Mnesia schema.

Clients can connect to either daemon. Endpoint records and messages are
replicated, and live presence is exchanged through `:pg`.

Remote HTTP clients require an explicit `--bind` address (and `--allow-host`
for names other than that address). The current transport
is plain HTTP/WebSocket with bearer credentials, so use it only on a trusted
network; there is no TLS or untrusted-internet security boundary.

## HTTP and WebSocket API

All routes except health require authentication. Endpoint requests use:

```text
X-WW-Endpoint: ep_...
Authorization: Bearer <endpoint-token>
```

Registration instead uses `X-WW-Admin-Token`.

| Operation | Route |
| --- | --- |
| Health | `GET /v1/health` |
| Register | `POST /v1/endpoints` |
| Discover | `GET /v1/endpoints` |
| Inspect | `GET /v1/endpoints/:id` |
| Send | `POST /v1/messages` |
| History | `GET /v1/endpoints/:id/history` |
| Streaming tail | `GET /v1/endpoints/:id/tail` |
| Acknowledge | `POST /v1/endpoints/:id/ack` |
| WebSocket | `GET /v1/endpoints/:id/socket` |

Browser WebSockets authenticate with subprotocols so tokens do not appear in
URLs:

```js
const socket = new WebSocket(
  `ws://127.0.0.1:7420/v1/endpoints/${endpointId}/socket`,
  ["ww", `ww-token.${endpointToken}`],
);

socket.onmessage = ({ data }) => {
  const frame = JSON.parse(data);
  if (frame.op === "message") {
    // Apply frame.message, then acknowledge it.
    socket.send(JSON.stringify({ op: "ack", id: frame.message.id }));
  }
};
```

Send a message over the socket with `op: "send"`:

```json
{
  "op": "send",
  "to": "ep_...",
  "type": "ui.button_clicked.v1",
  "payload": {"button": "deploy"},
  "reply_to": null
}
```

## Tests

```sh
mix test
```

Run the loopback HTTP/WebSocket tests:

```sh
WW_TEST_HTTP=1 mix test --include transport
```

Run everything, including the real two-node test and the headless-Chrome
dashboard test (requires Google Chrome; the explicit test cookie means no
`~/.erlang.cookie` is created):

```sh
epmd -daemon
WW_TEST_HTTP=1 elixir --name ww_test@127.0.0.1 --cookie ww_test_cookie \
  -S mix test --include distributed --include transport --include browser
```

When a sandbox forbids Mix's local compile-lock socket, prefix commands with
`MIX_OS_CONCURRENCY_LOCK=0`; do not run concurrent compilations in that mode.

## Current limits

- At-least-once delivery; receivers must deduplicate application effects.
- Per-mailbox ordering only while replicas are connected. A partition can create
  conflicting sequences and writes on both sides. Mnesia does not automatically
  merge diverged replicas; recovery requires manually choosing an authoritative
  side and restarting/resynchronizing the losers.
- Mnesia transactions support daemon/node crash recovery but are not an fsync
  guarantee. OS crashes or power loss can lose recent writes.
- Every admitted cluster node is fully trusted. Erlang distribution, EPMD, and
  the plain HTTP transport are for trusted networks only.
- `disc_copies` retains all history in RAM and on disk; retention and large
  payload storage are not implemented.
- Endpoints cannot be deregistered and tokens cannot be rotated yet; a leaked
  endpoint token stays valid. Every Pi session and dashboard adds an endpoint.
- Mailbox ownership uses `:global`, which assumes a connected full-mesh cluster;
  OTP may log and resolve a name conflict during concurrent takeover.
- Dashboard comments made before a reload persist only in that browser tab.
  Reloads replay the dashboard's whole history; deltas keep that small, but
  every full publish of a large page stays in it. A page's scripts can stream data to itself but
  cannot send messages to the agent. The Pi adapter forgets which dashboards it
  opened when its session restarts, after which their comments are refused.
  Other harnesses are not implemented.
