defmodule WwPiAdapterTest do
  use ExUnit.Case, async: false

  alias Ww.{TestHTTP, TestWS}

  @moduletag :transport
  @admin "test-admin-token"

  setup do
    Enum.each([:ww_messages, :ww_counters, :ww_endpoints], fn table ->
      {:atomic, :ok} = :mnesia.clear_table(table)
    end)

    File.rm_rf!("tmp/pi-sdk-test")
    :ok
  end

  test "live Pi session exchanges browser messages and handles reconnect and queues unmarked types" do
    {browser, browser_token} = register_browser()
    pi = start_pi(browser.id)
    # Closing the port does not stop node (the Pi session keeps its own event loop alive), so
    # kill it by OS pid; otherwise every run leaks a session process.
    {:os_pid, os_pid} = Port.info(pi, :os_pid)

    on_exit(fn ->
      System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end)

    agent = wait_for_agent(browser, browser_token)

    socket = TestWS.connect(browser.id, browser_token)

    socket =
      TestWS.send_json(socket, %{
        op: "send",
        id: "msg_pi_roundtrip",
        to: agent["id"],
        type: "test.ping.v1",
        payload: %{text: "hello pi", delivery: "immediate"}
      })

    {socket, accepted} = TestWS.receive_json(socket, 5_000)
    assert accepted["op"] == "accepted"
    {socket, response} = TestWS.receive_json(socket, 5_000)
    assert response["message"]["type"] == "test.pong.v1"
    assert response["message"]["payload"]["text"] == "hello from pi"
    assert response["message"]["reply_to"] == "msg_pi_roundtrip"
    socket = TestWS.send_json(socket, %{op: "ack", id: response["message"]["id"]})
    {socket, _} = TestWS.receive_json(socket)

    socket =
      TestWS.send_json(socket, %{
        op: "send",
        id: "msg_pi_unsupported",
        to: agent["id"],
        type: "example.unsupported.v1",
        payload: %{}
      })

    # Not marked immediate, so it queues in the agent's inbox instead of prompting the model.
    {socket, _} = TestWS.receive_json(socket)

    # Comments are accepted only from canvases this Pi session opened or published to; any
    # other endpoint's canvas.comment.v1 is refused without reaching the model.
    socket =
      TestWS.send_json(socket, %{
        op: "send",
        id: "msg_pi_canvas_comment",
        to: agent["id"],
        type: "canvas.comment.v1",
        payload: %{text: "too noisy", region: %{x: 0, y: 0, width: 0.5, height: 0.5}, panels: []}
      })

    {socket, _} = TestWS.receive_json(socket, 5_000)
    {socket, commented} = TestWS.receive_json(socket, 5_000)
    assert commented["message"]["reply_to"] == "msg_pi_canvas_comment"
    assert commented["message"]["type"] == "core.error.v1"
    assert commented["message"]["payload"]["error"] == "unknown_canvas"
    socket = TestWS.send_json(socket, %{op: "ack", id: commented["message"]["id"]})
    {_socket, _} = TestWS.receive_json(socket)
    TestWS.close(socket)
    wait_until(fn -> not online?(browser, browser_token, browser.id) end)

    assert {201, _} =
             TestHTTP.request(
               :post,
               "/v1/messages",
               %{
                 id: "msg_pi_reconnect",
                 to: agent["id"],
                 type: "test.ping.v1",
                 payload: %{text: "offline", delivery: "immediate"}
               },
               TestHTTP.auth(browser.id, browser_token)
             )

    wait_until(fn -> reply_in_history?(browser, browser_token, "msg_pi_reconnect") end)
    reconnected = TestWS.connect(browser.id, browser_token)
    {reconnected, pending} = TestWS.receive_json(reconnected, 5_000)
    assert pending["message"]["reply_to"] == "msg_pi_reconnect"
    assert pending["message"]["type"] == "test.pong.v1"
    _ = TestWS.send_json(reconnected, %{op: "ack", id: pending["message"]["id"]})
  end

  test "canvas tools: open keeps its token out of the model result, publish sends a file" do
    {output, 0} =
      System.cmd("node", ["test/support/pi_tool_check.mjs"],
        env: [
          {"WW_URL", "http://127.0.0.1:17420"},
          {"WW_ADMIN_TOKEN", @admin},
          {"WW_OPEN_BROWSER", "0"}
        ]
      )

    %{
      "content" => content,
      "details" => %{"endpoint_id" => id},
      "notices" => [notice],
      "published" => %{"message_id" => published_id},
      "republished" => republished,
      "expected" => expected
    } = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()

    [_, fragment] = String.split(notice, "/canvas#")
    %{"endpoint" => ^id, "token" => token} = URI.decode_query(fragment)
    refute content =~ token
    assert %Ww.Endpoint{accepts: accepts} = Ww.Store.get_endpoint(id)
    assert "canvas.render.v1" in accepts

    assert [first, full, delta] = Ww.Store.history(id)
    assert %Ww.Message{id: ^published_id, type: "canvas.render.v1"} = first
    assert first.payload == %{"html" => "<h1>from pi</h1>", "title" => "Pi page"}

    # A delta to an unrelated page is not smaller, so that publish is full.
    assert republished == ["canvas.render.v1", "canvas.delta.v1"]

    # The delta names its base and rebuilds the edited page with the browser's applier.
    assert %Ww.Message{type: "canvas.delta.v1", payload: %{"base" => base, "ops" => ops}} =
             delta

    assert base == full.id
    assert apply_ops(full.payload["html"], ops) == expected
  end

  defp apply_ops(old, ops) do
    lines = String.split(old, "\n")

    {out, rest} =
      Enum.reduce(ops, {[], lines}, fn
        %{"keep" => n}, {out, rest} -> {Enum.reverse(Enum.take(rest, n), out), Enum.drop(rest, n)}
        %{"drop" => n}, {out, rest} -> {out, Enum.drop(rest, n)}
        %{"insert" => new}, {out, rest} -> {Enum.reverse(new, out), rest}
      end)

    assert rest == []
    out |> Enum.reverse() |> Enum.join("\n")
  end

  defp register_browser do
    assert {201, response} =
             TestHTTP.request(:post, "/v1/endpoints", %{kind: "tool", name: "pi-browser"}, [
               {"x-ww-admin-token", @admin}
             ])

    {%{id: response["endpoint"]["id"]}, response["token"]}
  end

  defp start_pi(browser_id) do
    executable = :os.find_executable(~c"node")
    root = pi_root()
    script = Path.expand("support/pi_session.mjs", __DIR__) |> String.to_charlist()

    env = [
      {~c"PI_CODING_AGENT_ROOT", String.to_charlist(root)},
      {~c"WW_URL", ~c"http://127.0.0.1:17420"},
      {~c"WW_ADMIN_TOKEN", String.to_charlist(@admin)},
      {~c"WW_BROWSER_ID", String.to_charlist(browser_id)}
    ]

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :stderr_to_stdout,
        args: [script],
        env: env
      ])

    forwarder = spawn_link(fn -> forward_output(port) end)
    Port.connect(port, forwarder)
    port
  end

  defp forward_output(port) do
    receive do
      {^port, {:data, data}} ->
        IO.write(:stderr, data)
        forward_output(port)
    end
  end

  defp pi_root do
    managed_root = System.get_env("PI_MANAGED_INSTALL_ROOT")

    candidates =
      if managed_root do
        Path.wildcard(
          Path.expand("#{managed_root}/releases/*/node_modules/@earendil-works/pi-coding-agent")
        )
      else
        []
      end

    System.get_env("PI_CODING_AGENT_ROOT") || Enum.sort(candidates) |> List.last() ||
      raise("set PI_CODING_AGENT_ROOT to the installed pi-coding-agent package directory")
  end

  defp wait_for_agent(browser, token) do
    wait_until(fn ->
      case TestHTTP.request(
             :get,
             "/v1/endpoints?kind=agent&online=true",
             nil,
             TestHTTP.auth(browser.id, token)
           ) do
        {200, %{"endpoints" => [_ | _]}} -> true
        _ -> false
      end
    end)

    {200, %{"endpoints" => [agent | _]}} =
      TestHTTP.request(:get, "/v1/endpoints?kind=agent", nil, TestHTTP.auth(browser.id, token))

    agent
  end

  defp online?(caller, token, target) do
    {200, %{"endpoint" => endpoint}} =
      TestHTTP.request(:get, "/v1/endpoints/#{target}", nil, TestHTTP.auth(caller.id, token))

    endpoint["online"]
  end

  defp reply_in_history?(endpoint, token, reply_to) do
    {200, %{"messages" => messages}} =
      TestHTTP.request(
        :get,
        "/v1/endpoints/#{endpoint.id}/history",
        nil,
        TestHTTP.auth(endpoint.id, token)
      )

    Enum.any?(messages, &(&1["reply_to"] == reply_to))
  end

  defp wait_until(fun, attempts \\ 750)
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
