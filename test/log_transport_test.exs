defmodule WwLogTransportTest do
  # Runs `ww log` against the test daemon and checks who may do what over the real protocol.
  use ExUnit.Case, async: false

  alias Ww.TestHTTP

  @moduletag :transport
  @moduletag :tmp_dir
  @admin "test-admin-token"

  setup %{tmp_dir: dir} do
    Enum.each([:ww_messages, :ww_counters, :ww_endpoints], fn table ->
      {:atomic, :ok} = :mnesia.clear_table(table)
    end)

    System.put_env("WW_URL", "http://127.0.0.1:17420")
    System.put_env("WW_ADMIN_TOKEN", @admin)
    pid = spawn(fn -> Ww.Log.run(dir, false) end)

    on_exit(fn ->
      Process.exit(pid, :kill)
      System.delete_env("WW_URL")
      System.delete_env("WW_ADMIN_TOKEN")
    end)

    {:ok, dir: dir}
  end

  test "authors revise, only the user reviews, and a canvas reviews through canvas.action.v1" do
    {alice, alice_token} = register("agent", "alice", ["log.receipt.v1"])
    {bob, bob_token} = register("agent", "bob", [])
    log = wait_for_log(alice, alice_token)

    submit =
      ask(alice, alice_token, log, "log.submit.v1", %{title: "Bench result", tags: ["bench"]})

    assert %{"type" => "log.receipt.v1", "payload" => %{"entry" => entry}} = submit

    # Only the submitting endpoint may revise.
    assert %{"type" => "core.error.v1", "payload" => %{"error" => "only the endpoint" <> _}} =
             ask(bob, bob_token, log, "log.revise.v1", %{entry: entry, title: "Mine now"})

    assert %{"type" => "log.receipt.v1"} =
             ask(alice, alice_token, log, "log.revise.v1", %{entry: entry, body: "3 runs"})

    # Agents cannot review, even their own entries.
    assert %{"type" => "core.error.v1", "payload" => %{"error" => "only the log view" <> _}} =
             ask(alice, alice_token, log, "log.review.v1", %{entry: entry, decision: "approve"})

    # A subscribed canvas reviews like the view: its action and the decision do not collide.
    {canvas, canvas_token} = register("tool", "canvas", ["canvas.data.v1"])
    send_as(alice, alice_token, log, "log.subscribe.v1", %{to: canvas})

    wait_until(fn ->
      history(canvas, canvas_token) |> Enum.any?(&(&1["type"] == "canvas.data.v1"))
    end)

    send_as(canvas, canvas_token, log, "canvas.action.v1", %{
      action: "review",
      entry: entry,
      decision: "approve"
    })

    wait_until(fn ->
      %{"payload" => %{"entries" => [%{"status" => status}]}} =
        ask(alice, alice_token, log, "log.query.v1", %{})

      status == "approved"
    end)

    # The canvas page cannot subscribe itself (and so cannot make itself a reviewer).
    {page, page_token} = register("tool", "other canvas", ["canvas.data.v1"])

    send_raw(
      page,
      page_token,
      log,
      "canvas.action.v1",
      %{action: "subscribe"},
      "msg_subscribe_self"
    )

    assert %{
             "type" => "core.error.v1",
             "payload" => %{"error" => "unsupported: canvas.action.v1"}
           } =
             await_reply(page, page_token, "msg_subscribe_self")
  end

  defp register(kind, name, accepts) do
    {201, %{"endpoint" => %{"id" => id}, "token" => token}} =
      TestHTTP.request(:post, "/v1/endpoints", %{kind: kind, name: name, accepts: accepts}, [
        {"x-ww-admin-token", @admin}
      ])

    {id, token}
  end

  defp wait_for_log(id, token) do
    wait_until(fn ->
      {200, %{"endpoints" => found}} =
        TestHTTP.request(
          :get,
          "/v1/endpoints?accepts=log.submit.v1&online=true",
          nil,
          TestHTTP.auth(id, token)
        )

      case found do
        [%{"id" => log}] -> log
        _ -> false
      end
    end)
  end

  defp send_as(id, token, to, type, payload),
    do: send_raw(id, token, to, type, payload, "msg_#{System.unique_integer([:positive])}")

  defp send_raw(id, token, to, type, payload, message_id) do
    {201, _} =
      TestHTTP.request(
        :post,
        "/v1/messages",
        %{id: message_id, to: to, type: type, payload: payload},
        TestHTTP.auth(id, token)
      )

    message_id
  end

  defp ask(id, token, to, type, payload) do
    message_id = "msg_#{System.unique_integer([:positive])}"
    send_raw(id, token, to, type, payload, message_id)
    await_reply(id, token, message_id)
  end

  defp await_reply(id, token, message_id) do
    wait_until(fn -> Enum.find(history(id, token), &(&1["reply_to"] == message_id)) end)
  end

  defp history(id, token) do
    {200, %{"messages" => messages}} =
      TestHTTP.request(:get, "/v1/endpoints/#{id}/history", nil, TestHTTP.auth(id, token))

    messages
  end

  defp wait_until(fun, attempts \\ 100) do
    case fun.() do
      result when result in [nil, false] and attempts > 0 ->
        Process.sleep(50)
        wait_until(fun, attempts - 1)

      result when result in [nil, false] ->
        flunk("timed out waiting")

      result ->
        result
    end
  end
end
