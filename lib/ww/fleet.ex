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
    * `fleet.remove.v1 {id}` or `canvas.action.v1 {action: "remove", id}` from a subscriber:
      deregisters an endpoint that exists and is offline.

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
      seen: 0,
      subscribers: %{viewer => "fleet.state.v1"}
    }

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
        "canvas.action.v1"
      ],
      emits: ["fleet.state.v1", "canvas.data.v1"],
      metadata: %{tool: "fleet"}
    }
  end

  defp viewer_endpoint do
    %{
      kind: "tool",
      name: "fleet view",
      accepts: ["fleet.state.v1"],
      emits: ["fleet.subscribe.v1", "fleet.remove.v1"],
      metadata: %{tool: "fleet-view"}
    }
  end

  defp loop(state) do
    endpoints = endpoints(state)
    {state, changed?, fresh} = handle_messages(state, endpoints)
    # Removals change the fleet, so list again rather than waiting a whole interval.
    endpoints = if changed?, do: endpoints(state), else: endpoints
    current = rows(endpoints)

    # Everyone gets changes; new subscribers get the current state even when nothing changed.
    targets = if current != state.last, do: Map.keys(state.subscribers), else: fresh

    payload = %{
      fleet: state.id,
      endpoints: current,
      updated:
        "updated " <> (DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601())
    }

    state = Enum.reduce(Enum.uniq(targets), state, &deliver(&2, &1, payload))
    Process.sleep(state.interval)
    loop(%{state | last: current})
  end

  defp endpoints(state),
    do: CLI.request(:get, "/v1/endpoints", nil, state.auth, false)["endpoints"]

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

  # shortcut: reads new messages by polling history (one round trip per interval); switch to
  # the streaming tail if the interval needs to drop below a second.
  defp handle_messages(state, endpoints) do
    messages =
      CLI.request(:get, "/v1/endpoints/#{state.id}/history", nil, state.auth, false)["messages"]
      |> Enum.filter(&(&1["sequence"] > state.seen and &1["from"] != state.id))

    {state, changed?, fresh} =
      Enum.reduce(messages, {state, false, []}, fn message, {state, changed?, fresh} ->
        case command(message, state.subscribers, endpoints, state.id) do
          {:subscribe, to, type} ->
            {put_in(state.subscribers[to], type), changed?, [to | fresh]}

          {:unsubscribe, to} ->
            {%{state | subscribers: Map.delete(state.subscribers, to)}, changed?, fresh}

          {:remove, id} ->
            {state, remove(state, id) or changed?, fresh}

          :ignore ->
            {state, changed?, fresh}
        end
      end)

    for message <- messages do
      CLI.request(:post, "/v1/endpoints/#{state.id}/ack", %{id: message["id"]}, state.auth, false)
    end

    seen = Enum.reduce(messages, state.seen, &max(&1["sequence"], &2))
    {%{state | seen: seen}, changed?, fresh}
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

  @doc """
  Decides what an incoming message asks for. Message content is untrusted: only subscribers
  may remove, and only endpoints that exist and are offline (never the fleet itself). A sender
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

      type when type in ["fleet.remove.v1", "canvas.action.v1"] ->
        id = payload["id"]
        remove? = type == "fleet.remove.v1" or payload["action"] == "remove"

        if remove? and Map.has_key?(subscribers, from) and removable?(id, endpoints, self_id),
          do: {:remove, id},
          else: :ignore

      _ ->
        :ignore
    end
  end

  defp removable?(id, endpoints, self_id) when is_binary(id),
    do: id != self_id and Enum.any?(endpoints, &(&1["id"] == id and &1["online"] == false))

  defp removable?(_id, _endpoints, _self_id), do: false

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
