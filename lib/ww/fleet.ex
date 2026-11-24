defmodule Ww.Fleet do
  @moduledoc """
  `ww fleet`: a tool endpoint that tracks every registered agent and tool and streams the
  list to subscribers; it can remove, disconnect and shut down endpoints and broadcast
  prompts to agents. It owns no page: its standalone view is `/fleet` (a viewer endpoint it
  registers), and `ww fleet page` is the same view for a canvas. The message protocol is
  in the README ("Example tool: fleet"); `command/2` decides who may do what.
  """

  alias Ww.Tool

  @actions ~w(remove disconnect shutdown remove_offline broadcast)

  @doc "The fleet view as one self-contained page, for publishing into a canvas."
  def canvas_page, do: Tool.canvas_page("/fleet")

  @doc "Runs until the fleet is shut down or deregistered."
  def run(interval_ms, open?) do
    %{admin: admin, tool: tool, viewer: viewer} =
      Tool.start("fleet", fleet_endpoint(), viewer_endpoint(), open?)

    state = %{
      headers: tool.headers,
      admin: admin,
      id: tool.id,
      interval: interval_ms,
      last: nil,
      fresh: [],
      broadcasts: %{},
      viewer: viewer.id,
      subscribers: %{viewer.id => "fleet.state.v1"}
    }

    Tool.follow(tool)
    loop(state)
  catch
    {:stop, reason} -> IO.puts(:stderr, "fleet #{reason}; exiting")
  end

  defp fleet_endpoint do
    %{
      kind: "tool",
      name: "fleet",
      accepts: ~w(fleet.subscribe.v1 fleet.unsubscribe.v1 fleet.remove.v1 fleet.disconnect.v1
           fleet.shutdown.v1 fleet.remove_offline.v1 fleet.broadcast.v1 canvas.action.v1
           core.shutdown.v1),
      emits: ~w(fleet.state.v1 fleet.broadcast_status.v1 canvas.data.v1 core.shutdown.v1
           agent.prompt.v1 core.error.v1),
      metadata: %{tool: "fleet"}
    }
  end

  defp viewer_endpoint do
    %{
      kind: "tool",
      name: "fleet view",
      accepts: ~w(fleet.state.v1 fleet.broadcast_status.v1 core.shutdown.v1 core.error.v1),
      emits: ~w(fleet.subscribe.v1 fleet.remove.v1 fleet.remove_offline.v1 fleet.broadcast.v1
           fleet.disconnect.v1 fleet.shutdown.v1),
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
      :tool_deregistered -> throw({:stop, "was disconnected"})
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
    payload = %{fleet: state.id, endpoints: rows, broadcasts: history, updated: Tool.now()}
    dropped = Tool.push(state.headers, Map.take(state.subscribers, targets), payload)
    %{state | last: current, fresh: [], subscribers: Map.drop(state.subscribers, dropped)}
  end

  # Someone disconnected the fleet itself: its token is gone, so stop instead of crashing.
  defp endpoints(state) do
    Tool.request(:get, "/v1/endpoints", nil, state.headers)["endpoints"]
  rescue
    error in Tool.HTTPError ->
      if error.status == 401,
        do: throw({:stop, "was disconnected"}),
        else: reraise(error, __STACKTRACE__)
  end

  # Decided against a fresh listing, so "online"/"offline" reflects the moment of the click.
  defp handle_message(state, message) do
    endpoints = endpoints(state)

    case command(message, Map.put(state, :endpoints, endpoints)) do
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
        state |> broadcast(message, ids, text, endpoints) |> poll()

      :exit ->
        exit_fleet(state, message["from"])

      {:error, reason} ->
        Tool.reply(state.headers, state.subscribers, message, "core.error.v1", %{error: reason})
        state
    end
  end

  # delivery: "immediate" makes a Pi session take it as a prompt now (queued types wait).
  # Each send is tracked so the view can show which sessions acknowledged it.
  defp broadcast(state, request, ids, text, endpoints) do
    names = Map.new(endpoints, &{&1["id"], &1["name"]})
    id = broadcast_id(request)

    sessions =
      for agent <- ids do
        message_id = "#{id}.#{agent}"
        payload = %{text: text, delivery: "immediate"}

        status =
          try do
            Tool.send_message(state.headers, agent, "agent.prompt.v1", payload, %{id: message_id})
            "pending"
          rescue
            error ->
              IO.puts(:stderr, "broadcast to #{agent} failed: #{Exception.message(error)}")
              "failed"
          end

        %{id: agent, name: names[agent] || agent, message_id: message_id, status: status}
      end

    IO.puts(:stderr, "broadcast to #{length(ids)} agent(s)")

    tracked = %{
      id: id,
      to: request["from"],
      text: text,
      sessions: sessions,
      started: System.monotonic_time(:second),
      sent_at: Tool.now()
    }

    report_broadcast(state, tracked)
    put_in(state.broadcasts[id], tracked)
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
        sessions: Enum.map(b.sessions, &receipt/1)
      }
    end)
  end

  defp receipt(session), do: Map.take(session, [:id, :name, :status])

  defp refresh_session(state, %{status: "pending"} = session) do
    path = "/v1/messages/#{URI.encode(session.message_id)}"

    case Tool.request(:get, path, nil, state.headers) do
      %{"status" => "acked"} -> %{session | status: "acked"}
      _ -> session
    end
  rescue
    # Deregistered recipients take their messages with them.
    _ -> %{session | status: "failed"}
  end

  defp refresh_session(_state, session), do: session

  defp report_broadcast(state, b) do
    payload = %{broadcast: b.id, text: b.text, sessions: Enum.map(b.sessions, &receipt/1)}
    Tool.send_to(state.headers, state.subscribers, b.to, "fleet.broadcast_status.v1", payload)
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
    Tool.send_message(state.headers, id, "core.shutdown.v1", %{requested_by: requested_by})
    IO.puts(:stderr, "asked #{id} to shut down")
  rescue
    error -> IO.puts(:stderr, "could not ask #{id} to shut down: #{Exception.message(error)}")
  end

  # Leaves no stale endpoints behind: the viewer, then the fleet itself.
  defp exit_fleet(state, requested_by) do
    for id <- [state.viewer, state.id], do: remove(state, id)
    throw({:stop, "shut down by #{requested_by}"})
  end

  defp remove(state, id) do
    Tool.request(:delete, "/v1/endpoints/#{id}", nil, [{"x-ww-admin-token", state.admin}])
    IO.puts(:stderr, "removed #{id}")
    true
  rescue
    # A double click or another fleet may have removed it already.
    error ->
      IO.puts(:stderr, "could not remove #{id}: #{Exception.message(error)}")
      false
  end

  @doc """
  Decides what an incoming message asks for, given `%{subscribers, endpoints, id, viewer,
  headers}`. Message content is untrusted. Anyone may watch (subscribe itself or a canvas)
  and anyone may ask the fleet itself to stop (`core.shutdown.v1`); only the user (the fleet's
  own view or a subscribed canvas) may act on endpoints or broadcast. Remove needs the target
  offline, disconnect and shutdown need it online, and the fleet never removes itself.
  """
  def command(%{"from" => from} = message, ctx) do
    {type, payload} = Tool.unwrap(message, "fleet", @actions)
    user? = Tool.user?(ctx.viewer, ctx.subscribers, from)

    case type do
      "fleet.subscribe.v1" ->
        with {:ok, target, type} <-
               Tool.subscription(ctx.headers, from, payload, "fleet.state.v1"),
             do: {:subscribe, target, type}

      "fleet.unsubscribe.v1" ->
        target = payload["to"] || from

        if target == from or user?,
          do: {:unsubscribe, target},
          else: {:error, "can only unsubscribe yourself"}

      "core.shutdown.v1" ->
        :exit

      "fleet." <> _ when not user? ->
        {:error, "only the fleet view (or a canvas it streams to) can do that"}

      "fleet.broadcast.v1" ->
        broadcast_command(payload, ctx.endpoints)

      "fleet.remove_offline.v1" ->
        {:remove_all, offline_ids(ctx.endpoints, ctx.subscribers)}

      "fleet." <> rest ->
        endpoint_command(String.replace_suffix(rest, ".v1", ""), payload["id"], ctx)

      _ ->
        {:error, "unsupported: #{type}"}
    end
  end

  defp broadcast_command(payload, endpoints) do
    text = payload["text"]
    ids = if is_list(payload["ids"]), do: payload["ids"], else: []

    online_agents =
      for e <- endpoints, e["kind"] == "agent", e["online"], into: MapSet.new(), do: e["id"]

    targets = ids |> Enum.filter(&MapSet.member?(online_agents, &1)) |> Enum.uniq()

    cond do
      not is_binary(text) or String.trim(text) == "" or String.length(text) > 10_000 ->
        {:error, "a broadcast needs 1-10000 characters of text"}

      targets == [] ->
        {:error, "none of those agents is online"}

      true ->
        {:broadcast, targets, text}
    end
  end

  defp endpoint_command(action, id, ctx) do
    target = Enum.find(ctx.endpoints, &(&1["id"] == id))

    cond do
      action not in ~w(remove disconnect shutdown) ->
        {:error, "unsupported: fleet.#{action}.v1"}

      is_nil(target) ->
        {:error, "no endpoint #{inspect(id)}"}

      # Shutting the fleet down from its own view is allowed; removing it is not.
      action == "shutdown" and id == ctx.id ->
        :exit

      id == ctx.id ->
        {:error, "the fleet cannot remove itself; shut it down instead"}

      action == "remove" and not target["online"] ->
        {:remove, id}

      action == "disconnect" and target["online"] ->
        {:remove, id}

      action == "shutdown" and target["online"] ->
        {:shutdown, id}

      true ->
        {:error,
         "cannot #{action} an endpoint that is #{if target["online"], do: "online", else: "offline"}"}
    end
  end

  defp offline_ids(endpoints, subscribers),
    do: for(e <- endpoints, !e["online"], not Map.has_key?(subscribers, e["id"]), do: e["id"])

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
