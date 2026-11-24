defmodule WwFleetTransportTest do
  # Runs `ww fleet` against the test daemon: a subscribed canvas acts as the user.
  use Ww.TransportCase, async: false

  test "watchers get state; the user removes, broadcasts with receipts, and shuts the fleet down" do
    agent = register!("agent", "agent", [], %{harness: "pi"})
    pid = start_tool(fn -> Ww.Fleet.run(200, false) end)
    fleet = wait_for_endpoint(agent, "fleet.subscribe.v1")

    # Watching: an agent subscribes itself and gets the endpoint list.
    send_raw(agent, fleet, "fleet.subscribe.v1", %{})
    wait_until(fn -> Enum.find(history(agent), &(&1["type"] == "fleet.state.v1")) end)

    # ...but watching is not acting.
    {dead_id, _} = dead = register!("tool", "dead")

    assert %{"type" => "core.error.v1", "payload" => %{"error" => "only the fleet view" <> _}} =
             ask(agent, fleet, "fleet.remove.v1", %{id: dead_id})

    # The user: a canvas the agent subscribed.
    canvas = register!("tool", "canvas", ["canvas.data.v1"])
    {canvas_id, _} = canvas
    send_raw(agent, fleet, "fleet.subscribe.v1", %{to: canvas_id})
    wait_until(fn -> Enum.find(history(canvas), &(&1["type"] == "canvas.data.v1")) end)

    send_raw(canvas, fleet, "canvas.action.v1", %{action: "remove", id: dead_id})

    wait_until(fn ->
      match?(
        {401, _},
        TestHTTP.request(
          :get,
          "/v1/endpoints/#{dead_id}/history",
          nil,
          TestHTTP.auth(dead_id, elem(dead, 1))
        )
      )
    end)

    # Broadcast to the agent (online: it has a socket); its acknowledgement shows up in the
    # canvas as a receipt.
    {agent_id, agent_token} = agent
    socket = Ww.TestWS.connect(agent_id, agent_token)
    on_exit(fn -> Ww.TestWS.close(socket) end)

    send_raw(canvas, fleet, "canvas.action.v1", %{
      action: "broadcast",
      ids: [agent_id],
      text: "status?",
      broadcast: "b1"
    })

    prompt = wait_until(fn -> Enum.find(history(agent), &(&1["type"] == "agent.prompt.v1")) end)
    assert prompt["payload"] == %{"text" => "status?", "delivery" => "immediate"}

    {200, _} =
      TestHTTP.request(
        :post,
        "/v1/endpoints/#{agent_id}/ack",
        %{id: prompt["id"]},
        TestHTTP.auth(agent_id, agent_token)
      )

    wait_until(fn ->
      Enum.find(history(canvas), fn m ->
        match?(
          %{
            "type" => "canvas.data.v1",
            "payload" => %{
              "reply" => %{
                "type" => "fleet.broadcast_status.v1",
                "payload" => %{"broadcast" => "b1", "sessions" => [%{"status" => "acked"}]}
              }
            }
          },
          m
        )
      end)
    end)

    # Shutting the fleet down removes it and its viewer, and the process returns.
    send_raw(canvas, fleet, "canvas.action.v1", %{action: "shutdown", id: fleet})
    wait_until(fn -> not Process.alive?(pid) end)

    {200, %{"endpoints" => left}} =
      TestHTTP.request(:get, "/v1/endpoints", nil, TestHTTP.auth(agent_id, agent_token))

    assert Enum.map(left, & &1["name"]) |> Enum.sort() == ["agent", "canvas"]
  end
end
