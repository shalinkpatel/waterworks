defmodule WwDemoTest do
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

  test "demo assets are served" do
    assert {200, html} = TestHTTP.request(:get, "/demo")
    assert to_string(html) =~ "Waterworks echo"
    assert {200, javascript} = TestHTTP.request(:get, "/demo/app.js")
    assert to_string(javascript) =~ "demo.echo.v1"
  end

  test "browser and real CLI echo process round trip and reconnect" do
    {browser, browser_token} = register("tool", "browser-demo")
    {cli, cli_token} = register("tool", "cli-demo")
    echo = start_echo(cli.id, cli_token)
    on_exit(fn -> if Port.info(echo), do: Port.close(echo) end)

    wait_until(fn -> online?(browser, browser_token, cli.id) end)

    socket = TestWS.connect(browser.id, browser_token)

    socket =
      TestWS.send_json(socket, %{
        op: "send",
        id: "msg_demo_roundtrip",
        to: cli.id,
        type: "demo.echo.v1",
        payload: %{text: "hello waterworks"}
      })

    {socket, accepted} = TestWS.receive_json(socket)
    assert accepted["op"] == "accepted"

    {socket, response} = TestWS.receive_json(socket)
    assert response["op"] == "message"
    assert response["message"]["type"] == "demo.echoed.v1"
    assert response["message"]["payload"]["text"] == "hello waterworks"
    assert response["message"]["payload"]["echoed_by"] == cli.id
    assert response["message"]["reply_to"] == "msg_demo_roundtrip"

    socket = TestWS.send_json(socket, %{op: "ack", id: response["message"]["id"]})
    {_socket, acked} = TestWS.receive_json(socket)
    assert acked["op"] == "acked"
    TestWS.close(socket)

    assert {201, _} =
             TestHTTP.request(
               :post,
               "/v1/messages",
               %{
                 id: "msg_demo_reconnect",
                 to: cli.id,
                 type: "demo.echo.v1",
                 payload: %{text: "while offline"}
               },
               TestHTTP.auth(browser.id, browser_token)
             )

    wait_until(fn -> message_in_history?(browser, browser_token, "msg_demo_reconnect-echo") end)
    reconnected = TestWS.connect(browser.id, browser_token)
    {reconnected, pending} = TestWS.receive_json(reconnected)
    assert pending["message"]["id"] == "msg_demo_reconnect-echo"
    assert pending["message"]["payload"]["text"] == "while offline"

    _ = TestWS.send_json(reconnected, %{op: "ack", id: pending["message"]["id"]})
  end

  defp register(kind, name) do
    assert {201, response} =
             TestHTTP.request(:post, "/v1/endpoints", %{kind: kind, name: name}, [
               {"x-ww-admin-token", @admin}
             ])

    {%{id: response["endpoint"]["id"]}, response["token"]}
  end

  defp start_echo(id, token) do
    executable = :os.find_executable(~c"elixir")
    paths = Path.wildcard("_build/test/lib/*/ebin")
    args = Enum.flat_map(paths, &["-pa", Path.expand(&1)]) ++ ["-e", ~c"Ww.CLI.main([\"echo\"])"]

    env = [
      {~c"WW_URL", ~c"http://127.0.0.1:17420"},
      {~c"WW_ENDPOINT", String.to_charlist(id)},
      {~c"WW_TOKEN", String.to_charlist(token)}
    ]

    Port.open({:spawn_executable, executable}, [
      :binary,
      :stderr_to_stdout,
      args: args,
      env: env
    ])
  end

  defp online?(caller, token, target) do
    {200, %{"endpoint" => endpoint}} =
      TestHTTP.request(:get, "/v1/endpoints/#{target}", nil, TestHTTP.auth(caller.id, token))

    endpoint["online"]
  end

  defp message_in_history?(endpoint, token, id) do
    {200, %{"messages" => messages}} =
      TestHTTP.request(
        :get,
        "/v1/endpoints/#{endpoint.id}/history",
        nil,
        TestHTTP.auth(endpoint.id, token)
      )

    Enum.any?(messages, &(&1["id"] == id))
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(fun, 0), do: assert(fun.())

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end
end
