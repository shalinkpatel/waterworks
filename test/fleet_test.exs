defmodule WwFleetTest do
  use ExUnit.Case, async: true

  alias Ww.Fleet

  test "rows map type, status and cwd, inferring type for older endpoints, sorted by id" do
    endpoints = [
      %{
        "id" => "ep_b",
        "name" => "fix auth",
        "kind" => "agent",
        "online" => true,
        "metadata" => %{"cwd" => "/w", "harness" => "claude"}
      },
      %{
        "id" => "ep_a",
        "name" => "page",
        "kind" => "tool",
        "online" => false,
        "metadata" => %{},
        "accepts" => ["canvas.render.v1"]
      },
      %{
        "id" => "ep_c",
        "name" => "ww",
        "kind" => "agent",
        "online" => false,
        "metadata" => %{},
        "accepts" => ["demo.echo.v1"]
      },
      %{
        "id" => "ep_d",
        "name" => "x",
        "kind" => "tool",
        "online" => false,
        "metadata" => %{"tool" => "fleet"}
      },
      %{
        "id" => "ep_e",
        "name" => "old",
        "kind" => "tool",
        "online" => false,
        "metadata" => %{},
        "accepts" => ["dashboard.render.v1"]
      }
    ]

    assert Enum.map(Fleet.rows(endpoints), &{&1.id, &1.type, &1.status, &1.cwd}) == [
             {"ep_a", "canvas", "offline", ""},
             {"ep_b", "claude", "online", "/w"},
             {"ep_c", "pi", "offline", ""},
             {"ep_d", "fleet", "offline", ""},
             {"ep_e", "dashboard (legacy)", "offline", ""}
           ]
  end

  @endpoints [
    %{"id" => "ep_agent", "accepts" => ["demo.echo.v1"], "online" => true},
    %{"id" => "ep_canvas", "accepts" => ["canvas.data.v1"], "online" => true},
    %{"id" => "ep_view", "accepts" => ["fleet.state.v1"], "online" => true},
    %{"id" => "ep_dead", "accepts" => [], "online" => false},
    %{"id" => "ep_fleet", "accepts" => [], "online" => true}
  ]

  defp command(type, from, payload, subscribers \\ %{}),
    do:
      Fleet.command(
        %{"type" => type, "from" => from, "payload" => payload},
        subscribers,
        @endpoints,
        "ep_fleet"
      )

  test "subscribe: canvases get canvas.data.v1, a sender can subscribe itself, nothing else" do
    assert command("fleet.subscribe.v1", "ep_agent", %{"to" => "ep_canvas"}) ==
             {:subscribe, "ep_canvas", "canvas.data.v1"}

    assert command("fleet.subscribe.v1", "ep_view", %{}) ==
             {:subscribe, "ep_view", "fleet.state.v1"}

    assert command("fleet.subscribe.v1", "ep_agent", %{"to" => "ep_view"}) == :ignore
    assert command("fleet.subscribe.v1", "ep_agent", %{"to" => "ep_missing"}) == :ignore
  end

  test "remove (offline), disconnect and shutdown (online): subscribers only, never the fleet" do
    subs = %{"ep_view" => "fleet.state.v1", "ep_canvas" => "canvas.data.v1"}

    canvas = fn action, id ->
      command("canvas.action.v1", "ep_canvas", %{"action" => action, "id" => id}, subs)
    end

    assert command("fleet.remove.v1", "ep_view", %{"id" => "ep_dead"}, subs) ==
             {:remove, "ep_dead"}

    assert canvas.("remove", "ep_dead") == {:remove, "ep_dead"}

    assert command("fleet.disconnect.v1", "ep_view", %{"id" => "ep_agent"}, subs) ==
             {:remove, "ep_agent"}

    assert canvas.("disconnect", "ep_agent") == {:remove, "ep_agent"}

    assert command("fleet.shutdown.v1", "ep_view", %{"id" => "ep_agent"}, subs) ==
             {:shutdown, "ep_agent"}

    assert canvas.("shutdown", "ep_agent") == {:shutdown, "ep_agent"}

    # Wrong state for the action, not a subscriber, unknown target, or unknown action.
    assert command("fleet.remove.v1", "ep_view", %{"id" => "ep_agent"}, subs) == :ignore
    assert command("fleet.disconnect.v1", "ep_view", %{"id" => "ep_dead"}, subs) == :ignore
    assert command("fleet.shutdown.v1", "ep_view", %{"id" => "ep_dead"}, subs) == :ignore
    assert command("fleet.disconnect.v1", "ep_agent", %{"id" => "ep_canvas"}, subs) == :ignore
    assert command("fleet.remove.v1", "ep_view", %{"id" => "ep_missing"}, subs) == :ignore
    assert canvas.("nuke", "ep_dead") == :ignore

    # The fleet exits on a shutdown (its own, or core.shutdown.v1), but is never removed.
    assert command("fleet.shutdown.v1", "ep_view", %{"id" => "ep_fleet"}, subs) == :exit
    assert command("fleet.disconnect.v1", "ep_view", %{"id" => "ep_fleet"}, subs) == :ignore
    assert command("core.shutdown.v1", "ep_anyone", %{}, subs) == :exit
  end

  test "remove_offline: every offline endpoint except current subscribers, subscribers only" do
    endpoints = @endpoints ++ [%{"id" => "ep_old_view", "accepts" => [], "online" => false}]

    subs = %{
      "ep_view" => "fleet.state.v1",
      "ep_old_view" => "fleet.state.v1",
      "ep_canvas" => "canvas.data.v1"
    }

    run = fn type, from, payload ->
      Fleet.command(
        %{"type" => type, "from" => from, "payload" => payload},
        subs,
        endpoints,
        "ep_fleet"
      )
    end

    assert run.("fleet.remove_offline.v1", "ep_view", %{}) == {:remove_all, ["ep_dead"]}

    assert run.("canvas.action.v1", "ep_canvas", %{"action" => "remove_offline"}) ==
             {:remove_all, ["ep_dead"]}

    assert run.("fleet.remove_offline.v1", "ep_agent", %{}) == :ignore
  end

  test "broadcast: only from the fleet's own view, only to online agents, non-empty text" do
    endpoints = [
      %{"id" => "ep_pi", "kind" => "agent", "online" => true},
      %{"id" => "ep_pi_off", "kind" => "agent", "online" => false},
      %{"id" => "ep_tool", "kind" => "tool", "online" => true}
    ]

    subs = %{"ep_view" => "fleet.state.v1", "ep_canvas" => "canvas.data.v1"}

    run = fn type, from, payload ->
      Fleet.command(
        %{"type" => type, "from" => from, "payload" => payload},
        subs,
        endpoints,
        "ep_fleet",
        "ep_view"
      )
    end

    ids = ["ep_pi", "ep_pi_off", "ep_tool", "ep_missing", "ep_pi"]

    assert run.("fleet.broadcast.v1", "ep_view", %{"ids" => ids, "text" => "hi"}) ==
             {:broadcast, ["ep_pi"], "hi"}

    assert run.("fleet.broadcast.v1", "ep_canvas", %{"ids" => ids, "text" => "hi"}) == :ignore

    assert run.("canvas.action.v1", "ep_canvas", %{
             "action" => "broadcast",
             "ids" => ids,
             "text" => "hi"
           }) == :ignore

    assert run.("fleet.broadcast.v1", "ep_view", %{"ids" => ids, "text" => "  "}) == :ignore

    assert run.("fleet.broadcast.v1", "ep_view", %{"ids" => ["ep_tool"], "text" => "hi"}) ==
             :ignore
  end

  test "the canvas page inlines the view script" do
    page = Fleet.canvas_page()
    refute page =~ ~s(src="/fleet/app.js")
    assert page =~ "requestAction"
  end
end
