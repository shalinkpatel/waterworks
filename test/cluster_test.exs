defmodule WwClusterTest do
  use ExUnit.Case, async: false

  alias Ww.Message

  @moduletag :distributed
  @admin "test-admin-token"

  setup do
    unless Node.alive?() do
      raise "distributed tests need a named node; see README.md"
    end

    Enum.each([:ww_messages, :ww_counters, :ww_endpoints], fn table ->
      {:atomic, :ok} = :mnesia.clear_table(table)
    end)

    peer_name = :"ww_peer_#{System.unique_integer([:positive])}@127.0.0.1"
    cookie = Node.get_cookie() |> Atom.to_string() |> String.to_charlist()
    args = Enum.flat_map(:code.get_path(), &[~c"-pa", &1]) ++ [~c"-setcookie", cookie]
    {:ok, peer_pid, peer} = :peer.start_link(%{name: peer_name, args: args})
    peer_dir = Path.expand("../tmp/mnesia-#{peer}", __DIR__)
    File.rm_rf!(peer_dir)

    on_exit(fn ->
      File.rm_rf!(peer_dir)
      if Process.alive?(peer_pid), do: :peer.stop(peer_pid)
    end)

    :ok = :rpc.call(peer, Application, :load, [:ww])
    :ok = :rpc.call(peer, Application, :put_env, [:ww, :admin_token, @admin])
    :ok = :rpc.call(peer, Application, :put_env, [:ww, :mnesia_dir, peer_dir])
    :ok = :rpc.call(peer, Application, :put_env, [:ww, :join, node()])
    :ok = :rpc.call(peer, Application, :put_env, [:ww, :http, false])
    {:ok, _} = :rpc.call(peer, Application, :ensure_all_started, [:ww])
    :ok = :rpc.call(peer, Ww.Store, :setup, [])

    %{peer: peer}
  end

  test "mail queued on one node is delivered and acknowledged on another", %{peer: peer} do
    {:ok, agent, agent_token} =
      Ww.register_endpoint(%{kind: "agent", name: "origin-agent"}, @admin)

    {:ok, tool, tool_token} = Ww.register_endpoint(%{kind: "tool", name: "peer-tool"}, @admin)

    {:ok, sent} =
      Ww.send_message(agent.id, agent_token, tool.id, "ping.v1", %{"from" => "origin"})

    assert :rpc.call(peer, Ww.Store, :get_endpoint, [tool.id]) == Ww.Store.get_endpoint(tool.id)

    consumer =
      :rpc.call(peer, :erlang, :spawn, [
        Ww.TestRemoteConsumer,
        :start,
        [tool.id, tool_token, self()]
      ])

    true = is_pid(consumer)
    assert_receive {:ww_message, %Message{id: id}}, 1_000
    assert id == sent.id

    {:ok, [online]} = :rpc.call(peer, Ww, :discover, [agent.id, agent_token, %{name: tool.name}])
    assert online.online

    :ok = :rpc.call(peer, Ww, :acknowledge, [tool.id, tool_token, id])
    :ok = Ww.subscribe(tool.id, tool_token)
    refute_receive {:ww_message, _}, 100

    {:ok, replied} =
      :rpc.call(peer, Ww, :send_message, [
        agent.id,
        agent_token,
        tool.id,
        "pong.v1",
        %{"from" => "peer"},
        [reply_to: id]
      ])

    assert replied.sequence == 2
    assert_receive {:ww_message, %Message{id: reply_id, reply_to: ^id}}, 1_000
    assert reply_id == replied.id
  end
end
