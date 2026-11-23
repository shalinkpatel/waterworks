defmodule Ww.Mailbox do
  @moduledoc false
  use GenServer

  alias Ww.Store

  def subscribe(id, pid) do
    with {:ok, mailbox} <- ensure_started(id) do
      GenServer.call(mailbox, {:subscribe, pid})
    end
  end

  def notify(id) do
    case :global.whereis_name({:ww_mailbox, id}) do
      :undefined -> :ok
      pid -> GenServer.cast(pid, :notify)
    end
  end

  defp ensure_started(id) do
    case :global.whereis_name({:ww_mailbox, id}) do
      :undefined ->
        case DynamicSupervisor.start_child(Ww.MailboxSupervisor, {__MODULE__, id}) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            {:ok, pid}

          {:error, _reason} ->
            case :global.whereis_name({:ww_mailbox, id}) do
              :undefined -> {:error, :mailbox_unavailable}
              pid -> {:ok, pid}
            end
        end

      pid ->
        {:ok, pid}
    end
  end

  def start_link(id) do
    GenServer.start_link(__MODULE__, id, name: {:global, {:ww_mailbox, id}})
  end

  @impl true
  def init(id) do
    subscriber = :pg.get_members(:ww, {:endpoint, id}) |> List.first()
    monitor = if subscriber, do: Process.monitor(subscriber)

    state = %{id: id, subscriber: subscriber, monitor: monitor, delivered: MapSet.new()}
    {:ok, state, {:continue, :restore}}
  end

  @impl true
  def handle_continue(:restore, state), do: {:noreply, deliver_pending(state)}

  @impl true
  def handle_call({:subscribe, pid}, _from, %{subscriber: pid} = state),
    do: {:reply, :ok, state}

  def handle_call({:subscribe, pid}, _from, state) do
    if state.monitor, do: Process.demonitor(state.monitor, [:flush])
    if state.subscriber, do: remove_presence(state.id, state.subscriber)
    monitor = Process.monitor(pid)
    state = %{state | subscriber: pid, monitor: monitor, delivered: MapSet.new()}
    {:reply, :ok, deliver_pending(state)}
  end

  @impl true
  def handle_cast(:notify, state), do: {:noreply, deliver_pending(state)}

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{monitor: monitor} = state) do
    {:noreply, %{state | subscriber: nil, monitor: nil, delivered: MapSet.new()}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp remove_presence(id, subscriber) do
    if node(subscriber) == node() do
      :pg.leave(:ww, {:endpoint, id}, subscriber)
    else
      :rpc.call(node(subscriber), :pg, :leave, [:ww, {:endpoint, id}, subscriber])
    end
  end

  defp deliver_pending(%{subscriber: nil} = state), do: state

  defp deliver_pending(state) do
    pending = Store.pending(state.id)
    pending_ids = MapSet.new(pending, & &1.id)
    delivered = MapSet.intersection(state.delivered, pending_ids)

    delivered =
      Enum.reduce(pending, delivered, fn message, seen ->
        if MapSet.member?(seen, message.id) do
          seen
        else
          send(state.subscriber, {:ww_message, message})
          MapSet.put(seen, message.id)
        end
      end)

    %{state | delivered: delivered}
  end
end
