defmodule Ww.Fleet do
  @moduledoc """
  `ww fleet`: a tool endpoint that tracks every registered agent and tool and streams the
  list to subscribers. It owns no page. Its standalone view is `/fleet` (served by the
  daemon, opened with a viewer endpoint `ww fleet` registers); to comment on it with an
  agent, publish `ww fleet page` into a canvas and subscribe that canvas.

  Messages it accepts:
    * `fleet.subscribe.v1 {to?}`: stream state to the sender, or to the canvas `to`.
      Canvases receive `canvas.data.v1`; anything else receives `fleet.state.v1`.
    * `fleet.unsubscribe.v1 {to?}`
    * `fleet.remove.v1 {id}` (offline endpoints) and `fleet.disconnect.v1 {id}` (online
      ones) from a subscriber: deregisters the endpoint; a connected one is disconnected.
    * `fleet.shutdown.v1 {id}` from a subscriber: sends `core.shutdown.v1` to an online
      endpoint, asking it to stop (each endpoint decides what that means).
    * Canvases send the same as `canvas.action.v1 {action: "remove" | "disconnect" |
      "shutdown", id}`.
    * `core.shutdown.v1`: the fleet deregisters itself and its viewer and exits.

  State: `{fleet, endpoints: [{name, kind, type, status, id, cwd}], updated}`.
  """

  alias Ww.CLI

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
    {id, token} = register(admin, fleet_endpoint())
    auth = [{"x-ww-endpoint", id}, {"authorization", "Bearer #{token}"}]
    IO.puts(:stderr, "fleet endpoint: #{id}")

    # The standalone view is its own endpoint, so the browser and this process never share a
    # mailbox. It is subscribed up front; the page re-subscribes on every (re)connect.
    {viewer, viewer_token} = register(admin, viewer_endpoint())
    query = URI.encode_query(%{"endpoint" => viewer, "token" => viewer_token, "fleet" => id})
    url = CLI.base_url() <> "/fleet#" <> query
    IO.puts(:stderr, "fleet view: #{url}")
    if open? and match?({:unix, :darwin}, :os.type()), do: System.cmd("open", [url])

    state = %{
      auth: auth,
      admin: admin,
      id: id,
      interval: interval_ms,
      last: nil,
      fresh: [],
      viewer: viewer,
      subscribers: %{viewer => "fleet.state.v1"}
    }

    parent = self()
    spawn_link(fn -> tail(parent, %{id: id, headers: auth}) end)
    loop(state)
  end

  defp register(admin, body) do
    %{"endpoint" => %{"id" => id}, "token" => token} =
      CLI.request(:post, "/v1/endpoints", body, [{"x-ww-admin-token", admin}], false)

    {id, token}
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
        "canvas.action.v1",
        "core.shutdown.v1"
      ],
      emits: ["fleet.state.v1", "canvas.data.v1", "core.shutdown.v1"],
      metadata: %{tool: "fleet"}
    }
  end

  defp viewer_endpoint do
    %{
      kind: "tool",
      name: "fleet view",
      accepts: ["fleet.state.v1", "core.shutdown.v1"],
      emits: ["fleet.subscribe.v1", "fleet.remove.v1", "fleet.disconnect.v1", "fleet.shutdown.v1"],
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
      {:fleet_message, message} -> state |> handle_message(message) |> wait(deadline)
      :fleet_deregistered -> exit_deregistered()
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> loop(state)
    end
  end

  # Sends the list to everyone when it changed, and to new subscribers regardless.
  defp poll(state) do
    endpoints = endpoints(state)
    current = rows(endpoints)
    targets = if current != state.last, do: Map.keys(state.subscribers), else: state.fresh

    payload = %{
      fleet: state.id,
      endpoints: current,
      updated:
        "updated " <> (DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601())
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
    case command(message, state.subscribers, endpoints(state), state.id) do
      {:subscribe, to, type} ->
        poll(%{put_in(state.subscribers[to], type) | fresh: [to | state.fresh]})

      {:unsubscribe, to} ->
        %{state | subscribers: Map.delete(state.subscribers, to)}

      {:remove, id} ->
        if remove(state, id), do: poll(state), else: state

      {:shutdown, id} ->
        request_shutdown(state, id, message["from"])
        state

      :exit ->
        exit_fleet(state, message["from"])

      :ignore ->
        state
    end
  end

  # Streams this endpoint's mailbox (auto-acknowledged) to the fleet process, reconnecting if
  # the daemon restarts. A deregistered endpoint gets a final "deregistered" line or a 401.
  defp tail(parent, auth) do
    url = String.to_charlist(CLI.base_url() <> "/v1/endpoints/#{auth.id}/tail?ack=1")

    headers =
      Enum.map(auth.headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    # Its own httpc profile, so the endless stream never blocks the main loop's requests.
    case :inets.start(:httpc, profile: :ww_fleet_tail) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case :httpc.request(:get, {url, headers}, [], [sync: false, stream: :self], :ww_fleet_tail) do
      {:ok, ref} -> tail_stream(parent, auth, ref, "")
      {:error, _} -> tail_retry(parent, auth)
    end
  end

  defp tail_stream(parent, auth, ref, buffer) do
    receive do
      {:http, {^ref, :stream_start, _headers}} ->
        tail_stream(parent, auth, ref, buffer)

      {:http, {^ref, :stream, chunk}} ->
        [rest | lines] = String.split(buffer <> chunk, "\n") |> Enum.reverse()

        for line <- Enum.reverse(lines), line != "" do
          case Jason.decode!(line) do
            %{"op" => "message", "message" => message} -> send(parent, {:fleet_message, message})
            %{"op" => "deregistered"} -> send(parent, :fleet_deregistered)
            _ -> :ok
          end
        end

        tail_stream(parent, auth, ref, rest)

      {:http, {^ref, {{_, 401, _}, _, _}}} ->
        send(parent, :fleet_deregistered)

      {:http, {^ref, _end_or_error}} ->
        tail_retry(parent, auth)
    end
  end

  defp tail_retry(parent, auth) do
    Process.sleep(1_000)
    tail(parent, auth)
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
    "canvas.action.v1" => nil
  }

  @doc """
  Decides what an incoming message asks for. Message content is untrusted: only subscribers may
  act, only on endpoints that exist; remove needs it offline, disconnect and shutdown need it
  online, and the fleet never removes itself (it only exits on a shutdown). A sender
  may subscribe itself or a canvas, but not other kinds of endpoint.
  """
  def command(%{"type" => type, "from" => from} = message, subscribers, endpoints, self_id) do
    payload = message["payload"] || %{}
    target = payload["to"] || from

    case type do
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
          not Map.has_key?(subscribers, from) or is_nil(target) -> :ignore
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

  @doc "Page rows for every endpoint, in a stable order."
  def rows(endpoints) do
    endpoints
    |> Enum.map(fn e ->
      %{
        name: e["name"],
        kind: e["kind"],
        type: type(e),
        status: if(e["online"], do: "online", else: "offline"),
        id: e["id"],
        cwd: get_in(e, ["metadata", "cwd"]) || ""
      }
    end)
    |> Enum.sort_by(& &1.id)
  end

  # Agents name their harness in metadata.harness, tools their tool in metadata.tool.
  # Endpoints registered before that convention are inferred from their accepts or name.
  defp type(%{"kind" => "agent"} = e) do
    cond do
      meta(e, "harness") -> meta(e, "harness")
      "demo.echo.v1" in (e["accepts"] || []) -> "pi"
      String.starts_with?(e["name"] || "", "pi-") -> "pi"
      true -> "unknown"
    end
  end

  defp type(e) do
    accepts = e["accepts"] || []

    cond do
      meta(e, "tool") -> meta(e, "tool")
      "canvas.render.v1" in accepts -> "canvas"
      "dashboard.render.v1" in accepts -> "dashboard (legacy)"
      true -> "unknown"
    end
  end

  defp meta(e, key), do: get_in(e, ["metadata", key])
end
