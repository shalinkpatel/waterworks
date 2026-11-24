defmodule Ww.Fleet do
  @moduledoc """
  `ww fleet`: a canvas of every registered agent and tool. Registers one canvas,
  publishes `priv/fleet/index.html` to it, then polls discovery and sends
  `canvas.data.v1` only when the fleet changes, so history stays small.
  """

  alias Ww.CLI

  @external_resource Path.expand("../../priv/fleet/index.html", __DIR__)
  @page File.read!(Path.expand("../../priv/fleet/index.html", __DIR__))

  def run(interval_ms, open?) do
    admin = System.get_env("WW_ADMIN_TOKEN") || raise("WW_ADMIN_TOKEN is required")

    %{"endpoint" => %{"id" => id}, "token" => token} =
      CLI.request(
        :post,
        "/v1/endpoints",
        CLI.canvas_endpoint("Waterworks fleet"),
        [{"x-ww-admin-token", admin}],
        false
      )

    auth = [{"x-ww-endpoint", id}, {"authorization", "Bearer #{token}"}]
    url = CLI.canvas_url(id, token)
    IO.puts(:stderr, "fleet canvas: #{url}")
    if open? and match?({:unix, :darwin}, :os.type()), do: System.cmd("open", [url])

    send_as(auth, id, "canvas.render.v1", %{html: @page, title: "Waterworks fleet"})

    loop(%{
      auth: auth,
      admin: admin,
      id: id,
      interval: interval_ms,
      last: nil,
      seen: 0,
      removed?: false
    })
  end

  defp loop(state) do
    endpoints = endpoints(state)
    state = handle_actions(state, endpoints)
    # Removals change the fleet, so list again rather than waiting a whole interval.
    endpoints = if state.removed?, do: endpoints(state), else: endpoints
    current = rows(endpoints, state.id)

    if current != state.last do
      updated = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      payload = %{endpoints: current, updated: "updated " <> updated}
      send_as(state.auth, state.id, "canvas.data.v1", payload)
    end

    Process.sleep(state.interval)
    loop(%{state | last: current})
  end

  defp endpoints(state),
    do: CLI.request(:get, "/v1/endpoints", nil, state.auth, false)["endpoints"]

  # Page buttons arrive as canvas.action.v1 in our own mailbox. Page content is untrusted, so
  # a removal is honoured only for an endpoint that exists, is offline, and is not this canvas.
  # shortcut: re-reads the whole history each poll; fine for one canvas, add a pending-only
  # route if histories grow large.
  defp handle_actions(state, endpoints) do
    actions =
      CLI.request(:get, "/v1/endpoints/#{state.id}/history", nil, state.auth, false)["messages"]
      # Only the page itself (it holds this canvas's token) sends actions from our own id.
      |> Enum.filter(&(&1["type"] == "canvas.action.v1" and &1["from"] == state.id))
      |> Enum.filter(&(&1["sequence"] > state.seen))

    removed =
      for message <- actions, removable?(message["payload"], endpoints, state.id) do
        id = message["payload"]["id"]

        # A double click or another fleet canvas may have removed it already.
        try do
          CLI.request(
            :delete,
            "/v1/endpoints/#{id}",
            nil,
            [{"x-ww-admin-token", state.admin}],
            false
          )

          IO.puts(:stderr, "removed #{id}")
        rescue
          error -> IO.puts(:stderr, "could not remove #{id}: #{Exception.message(error)}")
        end
      end

    for message <- actions,
        do:
          CLI.request(
            :post,
            "/v1/endpoints/#{state.id}/ack",
            %{id: message["id"]},
            state.auth,
            false
          )

    seen = Enum.reduce(actions, state.seen, &max(&1["sequence"], &2))
    Map.merge(state, %{seen: seen, removed?: removed != []})
  end

  @doc "Whether a page action asks to remove an existing, offline endpoint other than the canvas."
  def removable?(%{"action" => "remove", "id" => id}, endpoints, self_id) when is_binary(id),
    do: id != self_id and Enum.any?(endpoints, &(&1["id"] == id and &1["online"] == false))

  def removable?(_payload, _endpoints, _self_id), do: false

  defp send_as(auth, id, type, payload),
    do: CLI.request(:post, "/v1/messages", %{to: id, type: type, payload: payload}, auth, false)

  @doc "Page rows for every endpoint except the canvas itself, in a stable order."
  def rows(endpoints, self_id) do
    endpoints
    |> Enum.reject(&(&1["id"] == self_id))
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
  # Endpoints registered before that convention are inferred from their name or accepts.
  defp type(%{"kind" => "agent"} = e),
    do:
      meta(e, "harness") ||
        if(String.starts_with?(e["name"] || "", "pi-"), do: "pi", else: "unknown")

  defp type(e),
    do:
      meta(e, "tool") ||
        if("canvas.render.v1" in (e["accepts"] || []), do: "canvas", else: "unknown")

  defp meta(e, key), do: get_in(e, ["metadata", key])
end
