# Waterworks v0.1

Waterworks (`ww`) connects agent and tool instances with crash-durable, typed mailboxes.
The first implementation is a trusted-network Elixir/OTP daemon and CLI with
HTTP, streaming HTTP, and WebSocket transports. It includes a fixed browser/CLI
echo demo and a reference Pi adapter, but does not host arbitrary web tools or
implement other harness adapters.

## Scope and non-goals

- One mailbox per running agent or tool endpoint instance.
- Direct endpoint addressing after discovery; no topics or load balancing.
- At-least-once delivery and per-mailbox ordering while the cluster is connected,
  never exactly-once delivery.
- Multiple Elixir nodes on one trusted network using Erlang distribution.
- Endpoint and message recovery after daemon/node process crashes using replicated
  Mnesia tables; recent commits are not guaranteed to survive machine power loss.
- JSON is the external representation; Elixir structs are used inside the daemon.
- Browser/WebSocket transport, Pi integration, and MCP are adapters, not core.
- Clustering does not provide consensus or safe automatic recovery from network
  partitions. Nodes must use a shared secret Erlang cookie on a trusted network.

## Endpoints and discovery

An endpoint registration contains:

- `id`: unique, random endpoint instance identifier; stable across reconnects.
- `kind`: `agent` or `tool`; used for discovery, not routing behavior.
- `name`: human-readable label.
- `accepts` and `emits`: lists of versioned message type names.
- `metadata`: string-keyed JSON object, for example a workspace path.
- `token_hash`: hash of the endpoint's scoped token; never returned by discovery.

A new agent session or tool instance normally registers a new ID. Its adapter
reuses that ID and token when reconnecting. Registration requires the admin token supplied through the daemon environment.
Discovery and inspection require a valid endpoint token. Sending as an endpoint
requires that endpoint's token. The server derives `from` from this identity.
Tokens are stored only as SHA-256 hashes and compared in constant time. HTTP
requests are authenticated before their bodies are read; streaming transports
(WebSocket, tail) authenticate once at connect and keep only the endpoint ID,
acting through `Ww.send_as/5`, `Ww.subscribe_as/2`, and `Ww.acknowledge_as/2`.
A Host-header check rejects requests that do not name this daemon, blocking DNS
rebinding from web pages; there are no cookies or CORS headers, so other pages
cannot make authenticated requests.

Discovery returns descriptors without credentials and can filter by `kind`,
`name`, `accepts`, and exact metadata values. Online status means at least one
live subscriber process for the endpoint in the cluster's `:pg` membership.
Process death removes live membership automatically. Offline endpoints remain
discoverable and can receive queued messages.

## Message envelope

```json
{
  "v": 1,
  "id": "01K8M4...",
  "from": "ep_agent_...",
  "to": "ep_tool_...",
  "type": "ui.button_clicked.v1",
  "payload": {"button": "deploy"},
  "reply_to": null,
  "received_at": "2026-11-20T20:00:00.000Z",
  "sequence": 42
}
```

The sender supplies a unique ID, recipient, versioned type, JSON object payload,
and optional `reply_to`. The daemon authenticates `from`, assigns receive time,
and assigns a monotonically increasing sequence in the recipient's mailbox.
The core validates only the envelope. Endpoint adapters validate their payload
contracts. Unknown fields and payload types are not interpreted by the router.

Control operations are `register`, `discover`, `send`, `subscribe`, `ack`,
`inspect`, and `history`. The CLI uses the public HTTP API; streaming HTTP tails
provide newline-delimited JSON and heartbeat frames. WebSockets accept `send`,
`ack`, and `ping` operations and deliver messages as JSON. Browser sockets pass
their scoped token in the subprotocol handshake rather than the URL. Native
Elixir adapters use the same public API without changing the message model.

## Delivery semantics

1. Validate the sender, recipient, envelope, and configured size limits.
2. In one Mnesia transaction, increment the recipient sequence and commit the
   message as pending. Only then report acceptance to the sender. A Mnesia
   transaction commit is not an fsync: it supports process/node crash recovery,
   but an OS crash or power loss can still lose recent writes.
3. Notify the recipient's live mailbox through its `:global` registration. `:pg`
   separately tracks subscriber presence. With no live mailbox, the committed
   pending record is sufficient.
4. A subscriber receives pending messages in sequence order. A process that
   disconnects before acknowledgement will receive the message again after
   reconnecting. Receivers must use message IDs to make application idempotent.
5. Acknowledgement marks the message applied. It does not mean an LLM finished
   working. Completion and errors are separate typed messages linked with
   `reply_to`.

Each mailbox has one active subscriber generation. A newer connection replaces
notification delivery for the older one. Presence membership is registered by
the local adapter process; process death or heartbeat-detected disconnect
removes it. There is no ordering guarantee across mailboxes. Tables are
replicated so another node can queue and read messages when the endpoint
reconnects there. During a network partition, both sides can allocate the same
mailbox sequence or accept conflicting writes; ordering is guaranteed only while
the relevant replicas remain connected.

## Live dashboards

A dashboard is an ordinary tool endpoint whose page is served at `/dashboard`.
Its state is a pure fold over its mailbox (`priv/dashboard/core.js`):
`dashboard.render.v1` replaces it, `dashboard.patch.v1` upserts, removes, and
appends points, and `dashboard.reply.v1` attaches replies to comments. Messages
at or below the last applied sequence are skipped, so replaying history and then
streaming pending messages over the socket yields each message once; this is
how a reload rebuilds the page. Region comments are sent as
`dashboard.comment.v1` to the endpoint that last rendered or patched the page,
with the region as dashboard fractions and the overlapping panels. Because the
page holds the dashboard token, panel content is rendered only as text and SVG
attributes, and the token stays in the URL fragment and tab storage.

Page mode (`dashboard.render.v1 {html}`) runs agent-authored HTML, such as
rich reports, in an iframe loaded from `/dashboard/frame`, which is served
with a `sandbox allow-scripts allow-popups allow-popups-to-escape-sandbox` CSP
and has the `sandbox` attribute (popups it opens, such as links in new tabs, are
ordinary pages with no access to the dashboard's token),
so the page has an opaque origin and cannot read the host document, its storage,
or call the authenticated API. The host posts the HTML to the frame's loader,
which writes it and appends `helper.js`. The helper reports the page height (the
frame is sized to its content so region coordinates stay stable), delivers
`dashboard.data.v1` payloads as `waterworks` events, and answers region
inspections with the heading, text, and ids under a rectangle or the page's
text selection. Each render creates a new frame; data since the last render is
replayed into it in sequence order.

Comments are anchored to an area or a picked element. In page mode the helper
runs the element picker inside the frame (hover outline, ArrowUp/ArrowDown to
widen or narrow, click or Enter to pick, keys forwarded by the host) and
describes the element with a CSS path: its id, or `tag:nth-of-type` steps.
Comments live in the browser tab; element comments store that selector, and the
host asks the frame to locate it again whenever the page renders or resizes, so
markers follow their elements. `dashboard.clear.v1` removes markers by comment
ID or all made before the clear; like everything else it is replayed from
history.

`dashboard.delta.v1 {base, ops}` publishes a new page version as line edits.
The page state tracks `revision`, the message ID of the current page; a delta
applies only if `base` equals it and its ops consume the whole base, so a delta
can never silently corrupt a page. Otherwise the page keeps its version and the
host replies `core.error.v1 {error: "delta_base_mismatch", base, expected}` to
the sender, with an ID derived from the delta so history replays do not repeat
it. Publishers diff against their own last publish; one publisher per dashboard
is the expected case, and a mismatch is the signal to send a full page. The
router still treats deltas as opaque payloads.

## Pi adapter

`.pi/extensions/waterworks.js` registers one agent endpoint per Pi session or
uses endpoint credentials supplied by the environment. Credentials are kept in
memory, never added to the transcript. The socket reconnects with the same
endpoint identity. Supported messages are injected with `pi.sendMessage()` using
`steer` delivery and acknowledged after Pi accepts them into the session;
acknowledgement does not mean the model finished working. Only dashboard
comments, errors, echoes, and messages with `payload.delivery: "immediate"` do
this; every other message stays unacknowledged in an in-session inbox (so a
restart redelivers it) until the model calls `ww_inbox`, which returns and
acknowledges them. The footer shows the queued count. Dashboard comments are
accepted only from dashboards the session opened or published to (others get
`core.error.v1 {error: "unknown_dashboard"}`), and page-derived comment fields are
presented to the model as untrusted data. The model sends structured
replies through the extension's `ww_send` tool and discovers peers through
`ww_discover`.

## OTP and distribution

The application supervision tree contains a cluster-scoped `:pg` process and a
`DynamicSupervisor` for mailbox processes. `Ww.Store` owns Mnesia operations;
`Ww.Mailbox` owns live subscriptions; `Ww` is the small public API. Mailbox
processes use `:global` names, which assume a connected full-mesh cluster;
concurrent cross-node takeover can make OTP log and resolve a name conflict.

Before application startup, the first node creates a disk-backed Mnesia schema
and replicated table definitions. A joining node connects to an existing node,
obtains the remote schema through `extra_db_nodes`, changes its schema to disk
copies, and adds local disk copies of the Waterworks tables. Nodes use long names
when connecting across hosts. The shared cookie lives in `~/.erlang.cookie`
(mode 0400) on each host; Waterworks never creates it or writes it anywhere.

Mnesia and Erlang distribution do not make a partitioned cluster linearizable.
Without majority checks, both sides can accept writes. Mnesia does not
automatically merge diverged replicas after reconnect: an operator must choose
the authoritative side and restart/resynchronize the losers. Every admitted
node is fully trusted and can read or modify all Waterworks data. Waterworks
v0.1 therefore targets a small, trusted, connected cluster, not Byzantine nodes
or WAN consensus.

The `disc_copies` tables retain all history in RAM as well as on disk. Retention,
large-payload storage, automatic partition recovery, and stronger ownership are
intentionally deferred until actual operating requirements justify them.

## Evolution

Message types carry independent versions. Envelope changes require a new envelope
version. Additive registration metadata is preferred over new routing concepts.
Broadcast, schema registries, retention policies, remote untrusted transport, and
multi-writer conflict resolution remain deliberately out of scope.
