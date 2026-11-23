defmodule WwTest do
  use ExUnit.Case, async: false

  alias Ww.Message

  @admin "test-admin-token"

  setup do
    Enum.each([:ww_messages, :ww_counters, :ww_endpoints], fn table ->
      {:atomic, :ok} = :mnesia.clear_table(table)
    end)

    :ok
  end

  test "registration, discovery, and scoped authentication" do
    assert {:error, :unauthorized} = Ww.register_endpoint(%{kind: "tool", name: "bad"}, "wrong")
    {agent, agent_token} = endpoint!("agent", "agent")
    {tool, _tool_token} = endpoint!("tool", "counter", ["counter.set.v1"], %{workspace: "ww"})

    assert {:ok, [found]} =
             Ww.discover(agent.id, agent_token, %{
               kind: "tool",
               accepts: "counter.set.v1",
               metadata: %{workspace: "ww"}
             })

    assert found.id == tool.id
    refute found.online
    refute Map.has_key?(found, :token_hash)

    assert {:error, :unauthorized} =
             Ww.send_message(tool.id, agent_token, agent.id, "counter.set.v1", %{value: 1})

    assert {:error, :unauthorized} = Ww.discover(tool.id, "wrong")

    assert {:ok, _message} =
             Ww.send_message(agent.id, agent_token, tool.id, "counter.set.v1", %{value: 1})

    assert {:ok, []} = Ww.discover(agent.id, agent_token, %{name: "missing"})
  end

  test "messages are indexed by recipient" do
    assert :mnesia.table_info(:ww_messages, :index) != []
  end

  test "direct delivery, acknowledgement, and history" do
    {agent, agent_token} = endpoint!("agent", "agent")
    {tool, tool_token} = endpoint!("tool", "tool")

    assert {:error, :recipient_not_found} =
             Ww.send_message(agent.id, agent_token, "ep_missing", "ping.v1", %{})

    :ok = Ww.subscribe(tool.id, tool_token)

    assert {:ok, sent} =
             Ww.send_message(agent.id, agent_token, tool.id, "ping.v1", %{"value" => 1},
               reply_to: "msg_parent"
             )

    assert sent.v == 1
    assert sent.sequence == 1
    assert sent.reply_to == "msg_parent"
    assert_receive {:ww_message, %Message{} = delivered}
    assert delivered == sent

    :ok = Ww.acknowledge(tool.id, tool_token, delivered.id)
    :ok = Ww.subscribe(tool.id, tool_token)
    refute_receive {:ww_message, _}, 50
    assert {:ok, [^delivered]} = Ww.history(tool.id, tool_token)
  end

  test "offline messages redeliver until acknowledged" do
    {agent, agent_token} = endpoint!("agent", "agent")
    {tool, tool_token} = endpoint!("tool", "tool")

    {:ok, sent} = Ww.send_message(agent.id, agent_token, tool.id, "work.v1", %{"n" => 1})
    parent = self()

    consumer =
      spawn(fn ->
        receive do
          message -> send(parent, message)
        end
      end)

    :ok = Ww.subscribe(tool.id, tool_token, consumer)
    assert_receive {:ww_message, %Message{id: id}}, 500
    assert id == sent.id
    Process.exit(consumer, :kill)

    :ok = Ww.subscribe(tool.id, tool_token)
    assert_receive {:ww_message, %Message{id: ^id}}, 500
    :ok = Ww.acknowledge(tool.id, tool_token, id)
    :ok = Ww.subscribe(tool.id, tool_token)
    refute_receive {:ww_message, _}, 50
  end

  test "a replacement subscriber removes the previous connection's presence" do
    {_agent, _agent_token} = endpoint!("agent", "agent")
    {tool, tool_token} = endpoint!("tool", "tool")

    previous = spawn(fn -> Process.sleep(:infinity) end)
    :ok = Ww.subscribe(tool.id, tool_token, previous)
    :ok = Ww.subscribe(tool.id, tool_token)

    assert :pg.get_members(:ww, {:endpoint, tool.id}) == [self()]
    Process.exit(previous, :kill)
  end

  test "a supervised mailbox restores its live subscription after a crash" do
    {agent, agent_token} = endpoint!("agent", "agent")
    {tool, tool_token} = endpoint!("tool", "tool")
    {:ok, sent} = Ww.send_message(agent.id, agent_token, tool.id, "work.v1", %{})

    :ok = Ww.subscribe(tool.id, tool_token)
    assert_receive {:ww_message, %Message{id: id}}, 500
    assert id == sent.id

    mailbox = :global.whereis_name({:ww_mailbox, tool.id})
    Process.exit(mailbox, :kill)

    assert_receive {:ww_message, %Message{id: ^id}}, 500
    :ok = Ww.acknowledge(tool.id, tool_token, id)
  end

  test "pending mail survives application and Mnesia restart" do
    {agent, agent_token} = endpoint!("agent", "agent")
    {tool, tool_token} = endpoint!("tool", "tool")
    {:ok, sent} = Ww.send_message(agent.id, agent_token, tool.id, "offline.v1", %{})

    :ok = Application.stop(:ww)
    :stopped = :mnesia.stop()
    {:ok, _} = Application.ensure_all_started(:ww)

    :ok = Ww.subscribe(tool.id, tool_token)
    assert_receive {:ww_message, %Message{id: id}}, 500
    assert id == sent.id
    :ok = Ww.acknowledge(tool.id, tool_token, id)
  end

  test "per-mailbox ordering and idempotent message IDs" do
    {agent, agent_token} = endpoint!("agent", "agent")
    {tool, tool_token} = endpoint!("tool", "tool")

    for n <- 1..3 do
      assert {:ok, _} =
               Ww.send_message(agent.id, agent_token, tool.id, "step.v1", %{"n" => n},
                 id: "msg_ordered_#{n}"
               )
    end

    assert {:ok, retried} =
             Ww.send_message(agent.id, agent_token, tool.id, "step.v1", %{"n" => 3},
               id: "msg_ordered_3"
             )

    assert retried.sequence == 3

    assert {:error, :message_id_conflict} =
             Ww.send_message(agent.id, agent_token, tool.id, "step.v1", %{"n" => 99},
               id: "msg_ordered_3"
             )

    :ok = Ww.subscribe(tool.id, tool_token)

    for n <- 1..3 do
      assert_receive {:ww_message, %Message{sequence: ^n, payload: %{"n" => ^n}}}
    end

    refute_receive {:ww_message, _}, 50
  end

  defp endpoint!(kind, name, accepts \\ [], metadata \\ %{}) do
    {:ok, endpoint, token} =
      Ww.register_endpoint(
        %{kind: kind, name: name, accepts: accepts, emits: [], metadata: metadata},
        @admin
      )

    {endpoint, token}
  end
end
