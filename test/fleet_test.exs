defmodule WwFleetTest do
  use ExUnit.Case, async: true

  test "rows drop the canvas itself, map type, status and cwd, and sort by id" do
    endpoints = [
      %{
        "id" => "ep_b",
        "name" => "pi-1",
        "kind" => "agent",
        "online" => true,
        "metadata" => %{"cwd" => "/w", "harness" => "claude"}
      },
      %{
        "id" => "ep_self",
        "name" => "Waterworks fleet",
        "kind" => "tool",
        "online" => true,
        "metadata" => %{}
      },
      %{
        "id" => "ep_a",
        "name" => "dash",
        "kind" => "tool",
        "online" => false,
        "metadata" => %{},
        "accepts" => ["canvas.render.v1"]
      },
      %{
        "id" => "ep_c",
        "name" => "pi-9",
        "kind" => "agent",
        "online" => false,
        "metadata" => %{}
      },
      %{
        "id" => "ep_d",
        "name" => "x",
        "kind" => "tool",
        "online" => false,
        "metadata" => %{"tool" => "echo"}
      }
    ]

    assert Ww.Fleet.rows(endpoints, "ep_self") == [
             %{
               id: "ep_a",
               name: "dash",
               kind: "tool",
               type: "canvas",
               status: "offline",
               cwd: ""
             },
             %{
               id: "ep_b",
               name: "pi-1",
               kind: "agent",
               type: "claude",
               status: "online",
               cwd: "/w"
             },
             %{id: "ep_c", name: "pi-9", kind: "agent", type: "pi", status: "offline", cwd: ""},
             %{id: "ep_d", name: "x", kind: "tool", type: "echo", status: "offline", cwd: ""}
           ]
  end

  test "removals are honoured only for existing offline endpoints other than the canvas" do
    endpoints = [%{"id" => "ep_dead", "online" => false}, %{"id" => "ep_live", "online" => true}]
    assert Ww.Fleet.removable?(%{"action" => "remove", "id" => "ep_dead"}, endpoints, "ep_self")
    refute Ww.Fleet.removable?(%{"action" => "remove", "id" => "ep_live"}, endpoints, "ep_self")
    refute Ww.Fleet.removable?(%{"action" => "remove", "id" => "ep_gone"}, endpoints, "ep_self")
    refute Ww.Fleet.removable?(%{"action" => "remove", "id" => "ep_dead"}, endpoints, "ep_dead")
    refute Ww.Fleet.removable?(%{"action" => "nuke", "id" => "ep_dead"}, endpoints, "ep_self")
  end
end
