defmodule WwLogTransportTest do
  # Runs `ww log` against the test daemon and checks who may do what over the real protocol.
  use Ww.TransportCase, async: false

  @moduletag :tmp_dir

  test "authors revise, only the user reviews, and a canvas reviews through canvas.action.v1",
       %{tmp_dir: dir} do
    alice = register!("agent", "alice", ["log.receipt.v1"])
    bob = register!("agent", "bob")
    start_tool(fn -> Ww.Log.run(dir, false) end)
    log = wait_for_endpoint(alice, "log.submit.v1")

    assert %{"type" => "log.receipt.v1", "payload" => %{"entry" => entry}} =
             ask(alice, log, "log.submit.v1", %{title: "Bench result", tags: ["bench"]})

    # Only the submitting endpoint may revise.
    assert %{"type" => "core.error.v1", "payload" => %{"error" => "only the endpoint" <> _}} =
             ask(bob, log, "log.revise.v1", %{entry: entry, title: "Mine now"})

    assert %{"type" => "log.receipt.v1"} =
             ask(alice, log, "log.revise.v1", %{entry: entry, body: "3 runs"})

    # Agents cannot review, even their own entries.
    assert %{"type" => "core.error.v1", "payload" => %{"error" => "only the log view" <> _}} =
             ask(alice, log, "log.review.v1", %{entry: entry, decision: "approve"})

    # A subscribed canvas reviews like the view: its action and the decision do not collide.
    {canvas_id, _} = canvas = register!("tool", "canvas", ["canvas.data.v1"])
    send_raw(alice, log, "log.subscribe.v1", %{to: canvas_id})
    wait_until(fn -> Enum.any?(history(canvas), &(&1["type"] == "canvas.data.v1")) end)

    send_raw(canvas, log, "canvas.action.v1", %{
      action: "review",
      entry: entry,
      decision: "approve"
    })

    wait_until(fn ->
      %{"payload" => %{"entries" => [%{"status" => status}]}} =
        ask(alice, log, "log.query.v1", %{})

      status == "approved"
    end)

    # Replies to a canvas ride on canvas.data.v1 {reply}.
    send_raw(canvas, log, "canvas.action.v1", %{
      action: "review",
      entry: "log_missing",
      decision: "approve"
    })

    assert %{
             "payload" => %{
               "reply" => %{
                 "type" => "core.error.v1",
                 "payload" => %{"error" => "no entry log_missing"}
               }
             }
           } =
             wait_until(fn -> Enum.find(history(canvas), &get_in(&1, ["payload", "reply"])) end)

    # The canvas page cannot subscribe itself (and so cannot make itself a reviewer).
    page = register!("tool", "other canvas", ["canvas.data.v1"])

    assert %{
             "type" => "core.error.v1",
             "payload" => %{"error" => "unsupported: canvas.action.v1"}
           } =
             ask(page, log, "canvas.action.v1", %{action: "subscribe"})
  end
end
