defmodule Ww.TestWS do
  @moduledoc false

  def connect(id, token) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", 17_420)
    protocols = "ww, ww-token.#{token}"

    {:ok, conn, ref} =
      Mint.WebSocket.upgrade(:ws, conn, "/v1/endpoints/#{id}/socket", [
        {"sec-websocket-protocol", protocols}
      ])

    {conn, status, headers} = await_upgrade(conn, ref, [])
    {:ok, conn, websocket} = Mint.WebSocket.new(conn, ref, status, headers)
    state = %{conn: conn, ref: ref, websocket: websocket, frames: []}
    {state, %{"op" => "ready"}} = receive_json(state)
    state
  end

  def send_json(state, value) do
    {:ok, websocket, data} = Mint.WebSocket.encode(state.websocket, {:text, Jason.encode!(value)})
    {:ok, conn} = Mint.WebSocket.stream_request_body(state.conn, state.ref, data)
    %{state | conn: conn, websocket: websocket}
  end

  # One TCP read can carry several frames; extras are buffered for the next call.
  def receive_json(state, timeout \\ 1_000)

  def receive_json(%{frames: [frame | rest]} = state, _timeout),
    do: {%{state | frames: rest}, frame}

  def receive_json(state, timeout) do
    receive do
      message ->
        case Mint.WebSocket.stream(state.conn, message) do
          :unknown ->
            receive_json(state, timeout)

          {:ok, conn, responses} ->
            state = %{state | conn: conn}
            data = for {:data, ref, data} <- responses, ref == state.ref, into: "", do: data

            if data == "" do
              receive_json(state, timeout)
            else
              {:ok, websocket, frames} = Mint.WebSocket.decode(state.websocket, data)
              state = %{state | websocket: websocket}

              decoded = for {:text, text} <- frames, do: Jason.decode!(text)
              receive_json(%{state | frames: decoded}, timeout)
            end
        end
    after
      timeout -> :timeout
    end
  end

  def close(state), do: Mint.HTTP.close(state.conn)

  defp await_upgrade(conn, ref, acc) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          :unknown ->
            await_upgrade(conn, ref, acc)

          {:ok, conn, responses} ->
            acc = acc ++ responses

            if Enum.any?(acc, &(&1 == {:done, ref})) do
              {:status, ^ref, status} = Enum.find(acc, &match?({:status, ^ref, _}, &1))
              {:headers, ^ref, headers} = Enum.find(acc, &match?({:headers, ^ref, _}, &1))
              {conn, status, headers}
            else
              await_upgrade(conn, ref, acc)
            end
        end
    after
      1_000 -> raise "WebSocket upgrade timed out"
    end
  end
end
