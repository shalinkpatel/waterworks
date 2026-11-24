defmodule WwFleetTest do
  use ExUnit.Case, async: true

  alias Ww.Fleet

  test "rows take the type from metadata (harness for agents, tool for tools), sorted by id" do
    endpoints = [
      %{
        "id" => "ep_b",
        "kind" => "agent",
        "online" => true,
        "metadata" => %{"harness" => "claude"}
      },
      %{"id" => "ep_a", "kind" => "tool", "online" => false, "metadata" => %{"tool" => "canvas"}},
      %{"id" => "ep_c", "kind" => "agent", "online" => false, "metadata" => %{}}
    ]

    assert Enum.map(Fleet.rows(endpoints), &{&1.id, &1.type, &1.status}) == [
             {"ep_a", "canvas", "offline"},
             {"ep_b", "claude", "online"},
             {"ep_c", "unknown", "offline"}
           ]
  end

  @endpoints [
    %{"id" => "ep_agent", "kind" => "agent", "accepts" => [], "online" => true},
    %{"id" => "ep_agent_off", "kind" => "agent", "accepts" => [], "online" => false},
    %{"id" => "ep_canvas", "kind" => "tool", "accepts" => ["canvas.data.v1"], "online" => true},
    %{"id" => "ep_view", "kind" => "tool", "accepts" => ["fleet.state.v1"], "online" => true},
    %{"id" => "ep_dead", "kind" => "tool", "accepts" => [], "online" => false},
    %{"id" => "ep_fleet", "kind" => "tool", "accepts" => [], "online" => true}
  ]

  # The user is the fleet's own view (ep_view) or a subscribed canvas (ep_canvas). ep_agent has
  # subscribed itself to watch, which does not make it the user.
  @ctx %{
    endpoints: @endpoints,
    id: "ep_fleet",
    viewer: "ep_view",
    headers: [],
    subscribers: %{
      "ep_view" => "fleet.state.v1",
      "ep_canvas" => "canvas.data.v1",
      "ep_agent" => "fleet.state.v1"
    }
  }

  defp command(type, from, payload),
    do: Fleet.command(%{"type" => type, "from" => from, "payload" => payload}, @ctx)

  defp canvas(action, payload),
    do: command("canvas.action.v1", "ep_canvas", Map.put(payload, "action", action))

  test "remove (offline), disconnect and shutdown (online), from the view or a subscribed canvas" do
    assert command("fleet.remove.v1", "ep_view", %{"id" => "ep_dead"}) == {:remove, "ep_dead"}
    assert canvas("remove", %{"id" => "ep_dead"}) == {:remove, "ep_dead"}

    assert command("fleet.disconnect.v1", "ep_view", %{"id" => "ep_agent"}) ==
             {:remove, "ep_agent"}

    assert canvas("disconnect", %{"id" => "ep_agent"}) == {:remove, "ep_agent"}

    assert command("fleet.shutdown.v1", "ep_view", %{"id" => "ep_agent"}) ==
             {:shutdown, "ep_agent"}

    assert canvas("shutdown", %{"id" => "ep_agent"}) == {:shutdown, "ep_agent"}

    assert command("fleet.remove_offline.v1", "ep_view", %{}) ==
             {:remove_all, ["ep_agent_off", "ep_dead"]}

    # Wrong state for the action, unknown target, or unknown action: an error to answer.
    assert {:error, "cannot remove an endpoint that is online"} =
             command("fleet.remove.v1", "ep_view", %{"id" => "ep_agent"})

    assert {:error, _} = command("fleet.disconnect.v1", "ep_view", %{"id" => "ep_dead"})

    assert {:error, "no endpoint \"ep_missing\""} =
             command("fleet.remove.v1", "ep_view", %{"id" => "ep_missing"})

    assert {:error, "unsupported: canvas.action.v1"} = canvas("nuke", %{"id" => "ep_dead"})

    # The fleet exits on a shutdown (its own, or core.shutdown.v1 from anyone), never removed.
    assert command("fleet.shutdown.v1", "ep_view", %{"id" => "ep_fleet"}) == :exit
    assert {:error, _} = command("fleet.disconnect.v1", "ep_view", %{"id" => "ep_fleet"})
    assert command("core.shutdown.v1", "ep_anyone", %{}) == :exit
  end

  test "watching is not acting: subscribed agents and strangers cannot change anything" do
    for from <- ["ep_agent", "ep_stranger"],
        {type, payload} <- [
          {"fleet.remove.v1", %{"id" => "ep_dead"}},
          {"fleet.disconnect.v1", %{"id" => "ep_agent"}},
          {"fleet.shutdown.v1", %{"id" => "ep_agent"}},
          {"fleet.remove_offline.v1", %{}},
          {"fleet.broadcast.v1", %{"ids" => ["ep_agent"], "text" => "hi"}}
        ] do
      assert {:error, "only the fleet view" <> _} = command(type, from, payload)
    end

    # Anyone may unsubscribe itself; only the user may unsubscribe others.
    assert command("fleet.unsubscribe.v1", "ep_agent", %{}) == {:unsubscribe, "ep_agent"}
    assert {:error, _} = command("fleet.unsubscribe.v1", "ep_agent", %{"to" => "ep_view"})
  end

  test "broadcast goes only to online agents and needs text" do
    ids = ["ep_agent", "ep_agent_off", "ep_canvas", "ep_missing", "ep_agent"]

    assert command("fleet.broadcast.v1", "ep_view", %{"ids" => ids, "text" => "hi"}) ==
             {:broadcast, ["ep_agent"], "hi"}

    assert canvas("broadcast", %{"ids" => ids, "text" => "hi"}) ==
             {:broadcast, ["ep_agent"], "hi"}

    assert {:error, _} = command("fleet.broadcast.v1", "ep_view", %{"ids" => ids, "text" => "  "})

    assert {:error, "none of those agents is online"} =
             command("fleet.broadcast.v1", "ep_view", %{"ids" => ["ep_canvas"], "text" => "hi"})
  end

  test "rows mark subscribers as kept; history is newest first" do
    [row] =
      Fleet.rows(
        [%{"id" => "ep_v", "name" => "fleet view", "kind" => "tool", "online" => false}],
        %{"ep_v" => "fleet.state.v1"}
      )

    assert row.kept

    old = %{
      id: "b1",
      text: "first",
      sent_at: "t1",
      started: 1,
      sessions: [%{id: "a", name: "x", status: "acked", message_id: "m"}]
    }

    new = %{old | id: "b2", text: "second", started: 2}

    assert [
             %{broadcast: "b2", text: "second"},
             %{broadcast: "b1", sessions: [%{id: "a", name: "x", status: "acked"}]}
           ] =
             Fleet.history(%{"b1" => old, "b2" => new})
  end

  test "the canvas page inlines the view script" do
    page = Fleet.canvas_page()
    refute page =~ ~s(src="/fleet/app.js")
    assert page =~ "requestAction"
    assert page =~ ~s(<script>)
  end
end
