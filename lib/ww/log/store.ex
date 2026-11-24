defmodule Ww.Log.Store do
  @moduledoc """
  Persistence for `ww log`. SQLite (exqlite) holds entries, every revision, reviews and the
  metadata of data tables; DuckDB (duckdbex) holds the data tables themselves. Callers pass
  validated data (see `Ww.Log.Entry`). Both files live in one directory, private to the user.
  """

  alias Exqlite.Sqlite3, as: Sql

  defstruct [:sql, :duck, :duck_db]

  @schema """
  CREATE TABLE IF NOT EXISTS entries (
    id TEXT PRIMARY KEY,
    status TEXT NOT NULL,
    revision INTEGER NOT NULL,
    author TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS revisions (
    entry_id TEXT NOT NULL REFERENCES entries(id),
    revision INTEGER NOT NULL,
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    tags TEXT NOT NULL,
    links TEXT NOT NULL,
    by TEXT NOT NULL,
    at TEXT NOT NULL,
    PRIMARY KEY (entry_id, revision)
  );
  CREATE TABLE IF NOT EXISTS reviews (
    entry_id TEXT NOT NULL REFERENCES entries(id),
    revision INTEGER NOT NULL,
    action TEXT NOT NULL,
    note TEXT,
    at TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS data_tables (
    entry_id TEXT NOT NULL REFERENCES entries(id),
    revision INTEGER NOT NULL,
    name TEXT NOT NULL,
    description TEXT NOT NULL,
    duck_table TEXT NOT NULL,
    columns TEXT NOT NULL,
    row_count INTEGER NOT NULL,
    PRIMARY KEY (entry_id, revision, name)
  );
  """

  def open(dir) do
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    {:ok, sql} = Sql.open(Path.join(dir, "log.sqlite"))
    # synchronous=FULL: a committed review survives power loss, not just a crash.
    :ok =
      Sql.execute(
        sql,
        "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;"
      )

    :ok = Sql.execute(sql, @schema)
    {:ok, duck_db} = Duckdbex.open(Path.join(dir, "log.duckdb"))
    {:ok, duck} = Duckdbex.connection(duck_db)
    %__MODULE__{sql: sql, duck: duck, duck_db: duck_db}
  end

  @doc "Creates an entry at revision 1, status pending."
  def create(store, id, author, content, at) do
    transaction(store, fn ->
      exec(store, "INSERT INTO entries VALUES (?1, 'pending', 1, ?2, ?3, ?3)", [
        id,
        Jason.encode!(author),
        at
      ])

      insert_revision(store, id, 1, content, author_by(author), at)
      review(store, id, 1, "submit", nil, at)
    end)
  end

  @doc """
  Adds a revision (fields missing from `changes` carry over) and sets the status. Without
  `:tables` in `changes`, the new revision keeps the previous revision's tables.
  """
  def revise(store, id, changes, by, action, status, at) do
    [[revision]] = query(store, "SELECT revision FROM entries WHERE id = ?1", [id])
    current = content(store, id, revision)
    next = revision + 1
    content = Map.merge(current, Map.take(changes, [:title, :body, :tags, :links]))

    transaction(store, fn ->
      insert_revision(
        store,
        id,
        next,
        Map.put(content, :tables, Map.get(changes, :tables)),
        by,
        at
      )

      unless Map.has_key?(changes, :tables) do
        exec(
          store,
          "INSERT INTO data_tables SELECT entry_id, ?3, name, description, duck_table, columns, row_count FROM data_tables WHERE entry_id = ?1 AND revision = ?2",
          [id, revision, next]
        )
      end

      exec(
        store,
        "UPDATE entries SET revision = ?2, status = ?3, updated_at = ?4 WHERE id = ?1",
        [id, next, status, at]
      )

      review(store, id, next, action, nil, at)
    end)
  end

  @doc "Changes status only (approve, reject, request changes, reopen) and records why."
  def set_status(store, id, status, action, note, at) do
    transaction(store, fn ->
      [[revision]] = query(store, "SELECT revision FROM entries WHERE id = ?1", [id])

      exec(store, "UPDATE entries SET status = ?2, updated_at = ?3 WHERE id = ?1", [
        id,
        status,
        at
      ])

      review(store, id, revision, action, note, at)
    end)
  end

  @doc "Records a review event without a status change (e.g. an undeliverable request)."
  def note(store, id, action, note, at) do
    [[revision]] = query(store, "SELECT revision FROM entries WHERE id = ?1", [id])
    review(store, id, revision, action, note, at)
  end

  @doc "Every entry with its revisions, reviews and current tables, oldest first."
  def load_all(store), do: load(store, nil)

  def get(store, id), do: store |> load(id) |> List.first()

  @doc "Rows of one of an entry's current tables."
  def table_rows(store, id, name, limit) do
    case query(
           store,
           "SELECT t.duck_table, t.columns FROM data_tables t JOIN entries e ON e.id = t.entry_id AND e.revision = t.revision WHERE t.entry_id = ?1 AND t.name = ?2",
           [id, name]
         ) do
      [[duck_table, columns]] ->
        {:ok, result} =
          Duckdbex.query(store.duck, "SELECT * FROM #{ident(duck_table)} LIMIT #{limit}")

        {:ok, %{columns: Jason.decode!(columns), rows: Duckdbex.fetch_all(result)}}

      [] ->
        {:error, :unknown_table}
    end
  end

  # Data goes to DuckDB before the SQLite transaction commits; if that transaction then fails,
  # the DuckDB table is orphaned (unreferenced), never half-referenced.
  defp insert_revision(store, id, revision, content, by, at) do
    exec(store, "INSERT INTO revisions VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)", [
      id,
      revision,
      content.title,
      content.body,
      Jason.encode!(content.tags),
      Jason.encode!(content.links),
      by,
      at
    ])

    for table <- content[:tables] || [] do
      duck_table = "data_#{slug(id)}_r#{revision}_#{table.name}"
      columns = Enum.map_join(table.columns, ", ", &"#{ident(&1.name)} #{&1.type}")

      {:ok, _} =
        Duckdbex.query(store.duck, "CREATE OR REPLACE TABLE #{ident(duck_table)} (#{columns})")

      {:ok, appender} = Duckdbex.appender(store.duck, duck_table)
      :ok = Duckdbex.appender_add_rows(appender, table.rows)
      :ok = Duckdbex.appender_close(appender)

      exec(store, "INSERT INTO data_tables VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)", [
        id,
        revision,
        table.name,
        table.description,
        duck_table,
        Jason.encode!(table.columns),
        length(table.rows)
      ])
    end
  end

  defp review(store, id, revision, action, note, at),
    do:
      exec(store, "INSERT INTO reviews VALUES (?1, ?2, ?3, ?4, ?5)", [
        id,
        revision,
        action,
        note,
        at
      ])

  defp content(store, id, revision) do
    [[title, body, tags, links]] =
      query(
        store,
        "SELECT title, body, tags, links FROM revisions WHERE entry_id = ?1 AND revision = ?2",
        [id, revision]
      )

    %{title: title, body: body, tags: Jason.decode!(tags), links: Jason.decode!(links)}
  end

  defp load(store, id) do
    where = if id, do: " WHERE entry_id = ?1", else: ""
    args = if id, do: [id], else: []

    revisions =
      query(
        store,
        "SELECT entry_id, revision, title, body, tags, links, by, at FROM revisions#{where} ORDER BY revision",
        args
      )
      |> Enum.group_by(&hd/1, fn [_, rev, title, body, tags, links, by, at] ->
        %{
          revision: rev,
          title: title,
          body: body,
          tags: Jason.decode!(tags),
          links: Jason.decode!(links),
          by: by,
          at: at
        }
      end)

    reviews =
      query(
        store,
        "SELECT entry_id, revision, action, note, at FROM reviews#{where} ORDER BY rowid",
        args
      )
      |> Enum.group_by(&hd/1, fn [_, rev, action, note, at] ->
        %{revision: rev, action: action, note: note, at: at}
      end)

    tables =
      query(
        store,
        "SELECT entry_id, revision, name, description, columns, row_count FROM data_tables#{where}",
        args
      )
      |> Enum.group_by(&{Enum.at(&1, 0), Enum.at(&1, 1)}, fn [
                                                               _,
                                                               _,
                                                               name,
                                                               description,
                                                               columns,
                                                               rows
                                                             ] ->
        %{name: name, description: description, columns: Jason.decode!(columns), row_count: rows}
      end)

    entry_where = if id, do: " WHERE id = ?1", else: ""

    for [eid, status, rev, author, created, updated] <-
          query(
            store,
            "SELECT id, status, revision, author, created_at, updated_at FROM entries#{entry_where} ORDER BY created_at",
            args
          ) do
      history = Map.get(revisions, eid, [])
      current = List.last(history)

      %{
        id: eid,
        status: status,
        revision: rev,
        author: Jason.decode!(author),
        created_at: created,
        updated_at: updated,
        title: current.title,
        body: current.body,
        tags: current.tags,
        links: current.links,
        tables: Map.get(tables, {eid, rev}, []),
        revisions: history,
        reviews: Map.get(reviews, eid, [])
      }
    end
  end

  defp author_by(%{"user" => true}), do: "user"
  defp author_by(author), do: author["endpoint"] || "user"

  defp transaction(store, fun) do
    :ok = Sql.execute(store.sql, "BEGIN IMMEDIATE")

    try do
      fun.()
      :ok = Sql.execute(store.sql, "COMMIT")
    rescue
      error ->
        Sql.execute(store.sql, "ROLLBACK")
        reraise error, __STACKTRACE__
    end
  end

  defp exec(store, sql, args), do: [] = query(store, sql, args)

  defp query(store, sql, args) do
    {:ok, statement} = Sql.prepare(store.sql, sql)

    try do
      :ok = Sql.bind(statement, args)
      {:ok, rows} = Sql.fetch_all(store.sql, statement)
      rows
    after
      Sql.release(store.sql, statement)
    end
  end

  defp slug(id), do: id |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "_")
  defp ident(name), do: ~s("#{String.replace(name, ~s("), ~s(""))}")
end
