defmodule WwTransportTest do
  use Ww.TransportCase, async: false

  alias Ww.TestWS

  @admin "test-admin-token"

  test "HTTP registration, inspection, discovery, and authentication" do
    assert {200, %{"ok" => true}} = TestHTTP.request(:get, "/v1/health")

    # DNS rebinding: a request naming another host is refused before routing.
    assert {403, %{"error" => "forbidden_host"}} =
             TestHTTP.request(:get, "/v1/health", nil, [{"host", "attacker.example:17420"}])

    # Bodies are read only after authentication: garbage from an unknown caller is a 401.
    assert {401, _} =
             TestHTTP.request(:post, "/v1/messages", "not json", TestHTTP.auth("ep_x", "bad"))

    assert {401, _} =
             TestHTTP.request(:post, "/v1/endpoints", "not json", [{"x-ww-admin-token", "x"}])

    assert {401, _} =
             TestHTTP.request(:post, "/v1/endpoints", %{kind: "tool", name: "bad"}, [
               {"x-ww-admin-token", "wrong"}
             ])

    {agent, agent_token} = register("agent", "http-agent")
    {tool, _tool_token} = register("tool", "http-tool", ["tool.event.v1"])

    assert {401, _} = TestHTTP.request(:get, "/v1/endpoints", nil, TestHTTP.auth(agent.id, "bad"))

    assert {200, %{"endpoints" => [found]}} =
             TestHTTP.request(
               :get,
               "/v1/endpoints?kind=tool&accepts=tool.event.v1&online=false",
               nil,
               TestHTTP.auth(agent.id, agent_token)
             )

    assert found["id"] == tool.id
    refute Map.has_key?(found, "token_hash")

    assert {200, %{"endpoint" => inspected}} =
             TestHTTP.request(
               :get,
               "/v1/endpoints/#{tool.id}",
               nil,
               TestHTTP.auth(agent.id, agent_token)
             )

    assert inspected["name"] == "http-tool"
  end

  test "WebSocket delivery, acknowledgement, reconnect, and presence" do
    {agent, agent_token} = register("agent", "socket-agent")
    {tool, tool_token} = register("tool", "socket-tool")

    socket = TestWS.connect(tool.id, tool_token)

    assert {201, %{"message" => sent}} =
             TestHTTP.request(
               :post,
               "/v1/messages",
               %{to: tool.id, type: "ping.v1", payload: %{"value" => 1}},
               TestHTTP.auth(agent.id, agent_token)
             )

    {socket, received} = TestWS.receive_json(socket)
    assert received["op"] == "message"
    assert received["message"]["id"] == sent["id"]

    socket = TestWS.send_json(socket, %{op: "ack", id: sent["id"]})
    {socket, acked} = TestWS.receive_json(socket)
    assert acked == %{"op" => "acked", "id" => sent["id"]}

    assert {200, %{"endpoints" => [online]}} =
             TestHTTP.request(
               :get,
               "/v1/endpoints?online=true",
               nil,
               TestHTTP.auth(agent.id, agent_token)
             )

    assert online["id"] == tool.id
    TestWS.close(socket)

    eventually(fn ->
      {200, %{"endpoint" => endpoint}} =
        TestHTTP.request(
          :get,
          "/v1/endpoints/#{tool.id}",
          nil,
          TestHTTP.auth(agent.id, agent_token)
        )

      refute endpoint["online"]
    end)

    reconnected = TestWS.connect(tool.id, tool_token)
    assert TestWS.receive_json(reconnected, 100) == :timeout

    reconnected =
      TestWS.send_json(reconnected, %{
        op: "send",
        to: agent.id,
        type: "pong.v1",
        payload: %{},
        reply_to: sent["id"]
      })

    {_reconnected, accepted} = TestWS.receive_json(reconnected)
    assert accepted["op"] == "accepted"
    assert accepted["message"]["reply_to"] == sent["id"]
  end

  test "HTTP rename and deregistration" do
    {agent, agent_token} = register("agent", "pi-1")
    {other, other_token} = register("tool", "other")
    {victim, victim_token} = register("tool", "victim")

    assert {201, _} =
             TestHTTP.request(
               :post,
               "/v1/messages",
               %{to: victim.id, type: "x.v1", payload: %{}},
               TestHTTP.auth(agent.id, agent_token)
             )

    # Receipts: sender and recipient can see a message's status; others cannot.
    assert {201, %{"message" => %{"id" => sent_id}}} =
             TestHTTP.request(
               :post,
               "/v1/messages",
               %{to: other.id, type: "x.v1", payload: %{}},
               TestHTTP.auth(agent.id, agent_token)
             )

    assert {200, %{"status" => "pending"}} =
             TestHTTP.request(
               :get,
               "/v1/messages/#{sent_id}",
               nil,
               TestHTTP.auth(agent.id, agent_token)
             )

    assert {200, _} =
             TestHTTP.request(
               :post,
               "/v1/endpoints/#{other.id}/ack",
               %{id: sent_id},
               TestHTTP.auth(other.id, other_token)
             )

    assert {200, %{"status" => "acked"}} =
             TestHTTP.request(
               :get,
               "/v1/messages/#{sent_id}",
               nil,
               TestHTTP.auth(agent.id, agent_token)
             )

    assert {404, _} =
             TestHTTP.request(
               :get,
               "/v1/messages/#{sent_id}",
               nil,
               TestHTTP.auth(victim.id, victim_token)
             )

    # Rename: only yourself, and only name/metadata.
    assert {401, _} =
             TestHTTP.request(
               :patch,
               "/v1/endpoints/#{agent.id}",
               %{name: "x"},
               TestHTTP.auth(other.id, other_token)
             )

    assert {200, %{"endpoint" => renamed}} =
             TestHTTP.request(
               :patch,
               "/v1/endpoints/#{agent.id}",
               %{name: "fix auth", metadata: %{harness: "pi"}},
               TestHTTP.auth(agent.id, agent_token)
             )

    assert renamed["name"] == "fix auth"
    assert renamed["metadata"] == %{"harness" => "pi"}
    assert renamed["kind"] == "agent"

    victim_socket = TestWS.connect(victim.id, victim_token)
    # Its pending message arriving shows the socket is subscribed.
    {victim_socket, %{"op" => "message"}} = TestWS.receive_json(victim_socket)

    # Another endpoint cannot delete you; the admin token or your own token can.
    assert {401, _} =
             TestHTTP.request(
               :delete,
               "/v1/endpoints/#{victim.id}",
               nil,
               TestHTTP.auth(other.id, other_token)
             )

    assert {200, _} =
             TestHTTP.request(:delete, "/v1/endpoints/#{victim.id}", nil, [
               {"x-ww-admin-token", @admin}
             ])

    assert {401, _} =
             TestHTTP.request(
               :get,
               "/v1/endpoints/#{victim.id}/history",
               nil,
               TestHTTP.auth(victim.id, victim_token)
             )

    assert :mnesia.dirty_index_read(:ww_messages, victim.id, :to) == []
    # A connected endpoint is told why it was disconnected, so clients stop reconnecting.
    assert TestWS.receive_close(victim_socket) == {1000, "deregistered"}

    assert {404, %{"error" => "recipient_not_found"}} =
             TestHTTP.request(
               :post,
               "/v1/messages",
               %{to: victim.id, type: "x.v1", payload: %{}},
               TestHTTP.auth(agent.id, agent_token)
             )

    assert {200, _} =
             TestHTTP.request(
               :delete,
               "/v1/endpoints/#{other.id}",
               nil,
               TestHTTP.auth(other.id, other_token)
             )

    assert {404, _} =
             TestHTTP.request(:delete, "/v1/endpoints/#{other.id}", nil, [
               {"x-ww-admin-token", @admin}
             ])
  end

  test "HTTP tail streams messages; without ?ack=1 they stay pending until acknowledged" do
    {reader, reader_token} = register("tool", "reader")
    {writer, writer_token} = register("tool", "writer")

    # A raw socket keeps the open stream off the HTTP client the rest of the test uses.
    {:ok, tail} = :gen_tcp.connect(~c"127.0.0.1", 17_420, [:binary, active: false])
    on_exit(fn -> :gen_tcp.close(tail) end)

    :ok =
      :gen_tcp.send(
        tail,
        "GET /v1/endpoints/#{reader.id}/tail HTTP/1.1\r\nhost: 127.0.0.1\r\n" <>
          "authorization: Bearer #{reader_token}\r\n\r\n"
      )

    assert {%{"op" => "ready"}, buffer} = next_line(tail, "")

    assert {201, _} =
             TestHTTP.request(
               :post,
               "/v1/messages",
               %{id: "msg_tail", to: reader.id, type: "x.v1", payload: %{n: 1}},
               TestHTTP.auth(writer.id, writer_token)
             )

    assert {%{"op" => "message", "message" => %{"id" => "msg_tail", "payload" => %{"n" => 1}}}, _} =
             next_line(tail, buffer)

    status = fn ->
      {200, %{"status" => status}} =
        TestHTTP.request(
          :get,
          "/v1/messages/msg_tail",
          nil,
          TestHTTP.auth(writer.id, writer_token)
        )

      status
    end

    assert status.() == "pending"

    assert {200, _} =
             TestHTTP.request(
               :post,
               "/v1/endpoints/#{reader.id}/ack",
               %{id: "msg_tail"},
               TestHTTP.auth(reader.id, reader_token)
             )

    assert status.() == "acked"
  end

  # The next JSON line of the tail; chunk-size lines and headers are skipped.
  defp next_line(socket, buffer) do
    case String.split(buffer, "\n", parts: 2) do
      [line, rest] ->
        case String.trim(line) do
          "{" <> _ = json -> {Jason.decode!(json), rest}
          _ -> next_line(socket, rest)
        end

      [_partial] ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
        next_line(socket, buffer <> data)
    end
  end

  defp register(kind, name, accepts \\ []) do
    assert {201, response} =
             TestHTTP.request(
               :post,
               "/v1/endpoints",
               %{kind: kind, name: name, accepts: accepts},
               [{"x-ww-admin-token", @admin}]
             )

    endpoint = %{id: response["endpoint"]["id"], name: response["endpoint"]["name"]}
    {endpoint, response["token"]}
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(20)
      eventually(fun, attempts - 1)
  end
end
