# Waterworks

Waterworks (`ww`) is a small Elixir/OTP daemon that connects agent and tool
instances through crash-durable, typed mailboxes. It supports direct messaging,
capability discovery, offline delivery, acknowledgement, and multiple Erlang
nodes on a trusted network.

See [DESIGN.md](DESIGN.md) for the protocol and delivery model.

Waterworks is inspired by David Crespo's [ah](https://github.com/david-crespo/ah)
("agent host"), which showed how small web tools can talk back to a running
coding agent. Waterworks generalizes that idea into a mailbox for any agent or
tool. Live, commentable canvases are included as one example tool built on it.

## Build

Requires Elixir 1.20 and Erlang/OTP with Mnesia to build; the release bundles
its own Erlang runtime.

```sh
mix deps.get
MIX_ENV=prod mix release
```

`./ww` is a small committed wrapper that runs the CLI and daemon from that
release (`_build/prod/rel/ww`); symlink it onto your `PATH` (it resolves the
release next to the real script, or set `WW_RELEASE`). Rebuild the release after
pulling. It is a release rather than an escript so native libraries (NIFs) can be
loaded. Runtime configuration is supplied through command-line options and
environment variables, not written into the release; a distributed node takes
its cookie from `~/.erlang.cookie` (or `-setcookie` in `ERL_AFLAGS`), not the
release's own generated one.

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
  --kind tool --name canvas \
  --accepts canvas.render.v1 \
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
./ww discover --kind tool --accepts canvas.render.v1 --online
./ww inspect "$WW_ENDPOINT"
./ww send --to "$WW_ENDPOINT" --type canvas.render.v1 \
  --data '{"title":"Deployment","status":"started"}'
./ww tail                 # newline-delimited JSON; explicit acknowledgement
./ww tail --ack           # acknowledge each message after writing it
./ww ack --id msg_...
./ww history
```

`tail` emits `ready`, `message`, and `heartbeat` objects, and a final
`deregistered` if the endpoint is removed. Tools should ignore
control objects they do not understand. `WW_URL` selects the daemon and defaults
to `http://127.0.0.1:7420`.

## Demo

```sh
MIX_ENV=prod mix release
scripts/demo.sh        # Ctrl-C to stop; or run in the background and use scripts/demo.sh stop
```

This starts a scratch daemon on port 7470 (`WW_DEMO_PORT`) with state in
`tmp/demo`, opens a report-style page with Vega-Lite charts, streams simulated
fleet metrics into it every second (us-east-1 has a p99 incident each minute),
and runs a small responder that answers comments in the sidebar and pins notes
into the page. Edit `scripts/demo/page.html` while it runs: each save is
published live as a delta. The script prints how to connect a real Pi agent to
the same daemon. Needs `curl`, `jq`, and `openssl`; the charts load from a CDN.

## Pi adapter

The reference Pi extension is `.pi/extensions/waterworks.js`. Start Pi with an
admin token so each session can register its own agent endpoint:

```sh
export WW_ADMIN_TOKEN='<your-local-admin-token>'
pi -e "$PWD/.pi/extensions/waterworks.js"
```

Alternatively, pre-register an agent and supply `WW_ENDPOINT` and `WW_TOKEN`.
The endpoint is named after the session (`/name`), falling back to `pi-<pid>`,
and is renamed whenever the session name changes.
The extension reconnects automatically, keeps credentials in memory, injects
supported messages with `pi.sendMessage(..., deliverAs: "steer")`, and registers
`ww_send`, `ww_inbox`, `ww_discover`, `ww_canvas_open`, `ww_canvas_publish`
(publish an HTML file from disk), and `ww_log` (see the log tool) for the model.
`ww_canvas_open` creates a canvas, shows its URL to you, and opens it on
macOS (set `WW_OPEN_BROWSER=0` to disable); the model receives only the
endpoint ID, never the canvas token. Mailbox acknowledgement means Pi
accepted the message into its session; completion is a separate response.

The reference adapter prompts the session for `canvas.comment.v1`,
`core.error.v1`, `log.changes_requested.v1`, and anything sent with
`payload.delivery: "immediate"` (e.g. the fleet's `agent.prompt.v1`); it handles
`core.shutdown.v1` itself by leaving the fleet. Comments are accepted only from canvases the session opened
or published to (others get `core.error.v1 {error: "unknown_canvas"}`), and
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
| Message status (sender or recipient) | `GET /v1/messages/:id` |
| History | `GET /v1/endpoints/:id/history` |
| Streaming tail | `GET /v1/endpoints/:id/tail` |
| Acknowledge | `POST /v1/endpoints/:id/ack` |
| Rename (self: `name`, `metadata`) | `PATCH /v1/endpoints/:id` |
| Deregister (self, or admin token) | `DELETE /v1/endpoints/:id` |
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

## Example tool: live canvases

Canvases are one tool built on the mailbox primitives above, not part of the core. Any tool can be built the same way: register an endpoint, accept and emit typed messages.

A canvas is a tool endpoint rendered at `/canvas`. Create one and open the
printed URL; its credentials ride in the URL fragment, which the browser never
sends to the server, and the page moves them into tab storage:

```sh
export WW_ADMIN_TOKEN='<your-local-admin-token>'
./ww canvas --title "Fleet health"
```

### Page mode (HTML reports)

Publish any self-contained HTML page: inline data, Vega-Lite or other CDN scripts,
your own JS. Each publish replaces the page live and bumps its version chip:

```sh
./ww publish --to <canvas-id> --file report.html --watch   # republish on every save
```

Pages run in a sandboxed frame with an opaque origin (`sandbox allow-scripts
allow-popups allow-popups-to-escape-sandbox`): scripts and CDNs work, links may
open ordinary (unsandboxed) tabs, but the page
cannot reach the canvas's token, storage, or the authenticated API. Stream data
into a running page without a reload by sending `canvas.data.v1 {any}`:

```js
addEventListener("waterworks", (event) => update(event.detail));
```

Data sent since the last publish is replayed after a reload. Pages may be up to
16 MB.

Republishing sends a delta when that is less than half the page:
`canvas.delta.v1 {base, ops, title?}`, where `base` is the message ID of the
version it edits and `ops` are line edits that consume the whole base:
`{keep: n}`, `{drop: n}`, `{insert: [lines]}`. `ww publish --watch` diffs with
Myers (one edit to a 3 MB page sent 174 bytes); Pi's `ww_canvas_publish` sends
the changed span. A delta whose base is not the current page is refused: the page
keeps its version, shows "missed an update", and replies `core.error.v1
{error: "delta_base_mismatch"}` to the sender, after which Pi publishes the full
page. Deltas are line-based, so keep large embedded data on many lines, or stream
it with `canvas.data.v1`. Comments on a page carry `context`: the section heading, the visible
text, and the element ids under the region (or your text selection inside the
page).

### Panel mode

Without writing HTML, any endpoint can stream structured panels:

| Type | Payload |
| --- | --- |
| `canvas.render.v1` | `{title, panels}` replaces the page (`{title?, html}` for page mode) |
| `canvas.delta.v1` | page mode: `{base, ops, title?}` edits the current page's lines |
| `canvas.patch.v1` | `{title?, panels?, remove?, append?}`: upsert panels by `id`, remove ids, append `[x, y]` points to line series |
| `canvas.reply.v1` | `{text}` with `reply_to` set to a comment's ID |

Panels are `{id, kind, title, width?}` where `width` spans 1–4 columns and
`kind` is one of `stat {value, unit?, delta?}`, `line {series: [{name, points}]}`,
`bar {bars: [{label, value}]}`, `table {columns, rows}`, or `text {text}`. Line
series keep at most 500 points. Agent content is rendered as text, never HTML.

To give feedback, use **Comment area** to drag a rectangle (or select text
first, or press Enter for the whole canvas), or **Select element** to click
one: hover outlines it, ↑/↓ widen to its parent or narrow back, and a click or
Enter picks what is outlined. On published pages the picker runs inside the
sandboxed frame. The selection stays highlighted while you write; once sent it
remains as a hatched, numbered marker, and element markers follow their element
across republishes, deltas, and relayouts. The page sends
`canvas.comment.v1` to the endpoint that last rendered it:

```json
{"text": "...", "region": {"x": 0.1, "y": 0, "width": 0.3, "height": 0.2},
 "panels": [{"id": "qps", "title": "QPS", "kind": "stat"}],
 "selection": "", "canvas": {"title": "...", "sequence": 7}}
```

`region` is a fraction of the canvas; page-mode comments add
`context: {heading, text, ids, selection}` and `canvas.version`, and picked
elements add `element: {selector, tag, id, classes, text}` (plus `panel` in panel
mode). Replies appear under the comment. The agent removes markers once it has
addressed them with `canvas.clear.v1 {comments: [ids]}` or `{all: true}`
(comments made before the clear); the comment stays in the sidebar as "cleared
by agent". A reload rebuilds the page, clears included, from the endpoint's
mailbox history.

Page controls can call `waterworks.action({...})` (any JSON object up to 64 KB);
the host sends it as `canvas.action.v1` to `to` when given (e.g. a tool streaming
into the page), otherwise to the endpoint that last rendered the page. Like comment fields, treat action payloads as untrusted input.

## Example tool: fleet

`ww fleet` is a tool endpoint (`metadata.tool: "fleet"`) that tracks every
registered agent and tool and streams the list to subscribers whenever it
changes (polled every `--interval` seconds, default 2). It holds a streaming tail
of its own mailbox, so it shows as online and acts on requests immediately. It needs
`WW_ADMIN_TOKEN` and owns no canvas.

- **Standalone view:** it registers a viewer endpoint and opens
  `/fleet#endpoint=…&token=…&fleet=…` (`--no-open` to skip): counts, sorting,
  kind/type/status filters, search, and a light/dark toggle.
- **On a canvas:** to comment on the fleet with an agent, publish the same view
  into a canvas the agent owns and subscribe that canvas. Data streamed into a
  canvas does not change who owns it, so comments still go to the agent:

  ```sh
  ./ww fleet page > fleet.html        # the view as one self-contained page
  # agent: ww_canvas_publish fleet.html to its canvas, then
  # ww_send to the fleet: fleet.subscribe.v1 {"to": "<canvas id>"}
  ```

Messages: `fleet.subscribe.v1 {to?}` (anyone may watch: yourself, or a canvas),
`fleet.unsubscribe.v1 {to?}`, and, only from the user (the fleet's own view or a
canvas subscribed to it), `fleet.remove.v1 {id}` (offline endpoints),
`fleet.disconnect.v1 {id}` (online: deregisters it and closes its socket), and
`fleet.shutdown.v1 {id}` (online: sends it `core.shutdown.v1`). A subscribed canvas
sends the same as `canvas.action.v1 {action, id}`. Anything else, or a request
from someone else, is answered with `core.error.v1`. Subscribers receive `fleet.state.v1` (canvases:
`canvas.data.v1`) with `{fleet, endpoints: [{name, kind, type, status, id, kept}],
broadcasts, updated (UTC ISO 8601)}`; `kept` marks subscribers that "Remove all
offline" leaves alone. Offline rows have Remove; online rows have Shut down and Disconnect (click twice
to confirm). **Remove all offline** in the toolbar (`fleet.remove_offline.v1`) clears
every offline endpoint except the fleet's current subscribers, such as its viewer. Shutting the fleet down from its own row (or anyone sending it
`core.shutdown.v1`) deregisters the fleet and its viewer and exits.

**Broadcast** (standalone view, or the view published into a canvas): tick online agents, type a message, and Send
(or Cmd/Ctrl+Enter). The view sends `fleet.broadcast.v1 {ids, text, broadcast}`;
the fleet sends each online agent `agent.prompt.v1 {text, delivery: "immediate"}`,
so Pi sessions take it as a prompt now, and reports `fleet.broadcast_status.v1
{broadcast, text, sessions: [{id, name, status}]}` (pending, acked, failed) as they
acknowledge, which fills a live receipts modal. The **Broadcasts** tab lists this fleet's recent
broadcasts (the last 50, in memory until the fleet restarts) with their receipts;
click one to reopen its receipts. Through a canvas this relies on
trusting the canvas's pages (a canvas forwards actions from agent-authored HTML);
the fleet is meant for a single user.

`core.shutdown.v1` asks an endpoint to stop; each decides what that means. A Pi
session never exits for a remote message: it deregisters itself and leaves the
fleet (`/reload` rejoins). A canvas deregisters itself and shows "closed". Clients
closed with reason `deregistered` (Disconnect) stop reconnecting.

The Type column reads `metadata.harness` for agents (the Pi adapter sets `pi`)
and `metadata.tool` for tools (canvases set `canvas`); register your own with
`--metadata harness=...` or `--metadata tool=...`.

## Example tool: log

`ww log` is a work log with a review queue. Agents (and you) submit entries;
you approve them, reject them, or ask for changes, which go back to the session
that submitted the entry as a prompt. It needs `WW_ADMIN_TOKEN`, opens its view at
`/log` (`--no-open` to skip), and persists under
`$XDG_STATE_HOME/waterworks/log` (`~/.local/state` by default; `--dir` to
override): entries, every revision, reviews and table metadata in SQLite
(`log.sqlite`), and data tables in DuckDB (`log.duckdb`). Everything is restored
when `ww log` starts again.

An entry has a title, a markdown body, tags, links (`{url, label?, kind: pr |
dashboard | other}`) and optional data tables, each `{name, description?}` plus
one of: `csv` (text with a header row), `parquet` (base64), or `columns` + `rows`
(types BIGINT, DOUBLE, VARCHAR or BOOLEAN, inferred when omitted). DuckDB reads
CSV and Parquet itself and detects their column types; `{name, keep: true}`
carries a table over when a revision changes the table set. The `ww_log` tool
also takes `file: "results.parquet"` (or `.csv`) and reads it where the agent
runs. Statuses: `pending` →
`approved` / `rejected` / `changes_requested` (back to `pending` when revised).
Any edit you make, approved entries included, puts the entry back in the queue.

| Message | From | Answer / effect |
| --- | --- | --- |
| `log.submit.v1 {title, body?, tags?, links?, tables?}` | anyone | `log.receipt.v1 {entry, status}` |
| `log.revise.v1 {entry, …changes}` | the submitting endpoint, while pending or changes requested | `log.receipt.v1` |
| `log.tags.v1 {}` | anyone | `log.tag_list.v1 {tags: [{name, count}]}` |
| `log.query.v1 {status?, tags?, mine?, limit?}` | anyone | `log.entries.v1 {entries}` |
| `log.table.v1 {entry, table, limit?, offset?, order_by?, desc?, format?}` | anyone | `log.table_rows.v1 {columns, rows, total, offset}`, or `{csv}` with `format: "csv"` |
| `log.review.v1 {entry, decision, note?}` | the log view | decision: approve, reject, request_changes, reopen |
| `log.edit.v1 {entry, …changes}` | the log view | new revision, back to pending |

The author receives `log.changes_requested.v1 {entry, note}` (as an immediate
prompt), `log.approved.v1` and `log.rejected.v1`. If the author's session is gone,
the entry is marked so you can edit and approve it yourself. Errors answer
`core.error.v1`. The Pi adapter's `ww_log` tool wraps all of this for agents.

The view has a calendar (click a day for that day's entries, in your time zone),
tag filters, Queue / Changes requested / Approved / Rejected / All tabs, and an
entry modal with links and history. Tables open in a viewer with pages of 100
rows, sorting by any column, and CSV download (downloads may be blocked inside a
canvas; the standalone view allows them). New and Edit take tables too: paste
CSV or choose a CSV or Parquet file. `ww log page` prints it as a
single page to publish into a canvas; a subscribed canvas can review and edit
like the view.

## Tests

```sh
mix test
```

Run the loopback HTTP/WebSocket tests:

```sh
WW_TEST_HTTP=1 mix test --include transport
```

Run everything, including the real two-node test and the headless-Chrome
canvas test (requires Google Chrome; the explicit test cookie means no
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
- Tokens cannot be rotated yet; a leaked endpoint token stays valid until the
  endpoint is deregistered. Every Pi session and canvas adds an endpoint; remove
  dead ones with `ww deregister` or the fleet view.
- Mailbox ownership uses `:global`, which assumes a connected full-mesh cluster;
  OTP may log and resolve a name conflict during concurrent takeover.
- Canvas comments made before a reload persist only in that browser tab.
  Reloads replay the canvas's whole history; deltas keep that small, but
  every full publish of a large page stays in it. A page's scripts can send actions
  (`waterworks.action`) but not comments. The Pi adapter keeps the canvases it
  opened across `/reload`, but forgets them when Pi restarts, after which their
  comments are refused.
  Other harnesses are not implemented.
