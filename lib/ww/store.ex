defmodule Ww.Store do
  @moduledoc false

  alias Ww.{Endpoint, Message}

  @tables [:ww_endpoints, :ww_counters, :ww_messages]

  def setup do
    dir = mnesia_dir()
    File.mkdir_p!(dir)
    # Message history is plaintext; keep it private to the daemon's user.
    File.chmod!(dir, 0o700)
    Application.put_env(:mnesia, :dir, String.to_charlist(dir))

    join =
      case Application.get_env(:ww, :join) do
        nil -> nil
        "" -> nil
        value when is_binary(value) -> String.to_atom(value)
        value when is_atom(value) -> value
      end

    schema_exists = File.exists?(Path.join(dir, "schema.DAT"))
    join? = join != nil && join != node()

    if join? and not Node.alive?() do
      raise "WW_JOIN requires a distributed Erlang node"
    end

    if join? and Node.connect(join) != true do
      raise "could not connect to WW_JOIN node #{inspect(join)}"
    end

    if :mnesia.system_info(:is_running) != :yes do
      cond do
        join? && !schema_exists ->
          :ok = :mnesia.start()
          join_storage(join)

        !schema_exists ->
          case :mnesia.create_schema([node()]) do
            :ok -> :ok
            {:error, {_, {:already_exists, _}}} -> :ok
            {:error, reason} -> raise "could not create Mnesia schema: #{inspect(reason)}"
          end

          :ok = :mnesia.start()
          create_tables()

        true ->
          :ok = :mnesia.start()
          if join?, do: join_storage(join), else: create_tables()
      end
    else
      if join?, do: join_storage(join), else: create_tables()
    end

    case :mnesia.wait_for_tables(@tables, 15_000) do
      :ok -> :ok
      {:timeout, tables} -> raise "Mnesia tables did not load: #{inspect(tables)}"
      {:error, reason} -> raise "Mnesia tables failed to load: #{inspect(reason)}"
    end
  end

  def put_endpoint(%Endpoint{} = endpoint) do
    {:atomic, :ok} =
      :mnesia.transaction(fn -> :mnesia.write({:ww_endpoints, endpoint.id, endpoint}) end)

    :ok
  end

  @doc "Deletes an endpoint, its mailbox messages, and its sequence counter in one transaction."
  def delete_endpoint(id) do
    {:atomic, result} =
      :mnesia.transaction(fn ->
        case :mnesia.read(:ww_endpoints, id, :write) do
          [] ->
            :not_found

          [_] ->
            :mnesia.delete({:ww_endpoints, id})
            :mnesia.delete({:ww_counters, id})

            {:ww_messages, :_, :_, id, :_, :_, :_, :_, :_, :_}
            |> :mnesia.match_object()
            |> Enum.each(&:mnesia.delete({:ww_messages, elem(&1, 1)}))

            :ok
        end
      end)

    if result == :ok, do: :ok, else: {:error, result}
  end

  def get_endpoint(id) do
    case :mnesia.dirty_read(:ww_endpoints, id) do
      [{:ww_endpoints, ^id, endpoint}] -> endpoint
      [] -> nil
    end
  end

  def list_endpoints do
    :mnesia.dirty_match_object({:ww_endpoints, :_, :_})
    |> Enum.map(fn {:ww_endpoints, _, endpoint} -> endpoint end)
    |> Enum.sort_by(& &1.id)
  end

  def append(id, from, to, type, payload, reply_to) do
    result =
      :mnesia.transaction(fn ->
        case :mnesia.read(:ww_messages, id, :write) do
          [record] ->
            message = to_message(record)

            if message.from == from && message.to == to && message.type == type &&
                 message.payload == payload && message.reply_to == reply_to do
              {message, false}
            else
              :mnesia.abort(:message_id_conflict)
            end

          [] ->
            sequence = next_sequence(to)

            message = %Message{
              id: id,
              from: from,
              to: to,
              type: type,
              payload: payload,
              reply_to: reply_to,
              received_at: DateTime.utc_now() |> DateTime.truncate(:millisecond),
              sequence: sequence
            }

            :mnesia.write(to_record(message, :pending))
            {message, true}
        end
      end)

    case result do
      {:atomic, {message, created?}} -> {:ok, message, created?}
      {:aborted, reason} -> {:error, reason}
    end
  end

  def pending(to), do: messages_for(to, :pending)
  def history(to), do: messages_for(to, :all)

  def ack(to, id) do
    result =
      :mnesia.transaction(fn ->
        case :mnesia.read(:ww_messages, id, :write) do
          [{:ww_messages, ^id, _, ^to, _, _, _, _, _, :pending} = record] ->
            :mnesia.write(to_record(to_message(record), :acked))
            :ok

          [{:ww_messages, ^id, _, ^to, _, _, _, _, _, :acked}] ->
            :ok

          _ ->
            :mnesia.abort(:not_found)
        end
      end)

    case result do
      {:atomic, :ok} -> :ok
      {:aborted, reason} -> {:error, reason}
    end
  end

  defp messages_for(to, status) do
    # Uses the recipient index (see create_tables); stores created without it fall back to a scan.
    pattern = {:ww_messages, :_, :_, to, :_, :_, :_, :_, :_, :_}
    # Transactional so a node reads messages just committed elsewhere in the cluster.
    {:atomic, records} = :mnesia.transaction(fn -> :mnesia.match_object(pattern) end)

    records
    |> Enum.filter(&(status == :all || elem(&1, 9) == status))
    |> Enum.map(&to_message/1)
    |> Enum.sort_by(& &1.sequence)
  end

  defp next_sequence(to) do
    sequence =
      case :mnesia.read(:ww_counters, to, :write) do
        [] -> 1
        [{:ww_counters, ^to, current}] -> current + 1
      end

    :mnesia.write({:ww_counters, to, sequence})
    sequence
  end

  defp to_record(%Message{} = message, status) do
    {:ww_messages, message.id, message.from, message.to, message.type, message.payload,
     message.reply_to, message.received_at, message.sequence, status}
  end

  defp to_message(
         {:ww_messages, id, from, to, type, payload, reply_to, received_at, sequence, _status}
       ) do
    %Message{
      id: id,
      from: from,
      to: to,
      type: type,
      payload: payload,
      reply_to: reply_to,
      received_at: received_at,
      sequence: sequence
    }
  end

  defp create_tables do
    create_table(:ww_endpoints, [:id, :endpoint])
    create_table(:ww_counters, [:mailbox, :sequence])

    # Indexed by recipient so mailbox reads do not scan every stored message.
    create_table(
      :ww_messages,
      [:id, :from, :to, :type, :payload, :reply_to, :received_at, :sequence, :status],
      index: [:to]
    )
  end

  defp create_table(name, attributes, opts \\ []) do
    case :mnesia.create_table(name, [attributes: attributes, disc_copies: [node()]] ++ opts) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, ^name}} -> :ok
      {:aborted, reason} -> raise "could not create #{name}: #{inspect(reason)}"
    end
  end

  defp join_storage(peer) do
    case :mnesia.change_config(:extra_db_nodes, [peer]) do
      {:ok, nodes} when is_list(nodes) -> :ok
      {:error, reason} -> raise "could not join Mnesia cluster: #{inspect(reason)}"
    end

    if :mnesia.table_info(:schema, :storage_type) == :ram_copies do
      {:atomic, :ok} = :mnesia.change_table_copy_type(:schema, node(), :disc_copies)
    end

    Enum.each(@tables, fn table ->
      case :mnesia.add_table_copy(table, node(), :disc_copies) do
        {:atomic, :ok} -> :ok
        {:aborted, {:already_exists, ^table, _}} -> :ok
        {:aborted, {_, :already_exists, _}} -> :ok
        {:aborted, reason} -> raise "could not copy #{table}: #{inspect(reason)}"
      end
    end)
  end

  defp mnesia_dir do
    Application.get_env(:ww, :mnesia_dir) ||
      Path.join([
        System.get_env("XDG_STATE_HOME") || Path.join(System.user_home!(), ".local/state"),
        "waterworks",
        Atom.to_string(node()),
        "mnesia"
      ])
  end
end
