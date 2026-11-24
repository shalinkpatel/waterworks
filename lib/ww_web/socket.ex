defmodule WwWeb.Socket do
  @moduledoc false
  # State is %{id: endpoint id}: the router authenticated the upgrade, so no token is kept.
  @behaviour WebSock

  # Idle connections are closed by the server after 60 s; pings keep quiet canvases attached.
  @keepalive 30_000

  @impl true
  def init(state) do
    :ok = Ww.subscribe_as(state.id)
    Process.send_after(self(), :keepalive, @keepalive)
    push(%{op: "ready", endpoint: state.id}, state)
  end

  @impl true
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, body} when is_map(body) -> command(body, state)
      _ -> error("invalid_json", state)
    end
  end

  def handle_in(_frame, state), do: error("unsupported_frame", state)

  @impl true
  def handle_info({:ww_message, message}, state) do
    push(%{op: "message", message: Ww.Wire.message(message)}, state)
  end

  def handle_info(:ww_deregistered, state),
    do: {:stop, :normal, {1000, "deregistered"}, state}

  def handle_info(:keepalive, state) do
    Process.send_after(self(), :keepalive, @keepalive)
    {:push, {:ping, ""}, state}
  end

  def handle_info(_message, state), do: {:ok, state}

  defp command(%{"op" => "send"} = body, state) do
    {to, type, payload, opts} = Ww.Wire.send_args(body)

    case Ww.send_as(state.id, to, type, payload, opts) do
      {:ok, message} -> push(%{op: "accepted", message: Ww.Wire.message(message)}, state)
      {:error, reason} -> error(reason, state)
    end
  end

  defp command(%{"op" => "ack", "id" => id}, state) do
    case Ww.acknowledge_as(state.id, id) do
      :ok -> push(%{op: "acked", id: id}, state)
      {:error, reason} -> error(reason, state)
    end
  end

  defp command(%{"op" => "ping"}, state), do: push(%{op: "pong"}, state)
  defp command(_body, state), do: error("unknown_operation", state)

  defp error(reason, state), do: push(%{op: "error", error: to_string(reason)}, state)

  defp push(value, state), do: {:push, {:text, Jason.encode!(value)}, state}
end
