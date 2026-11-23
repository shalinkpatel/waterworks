defmodule WwTransportTest do
  use ExUnit.Case, async: false

  alias Ww.{TestHTTP, TestWS}

  @moduletag :transport
  @admin "test-admin-token"

  setup do
    Enum.each([:ww_messages, :ww_counters, :ww_endpoints], fn table ->
      {:atomic, :ok} = :mnesia.clear_table(table)
    end)

    :ok
  end

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
