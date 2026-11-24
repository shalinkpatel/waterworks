defmodule Ww.Fleet do
  @moduledoc """
  `ww fleet`: a tool endpoint that tracks every registered agent and tool and streams the
  list to subscribers; it can remove, disconnect and shut down endpoints and broadcast
  prompts to agents. It owns no page: its standalone view is `/fleet` (a viewer endpoint it
  registers), and `ww fleet page` is the same view for a canvas. The message protocol is
  in the README ("Example tool: fleet"); `command/5` decides who may do what.
  """

  alias Ww.{CLI, Tool}

  @external_resource Path.expand("../../priv/fleet/index.html", __DIR__)
  @external_resource Path.expand("../../priv/fleet/app.js", __DIR__)
  @html File.read!(Path.expand("../../priv/fleet/index.html", __DIR__))
  @js File.read!(Path.expand("../../priv/fleet/app.js", __DIR__))

  @doc "The fleet view as one self-contained page, for publishing into a canvas."
  def canvas_page,
    do:
      String.replace(
        @html,
        ~s(<script src="/fleet/app.js"></script>),
        "<script>\n#{@js}</script>"
      )

  def run(interval_ms, open?) do
    admin = System.get_env("WW_ADMIN_TOKEN") || raise("WW_ADMIN_TOKEN is required")
    {id, auth} = Tool.register(admin, fleet_endpoint())
    IO.puts(:stderr, "fleet endpoint: #{id}")

    # The standalone view is its own endpoint, so the browser and this process never share a
    # mailbox. It is subscribed up front; the page re-subscribes on every (re)connect.
    {viewer, viewer_auth} = Tool.register(admin, viewer_endpoint())
    url = Tool.view_url("/fleet", viewer, viewer_auth, %{"fleet" => id})
    IO.puts(:stderr, "fleet view: #{url}")
    if open? and match?({:unix, :darwin}, :os.type()), do: System.cmd("open", [url])

    state = %{
      auth: auth,
      admin: admin,
      id: id,
      interval: interval_ms,
      last: nil,
      fresh: [],
      broadcasts: %{},
      viewer: viewer,
      subscribers: %{viewer => "fleet.state.v1"}
    }

    Tool.follow(id, auth)
    loop(state)
  end

  defp fleet_endpoint do
    %{
      kind: "tool",
      name: "fleet",
      accepts: [
        "fleet.subscribe.v1",
        "fleet.unsubscribe.v1",
        "fleet.remove.v1",
        "fleet.disconnect.v1",
        "fleet.shutdown.v1",
        "fleet.remove_offline.v1",
        "fleet.broadcast.v1",
        "canvas.action.v1",
        "core.shutdown.v1"
      ],
      emits: [
        "fleet.state.v1",
        "fleet.broadcast_status.v1",
        "canvas.data.v1",
        "core.shutdown.v1",
        "agent.prompt.v1"
      ],
      metadata: %{tool: "fleet"}
    }
  end

  defp viewer_endpoint do
    %{
      kind: "tool",
      name: "fleet view",
      accepts: ["fleet.state.v1", "fleet.broadcast_status.v1", "core.shutdown.v1"],
      emits: [
        "fleet.subscribe.v1",
        "fleet.remove.v1",
        "fleet.remove_offline.v1",
        "fleet.broadcast.v1",
        "fleet.disconnect.v1",
        "fleet.shutdown.v1"
      ],
      metadata: %{tool: "fleet-view"}
    }
  end

  # The tail makes the fleet "online" and delivers requests as they arrive; discovery is
  # polled every interval because endpoint changes are not pushed to anyone.
  defp loop(state) do
    state = poll(state)
    wait(state, System.monotonic_time(:millisecond) + state.interval)
  end

  defp wait(state, deadline) do
    receive do
      {:tool_message, message} -> state |> handle_message(message) |> wait(deadline)
      :tool_deregistered -> exit_deregistered()
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> loop(state)
    end
  end

  # Sends the list to everyone when it changed, and to new subscribers regardless.
  defp poll(state) do
    state = refresh_broadcasts(state)
    endpoints = endpoints(state)
    rows = rows(endpoints, state.subscribers)
    history = history(state.broadcasts)
    current = {rows, history}
    targets = if current != state.last, do: Map.keys(state.subscribers), else: state.fresh

    payload = %{
      fleet: state.id,
      endpoints: rows,
      broadcasts: history,
      # UTC ISO 8601; each view shows it in its own local time zone.
      updated: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    state = Enum.reduce(Enum.uniq(targets), state, &deliver(&2, &1, payload))
    %{state | last: current, fresh: []}
  end

  defp exit_deregistered do
    IO.puts(:stderr, "fleet was disconnected; exiting")
    System.halt(0)
  end

  # Someone disconnected the fleet itself: its token is gone, so exit instead of crashing.
  defp endpoints(state) do
    CLI.request(:get, "/v1/endpoints", nil, state.auth, false)["endpoints"]
  rescue
    error ->
      if Exception.message(error) =~ "HTTP 401",
        do: exit_deregistered(),
        else: reraise(error, __STACKTRACE__)
  end

  # A subscriber that was deregistered (404) is dropped instead of crashing the loop.
  defp deliver(state, to, payload) do
    CLI.request(
      :post,
      "/v1/messages",
      %{to: to, type: state.subscribers[to], payload: payload},
      state.auth,
      false
    )

    state
  rescue
    error ->
      IO.puts(:stderr, "dropping subscriber #{to}: #{Exception.message(error)}")
      %{state | subscribers: Map.delete(state.subscribers, to)}
  end

  # Decided against a fresh listing, so "online"/"offline" reflects the moment of the click.
  defp handle_message(state, message) do
    case command(message, state.subscribers, endpoints(state), state.id, state.viewer) do
      {:subscribe, to, type} ->
        poll(%{put_in(state.subscribers[to], type) | fresh: [to | state.fresh]})

      {:unsubscribe, to} ->
        %{state | subscribers: Map.delete(state.subscribers, to)}

      {:remove, id} ->
        if remove(state, id), do: poll(state), else: state

      {:remove_all, ids} ->
        removed = Enum.count(ids, &remove(state, &1))
        IO.puts(:stderr, "removed #{removed} offline endpoint(s)")

        # Always answer the requester, so its "Removing…" state clears even if nothing was removed.
        poll(%{state | fresh: [message["from"] | state.fresh]})

      {:shutdown, id} ->
        request_shutdown(state, id, message["from"])
        state

      {:broadcast, ids, text} ->
        state |> broadcast(message, ids, text) |> poll()

      :exit ->
        exit_fleet(state, message["from"])

      :ignore ->
        state
    end
  end

  # delivery: "immediate" makes a Pi session take it as a prompt now (queued types wait).
  # Each send is tracked so the view can show which sessions acknowledged it; the broadcast id
  # is the request's message id, which the page chose and uses to match status updates.
  defp broadcast(state, request, ids, text) do
    names = Map.new(endpoints(state), &{&1["id"], &1["name"]})

    sessions =
      for id <- ids do
        message_id = "#{broadcast_id(request)}.#{id}"
        payload = %{text: text, delivery: "immediate"}
        body = %{id: message_id, to: id, type: "agent.prompt.v1", payload: payload}

        status =
          try do
            CLI.request(:post, "/v1/messages", body, state.auth, false)
            "pending"
          rescue
            error ->
              IO.puts(:stderr, "broadcast to #{id} failed: #{Exception.message(error)}")
              "failed"
          end

        %{id: id, name: names[id] || id, message_id: message_id, status: status}
      end

    IO.puts(:stderr, "broadcast to #{length(ids)} agent(s)")

    tracked = %{
      id: broadcast_id(request),
      to: request["from"],
      text: text,
      sessions: sessions,
      started: System.monotonic_time(:second),
      sent_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    report_broadcast(state, tracked)
    put_in(state.broadcasts[tracked.id], tracked)
  end

  # Broadcasts are kept in memory (the last 50) for the view's Broadcasts tab; they are gone
  # when the fleet restarts. Pending receipts are re-checked for 10 minutes.
  defp refresh_broadcasts(state) do
    broadcasts =
      state.broadcasts
      |> Enum.sort_by(fn {_id, b} -> -b.started end)
      |> Enum.take(50)
      |> Map.new(fn {id, b} ->
        if System.monotonic_time(:second) - b.started < 600 and
             Enum.any?(b.sessions, &(&1.status == "pending")) do
          sessions = Enum.map(b.sessions, &refresh_session(state, &1))
          updated = %{b | sessions: sessions}
          if sessions != b.sessions, do: report_broadcast(state, updated)
          {id, updated}
        else
          {id, b}
        end
      end)

    %{state | broadcasts: broadcasts}
  end

  @doc "Broadcast history for views, newest first."
  def history(broadcasts) do
    broadcasts
    |> Map.values()
    |> Enum.sort_by(&(-&1.started))
    |> Enum.map(fn b ->
      %{
        broadcast: b.id,
        text: b.text,
        sent_at: b.sent_at,
        sessions: Enum.map(b.sessions, &Map.take(&1, [:id, :name, :status]))
      }
    end)
  end

  defp refresh_session(state, %{status: "pending"} = session) do
    path = "/v1/messages/#{URI.encode(session.message_id)}"

    case CLI.request(:get, path, nil, state.auth, false) do
      %{"status" => "acked"} -> %{session | status: "acked"}
      _ -> session
    end
  rescue
    # Deregistered recipients take their messages with them.
    _ -> %{session | status: "failed"}
  end

  defp refresh_session(_state, session), do: session

  defp report_broadcast(state, b) do
    payload = %{
      broadcast: b.id,
      text: b.text,
      sessions: Enum.map(b.sessions, &Map.take(&1, [:id, :name, :status]))
    }

    # Canvases only take canvas.* types, so their receipts ride on canvas.data.v1.
    body =
      if state.subscribers[b.to] == "canvas.data.v1",
        do: %{to: b.to, type: "canvas.data.v1", payload: %{broadcast_status: payload}},
        else: %{to: b.to, type: "fleet.broadcast_status.v1", payload: payload}

    CLI.request(:post, "/v1/messages", body, state.auth, false)
  rescue
    _ -> :ok
  end

  # The page names its broadcast so it can match receipts; through a canvas the request's
  # message id is chosen by the canvas host, so the page passes payload.broadcast instead.
  defp broadcast_id(request) do
    case request["payload"]["broadcast"] do
      id when is_binary(id) and byte_size(id) in 1..100 -> id
      _ -> request["id"]
    end
  end

  defp request_shutdown(state, id, requested_by) do
    body = %{to: id, type: "core.shutdown.v1", payload: %{requested_by: requested_by}}
    CLI.request(:post, "/v1/messages", body, state.auth, false)
    IO.puts(:stderr, "asked #{id} to shut down")
  rescue
    error -> IO.puts(:stderr, "could not ask #{id} to shut down: #{Exception.message(error)}")
  end

  # Leaves no stale endpoints behind: the viewer, then the fleet itself.
  defp exit_fleet(state, requested_by) do
    for id <- [state.viewer, state.id], do: remove(state, id)
    IO.puts(:stderr, "fleet shut down by #{requested_by}")
    System.halt(0)
  end

  defp remove(state, id) do
    CLI.request(:delete, "/v1/endpoints/#{id}", nil, [{"x-ww-admin-token", state.admin}], false)
    IO.puts(:stderr, "removed #{id}")
    true
  rescue
    # A double click or another fleet may have removed it already.
    error ->
      IO.puts(:stderr, "could not remove #{id}: #{Exception.message(error)}")
      false
  end

  @actions %{
    "fleet.remove.v1" => "remove",
    "fleet.disconnect.v1" => "disconnect",
    "fleet.shutdown.v1" => "shutdown",
    "fleet.remove_offline.v1" => "remove_offline",
    "canvas.action.v1" => nil
  }

  @doc """
  Decides what an incoming message asks for. Message content is untrusted: only subscribers may
  act, only on endpoints that exist; remove needs it offline, disconnect and shutdown need it
  online, and the fleet never removes itself (it only exits on a shutdown). A sender
  may subscribe itself or a canvas, but not other kinds of endpoint.
  """
  def command(
        %{"type" => type, "from" => from} = message,
        subscribers,
        endpoints,
        self_id,
        viewer \\ nil
      ) do
    payload = message["payload"] || %{}
    target = payload["to"] || from

    case type do
      # From the fleet's own view, or as a canvas action from a subscribed canvas. Canvases
      # relay actions from agent-authored pages; accepted because the fleet is single-user.
      type
      when type == "fleet.broadcast.v1" or
             (type == "canvas.action.v1" and is_map_key(payload, "action") and
                :erlang.map_get("action", payload) == "broadcast") ->
        text = payload["text"]
        ids = if is_list(payload["ids"]), do: payload["ids"], else: []

        online_agents =
          for e <- endpoints,
              e["kind"] == "agent",
              e["online"] == true,
              into: MapSet.new(),
              do: e["id"]

        targets = Enum.filter(ids, &MapSet.member?(online_agents, &1)) |> Enum.uniq()

        allowed? =
          if type == "fleet.broadcast.v1",
            do: from == viewer and viewer != nil,
            else: subscribers[from] == "canvas.data.v1"

        if allowed? and is_binary(text) and String.trim(text) != "" and
             String.length(text) <= 10_000 and targets != [],
           do: {:broadcast, targets, text},
           else: :ignore

      "fleet.subscribe.v1" ->
        case Enum.find(endpoints, &(&1["id"] == target)) do
          %{"accepts" => accepts} ->
            cond do
              "canvas.data.v1" in accepts -> {:subscribe, target, "canvas.data.v1"}
              target == from -> {:subscribe, target, "fleet.state.v1"}
              true -> :ignore
            end

          nil ->
            :ignore
        end

      "fleet.unsubscribe.v1" ->
        {:unsubscribe, target}

      "core.shutdown.v1" ->
        :exit

      type when is_map_key(@actions, type) ->
        action = if type == "canvas.action.v1", do: payload["action"], else: @actions[type]
        id = payload["id"]
        target = Enum.find(endpoints, &(&1["id"] == id))

        cond do
          not Map.has_key?(subscribers, from) -> :ignore
          # Every offline endpoint except current subscribers (e.g. the fleet's own viewer,
          # which stays reopenable after its tab closes).
          action == "remove_offline" -> {:remove_all, offline_ids(endpoints, subscribers)}
          is_nil(target) -> :ignore
          # Shutting the fleet down from its own view is allowed; removing it is not.
          action == "shutdown" and id == self_id -> :exit
          id == self_id -> :ignore
          action == "remove" and target["online"] == false -> {:remove, id}
          action == "disconnect" and target["online"] == true -> {:remove, id}
          action == "shutdown" and target["online"] == true -> {:shutdown, id}
          true -> :ignore
        end

      _ ->
        :ignore
    end
  end

  defp offline_ids(endpoints, subscribers),
    do:
      for(
        e <- endpoints,
        e["online"] == false,
        not Map.has_key?(subscribers, e["id"]),
        do: e["id"]
      )

  @doc "Page rows for every endpoint, in a stable order."
  def rows(endpoints, subscribers \\ %{}) do
    endpoints
    |> Enum.map(fn e ->
      %{
        name: e["name"],
        kind: e["kind"],
        type: type(e),
        status: if(e["online"], do: "online", else: "offline"),
        id: e["id"],
        # Subscribers (e.g. this fleet's viewer) are never cleared by "Remove all offline".
        kept: Map.has_key?(subscribers, e["id"])
      }
    end)
    |> Enum.sort_by(& &1.id)
  end

  # Agents name their harness in metadata.harness, tools their tool in metadata.tool.
  defp type(%{"kind" => "agent"} = e), do: get_in(e, ["metadata", "harness"]) || "unknown"
  defp type(e), do: get_in(e, ["metadata", "tool"]) || "unknown"
end
