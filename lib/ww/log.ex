defmodule Ww.Log do
  @moduledoc """
  `ww log`: a work log with a review queue. Agents (and the user) submit entries; the user
  approves, rejects or requests changes, which go back to the author as a prompt. Entries
  persist in `Ww.Log.Store` and are restored on launch; the endpoint id changes per launch,
  so agents find it by discovery (accepts `log.submit.v1`). The message protocol is in the
  README ("Example tool: log").
  """

  alias Ww.Tool
  alias Ww.Log.{Entry, Store}

  @doc "The log view as one self-contained page, for publishing into a canvas."
  def canvas_page, do: Tool.canvas_page("/log")

  def default_dir do
    base = System.get_env("XDG_STATE_HOME") || Path.join(System.user_home!(), ".local/state")
    Path.join([base, "waterworks", "log"])
  end

  @doc "Runs until the log's endpoint is deregistered."
  def run(dir, open?) do
    store = Store.open(dir)
    IO.puts(:stderr, "log store: #{dir} (#{length(Store.load_all(store))} entries)")
    %{tool: tool, viewer: viewer} = Tool.start("log", endpoint(), viewer_endpoint(), open?)

    state = %{
      store: store,
      headers: tool.headers,
      id: tool.id,
      viewer: viewer.id,
      subscribers: %{viewer.id => "log.state.v1"}
    }

    Tool.follow(tool)
    loop(state)
  end

  defp endpoint do
    %{
      kind: "tool",
      name: "log",
      accepts:
        ~w(log.submit.v1 log.revise.v1 log.query.v1 log.tags.v1 log.table.v1 log.subscribe.v1
                  log.review.v1 log.edit.v1 canvas.action.v1),
      emits:
        ~w(log.receipt.v1 log.entries.v1 log.tag_list.v1 log.table_rows.v1 log.state.v1
                log.changes_requested.v1 log.approved.v1 log.rejected.v1 canvas.data.v1 core.error.v1),
      metadata: %{tool: "log"}
    }
  end

  defp viewer_endpoint do
    %{
      kind: "tool",
      name: "log view",
      accepts: ~w(log.state.v1 log.receipt.v1 log.table_rows.v1 core.error.v1),
      emits: ~w(log.subscribe.v1 log.review.v1 log.edit.v1 log.submit.v1 log.table.v1),
      metadata: %{tool: "log-view"}
    }
  end

  defp loop(state) do
    receive do
      {:tool_message, message} ->
        state |> handle(message) |> loop()

      :tool_deregistered ->
        IO.puts(:stderr, "log was disconnected; exiting")
    end
  end

  @doc false
  def handle(state, %{"from" => from} = message) do
    {type, payload} = Tool.unwrap(message, "log", ~w(review edit submit table))
    user? = Tool.user?(state.viewer, state.subscribers, from)

    case run_command(state, type, payload, from, user?) do
      {:ok, state, changed?} ->
        if changed?, do: publish(state), else: state

      {:reply, reply_type, reply, state} ->
        respond(state, message, reply_type, reply)
        state

      {:error, reason} ->
        respond(state, message, "core.error.v1", %{error: reason})
        state
    end
  rescue
    # One bad message must not take the log down with it.
    error ->
      IO.puts(:stderr, "log: #{Exception.message(error)}")
      respond(state, message, "core.error.v1", %{error: "internal error"})
      state
  end

  defp run_command(state, "log.subscribe.v1", payload, from, _user?) do
    with {:ok, target, type} <- Tool.subscription(state.headers, from, payload, "log.state.v1"),
         do: {:ok, put_in(state.subscribers[target], type), true}
  end

  defp run_command(state, "log.submit.v1", payload, from, user?) do
    id = Ww.random_id("log")

    with {:ok, content} <- Entry.validate(payload),
         :ok <- Store.create(state.store, id, author(state, from, user?), content, Tool.now()) do
      {:reply, "log.receipt.v1", %{entry: id, status: "pending"}, publish(state)}
    end
  end

  defp run_command(state, "log.revise.v1", payload, from, _user?) do
    with {:ok, entry} <- fetch(state, payload["entry"]),
         :ok <-
           check(
             entry.author["endpoint"] == from,
             "only the endpoint that submitted the entry may revise it"
           ),
         :ok <-
           check(
             entry.status in ~w(pending changes_requested),
             "entry is #{entry.status}; it can no longer be revised"
           ),
         {:ok, changes} <- Entry.validate(payload, partial: true),
         :ok <-
           Store.revise(state.store, entry.id, changes, from, "revise", "pending", Tool.now()) do
      {:reply, "log.receipt.v1", %{entry: entry.id, status: "pending"}, publish(state)}
    end
  end

  defp run_command(state, "log.edit.v1", payload, _from, true) do
    with {:ok, entry} <- fetch(state, payload["entry"]),
         # Any edit by the user puts the entry back in the queue, approved ones included.
         {:ok, changes} <- Entry.validate(payload, partial: true),
         :ok <-
           Store.revise(state.store, entry.id, changes, "user", "edit", "pending", Tool.now()) do
      {:reply, "log.receipt.v1", %{entry: entry.id, status: "pending"}, publish(state)}
    end
  end

  defp run_command(state, "log.review.v1", payload, _from, true) do
    with {:ok, entry} <- fetch(state, payload["entry"]),
         {:ok, status} <- transition(entry.status, payload["decision"]) do
      note = if is_binary(payload["note"]) and payload["note"] != "", do: payload["note"]
      Store.set_status(state.store, entry.id, status, payload["decision"], note, Tool.now())
      notify(state, entry, payload["decision"], note)
      {:ok, state, true}
    end
  end

  defp run_command(_state, type, _payload, _from, false)
       when type in ~w(log.edit.v1 log.review.v1),
       do: {:error, "only the log view can edit or review entries"}

  defp run_command(state, "log.query.v1", payload, from, _user?) do
    entries =
      Store.load_all(state.store)
      |> Enum.filter(fn e ->
        (is_nil(payload["status"]) or e.status == payload["status"]) and
          (not is_list(payload["tags"]) or Enum.all?(payload["tags"], &(&1 in e.tags))) and
          (payload["mine"] != true or e.author["endpoint"] == from)
      end)
      |> Enum.take(-limit(payload["limit"], 50, 200))
      |> Enum.map(&Map.drop(&1, [:revisions]))

    {:reply, "log.entries.v1", %{entries: entries}, state}
  end

  defp run_command(state, "log.tags.v1", _payload, _from, _user?),
    do: {:reply, "log.tag_list.v1", %{tags: tags(Store.load_all(state.store))}, state}

  defp run_command(
         state,
         "log.table.v1",
         %{"entry" => entry, "table" => table} = payload,
         _from,
         _user?
       )
       when is_binary(entry) and is_binary(table) do
    opts = [
      limit: limit(payload["limit"], 100, 1_000),
      offset:
        if(is_integer(payload["offset"]) and payload["offset"] >= 0,
          do: payload["offset"],
          else: 0
        ),
      order_by: payload["order_by"],
      desc: payload["desc"] == true
    ]

    echo = %{
      entry: entry,
      table: table,
      order_by: payload["order_by"],
      desc: opts[:desc]
    }

    # format: "csv" answers the whole table as CSV text (for downloads) instead of a page.
    result =
      if payload["format"] == "csv",
        do:
          with(
            {:ok, csv} <- Store.table_csv(state.store, entry, table, opts),
            do: {:ok, %{csv: csv}}
          ),
        else: Store.table_rows(state.store, entry, table, opts)

    case result do
      {:ok, data} -> {:reply, "log.table_rows.v1", Map.merge(data, echo), state}
      {:error, :unknown_table} -> {:error, "no table #{table} on #{entry}"}
    end
  end

  defp run_command(_state, type, _payload, _from, _user?), do: {:error, "unsupported: #{type}"}

  @doc "Allowed review transitions: {from status, action} -> new status."
  def transition(status, "approve") when status in ~w(pending changes_requested),
    do: {:ok, "approved"}

  def transition(status, "reject") when status != "rejected", do: {:ok, "rejected"}
  def transition("pending", "request_changes"), do: {:ok, "changes_requested"}
  def transition(status, "reopen") when status in ~w(approved rejected), do: {:ok, "pending"}
  def transition(status, action), do: {:error, "cannot #{action} an entry that is #{status}"}

  @doc "Tag counts over entries that are not rejected, most used first."
  def tags(entries) do
    entries
    |> Enum.reject(&(&1.status == "rejected"))
    |> Enum.flat_map(& &1.tags)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {name, count} -> {-count, name} end)
    |> Enum.map(fn {name, count} -> %{name: name, count: count} end)
  end

  # Changes requested reach the author as a prompt; if the author's endpoint is gone the
  # entry stays visible with a note, so the user can edit and approve it themselves.
  defp notify(_state, %{author: %{"user" => true}}, _action, _note), do: :ok

  defp notify(state, entry, action, note) do
    message =
      case action do
        "request_changes" ->
          {"log.changes_requested.v1",
           %{entry: entry.id, title: entry.title, note: note, delivery: "immediate"}}

        "approve" ->
          {"log.approved.v1", %{entry: entry.id, title: entry.title}}

        "reject" ->
          {"log.rejected.v1", %{entry: entry.id, title: entry.title, note: note}}

        "reopen" ->
          nil
      end

    with {type, payload} <- message do
      # A closed Pi session stays registered but offline: its mailbox would hold the request
      # with nobody to act on it, so tell the user instead (they can edit and approve).
      online? =
        try do
          Tool.send_message(state.headers, entry.author["endpoint"], type, payload)
          author_online?(state, entry.author["endpoint"])
        rescue
          _ -> false
        end

      if action == "request_changes" and not online?,
        do:
          Store.note(
            state.store,
            entry.id,
            "undeliverable",
            "the author's session is not connected",
            Tool.now()
          )
    end
  end

  defp author(_state, _from, true), do: %{"user" => true, "name" => "you"}

  defp author(state, from, false) do
    endpoint = Tool.request(:get, "/v1/endpoints/#{from}", nil, state.headers)["endpoint"]
    meta = endpoint["metadata"] || %{}

    %{
      "endpoint" => from,
      "name" => endpoint["name"],
      "harness" => meta["harness"],
      "cwd" => meta["cwd"]
    }
  end

  defp author_online?(state, id),
    do:
      Tool.request(:get, "/v1/endpoints/#{id}", nil, state.headers)["endpoint"]["online"] == true

  defp fetch(state, id) when is_binary(id) do
    case Store.get(state.store, id) do
      nil -> {:error, "no entry #{id}"}
      entry -> {:ok, entry}
    end
  end

  defp fetch(_state, _id), do: {:error, "entry id required"}

  # Every subscriber gets the whole state on any change: fine for one user's log.
  # shortcut: sends all entries each time; page through them if the log grows to thousands.
  defp publish(state) do
    entries = Store.load_all(state.store)
    payload = %{log: state.id, entries: entries, tags: tags(entries), updated: Tool.now()}
    dropped = Tool.push(state.headers, state.subscribers, payload)
    %{state | subscribers: Map.drop(state.subscribers, dropped)}
  end

  defp respond(state, message, type, payload),
    do: Tool.reply(state.headers, state.subscribers, message, type, payload)

  defp limit(n, _default, max) when is_integer(n) and n > 0, do: min(n, max)
  defp limit(_n, default, _max), do: default

  defp check(true, _), do: :ok
  defp check(false, reason), do: {:error, reason}
end
