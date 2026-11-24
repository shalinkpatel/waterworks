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
    %{"id" => "ep_dead", "accepts" => [], "online" => false}
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

  test "remove: only subscribers, only existing offline endpoints, never the fleet" do
    subs = %{"ep_view" => "fleet.state.v1", "ep_canvas" => "canvas.data.v1"}

    assert command("fleet.remove.v1", "ep_view", %{"id" => "ep_dead"}, subs) ==
             {:remove, "ep_dead"}

    assert command(
             "canvas.action.v1",
             "ep_canvas",
             %{"action" => "remove", "id" => "ep_dead"},
             subs
           ) ==
             {:remove, "ep_dead"}

    assert command("fleet.remove.v1", "ep_agent", %{"id" => "ep_dead"}, subs) == :ignore
    assert command("fleet.remove.v1", "ep_view", %{"id" => "ep_agent"}, subs) == :ignore
    assert command("fleet.remove.v1", "ep_view", %{"id" => "ep_fleet"}, subs) == :ignore

    assert command(
             "canvas.action.v1",
             "ep_canvas",
             %{"action" => "nuke", "id" => "ep_dead"},
             subs
           ) == :ignore
  end

  test "the canvas page inlines the view script" do
    page = Fleet.canvas_page()
    refute page =~ ~s(src="/fleet/app.js")
    assert page =~ "fleet.remove.v1"
  end
end
