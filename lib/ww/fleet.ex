defmodule Ww.Fleet do
  @moduledoc """
  `ww fleet`: a dashboard of every registered agent and tool. Registers one dashboard,
  publishes `priv/fleet/index.html` to it, then polls discovery and sends
  `dashboard.data.v1` only when the fleet changes, so history stays small.
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
        CLI.dashboard_endpoint("Waterworks fleet"),
        [{"x-ww-admin-token", admin}],
        false
      )

    auth = [{"x-ww-endpoint", id}, {"authorization", "Bearer #{token}"}]
    url = CLI.dashboard_url(id, token)
    IO.puts(:stderr, "fleet dashboard: #{url}")
    if open? and match?({:unix, :darwin}, :os.type()), do: System.cmd("open", [url])

    send_as(auth, id, "dashboard.render.v1", %{html: @page, title: "Waterworks fleet"})
    loop(auth, id, interval_ms, nil)
  end

  defp loop(auth, id, interval_ms, last) do
    %{"endpoints" => endpoints} = CLI.request(:get, "/v1/endpoints", nil, auth, false)
    current = rows(endpoints, id)

    if current != last do
      updated = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      send_as(auth, id, "dashboard.data.v1", %{endpoints: current, updated: "updated " <> updated})
    end

    Process.sleep(interval_ms)
    loop(auth, id, interval_ms, current)
  end

  defp send_as(auth, id, type, payload),
    do: CLI.request(:post, "/v1/messages", %{to: id, type: type, payload: payload}, auth, false)

  @doc "Page rows for every endpoint except the dashboard itself, in a stable order."
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
        if("dashboard.render.v1" in (e["accepts"] || []), do: "dashboard", else: "unknown")

  defp meta(e, key), do: get_in(e, ["metadata", key])
end
