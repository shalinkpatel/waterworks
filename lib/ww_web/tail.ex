defmodule WwWeb.Tail do
  @moduledoc false
  # The router authenticated the request; only the endpoint id is kept.
  import Plug.Conn

  def stream(conn, id) do
    :ok = Ww.subscribe_as(id)

    conn =
      conn
      |> put_resp_content_type("application/x-ndjson")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)

    auto_ack = conn.query_params["ack"] == "1"

    case chunk(conn, Jason.encode!(%{op: "ready", endpoint: id}) <> "\n") do
      {:ok, conn} -> loop(conn, id, auto_ack)
      {:error, _} -> conn
    end
  end

  defp loop(conn, id, auto_ack) do
    value =
      receive do
        {:ww_message, message} -> %{op: "message", message: Ww.Wire.message(message)}
        :ww_deregistered -> %{op: "deregistered"}
      after
        15_000 -> %{op: "heartbeat"}
      end

    case chunk(conn, Jason.encode!(value) <> "\n") do
      {:ok, conn} ->
        if auto_ack && value.op == "message", do: :ok = Ww.acknowledge_as(id, value.message.id)
        if value.op == "deregistered", do: conn, else: loop(conn, id, auto_ack)

      {:error, _} ->
        conn
    end
  end
end
