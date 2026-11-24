defmodule Ww.Log.Store do
  @moduledoc """
  Persistence for `ww log`. SQLite (exqlite) holds entries, every revision, reviews and the
  metadata of data tables; DuckDB (duckdbex) holds the data tables themselves. Callers pass
  validated data (see `Ww.Log.Entry`). Both files live in one directory, private to the user.
  """

  alias Exqlite.Sqlite3, as: Sql

  defstruct [:dir, :sql, :duck, :duck_db]

  @max_rows Ww.Log.Entry.max_rows()
  # Column types returned as-is; anything else (dates, decimals, structs...) is read as text.
  @json_types ~w(BOOLEAN TINYINT SMALLINT INTEGER BIGINT FLOAT REAL DOUBLE VARCHAR)

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
    # Private only when we create it; an existing --dir keeps the user's permissions.
    unless File.dir?(dir) do
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o700)
    end

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
    %__MODULE__{dir: dir, sql: sql, duck: duck, duck_db: duck_db}
  end

  @doc "Creates an entry at revision 1, status pending. `{:error, reason}` if a table is unreadable."
  def create(store, id, author, content, at) do
    with {:ok, tables} <- load_tables(store, id, 1, content.tables, nil) do
      transaction(store, fn ->
        exec(store, "INSERT INTO entries VALUES (?1, 'pending', 1, ?2, ?3, ?3)", [
          id,
          Jason.encode!(author),
          at
        ])

        insert_revision(store, id, 1, content, tables, author_by(author), at)
        review(store, id, 1, "submit", nil, at)
      end)
    end
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

    # Without :tables, every current table is kept.
    specs =
      Map.get(changes, :tables) ||
        Enum.map(current_tables(store, id, revision), &%{kind: :keep, name: &1})

    with {:ok, tables} <- load_tables(store, id, next, specs, revision) do
      transaction(store, fn ->
        insert_revision(store, id, next, content, tables, by, at)

        exec(
          store,
          "UPDATE entries SET revision = ?2, status = ?3, updated_at = ?4 WHERE id = ?1",
          [id, next, status, at]
        )

        review(store, id, next, action, nil, at)
      end)
    end
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

  @doc """
  A page of one of an entry's current tables: `{:ok, %{columns, rows, total, offset}}`.
  Options: limit, offset, order_by (a column name) and desc.
  """
  def table_rows(store, id, name, opts) do
    with {:ok, duck_table, columns, total} <- current_table(store, id, name) do
      # Interpolated below, so integers only.
      limit = non_negative(Keyword.get(opts, :limit), 100)
      offset = non_negative(Keyword.get(opts, :offset), 0)

      sql =
        "SELECT #{select_list(columns)} FROM #{ident(duck_table)}#{order(columns, opts)} LIMIT #{limit} OFFSET #{offset}"

      {:ok, result} = Duckdbex.query(store.duck, sql)
      {:ok, %{columns: columns, rows: Duckdbex.fetch_all(result), total: total, offset: offset}}
    end
  end

  @doc "A whole current table as CSV text (header row first), in the requested order."
  def table_csv(store, id, name, opts) do
    with {:ok, %{columns: columns, rows: rows}} <-
           table_rows(store, id, name, Keyword.merge(opts, limit: @max_rows, offset: 0)) do
      lines = [Enum.map(columns, & &1["name"]) | rows]

      {:ok,
       Enum.map_join(lines, "", fn row -> Enum.map_join(row, ",", &csv_field/1) <> "\r\n" end)}
    end
  end

  defp csv_field(nil), do: ""

  defp csv_field(v) when is_binary(v),
    do: if(v =~ ~r/[",\r\n]/, do: ~s("#{String.replace(v, ~s("), ~s(""))}"), else: v)

  defp csv_field(v), do: to_string(v)

  defp non_negative(n, _default) when is_integer(n) and n >= 0, do: n
  defp non_negative(_n, default), do: default

  defp current_table(store, id, name) do
    case query(
           store,
           "SELECT t.duck_table, t.columns, t.row_count FROM data_tables t JOIN entries e ON e.id = t.entry_id AND e.revision = t.revision WHERE t.entry_id = ?1 AND t.name = ?2",
           [id, name]
         ) do
      [[duck_table, columns, total]] -> {:ok, duck_table, Jason.decode!(columns), total}
      [] -> {:error, :unknown_table}
    end
  end

  defp current_tables(store, id, revision),
    do:
      for(
        [name] <-
          query(store, "SELECT name FROM data_tables WHERE entry_id = ?1 AND revision = ?2", [
            id,
            revision
          ]),
        do: name
      )

  defp select_list(columns) do
    Enum.map_join(columns, ", ", fn %{"name" => n, "type" => t} ->
      if t in @json_types, do: ident(n), else: "CAST(#{ident(n)} AS VARCHAR) AS #{ident(n)}"
    end)
  end

  # Sorting only by a known column, so the name is never taken from the request as SQL.
  defp order(columns, opts) do
    case Enum.find(columns, &(&1["name"] == opts[:order_by])) do
      nil ->
        ""

      %{"name" => n} ->
        " ORDER BY #{ident(n)} #{if opts[:desc], do: "DESC", else: "ASC"} NULLS LAST"
    end
  end

  # Tables load into DuckDB before the SQLite transaction, so an unreadable CSV is an answer
  # to the sender rather than a rolled-back write. A later SQLite failure leaves an orphaned
  # (unreferenced) DuckDB table, never a half-referenced one.
  defp load_tables(store, id, revision, specs, previous) do
    Ww.Log.Entry.collect(specs, &load_table(store, id, revision, &1, previous))
  end

  defp load_table(store, id, _revision, %{kind: :keep, name: name}, previous) do
    case query(
           store,
           "SELECT description, duck_table, columns, row_count FROM data_tables WHERE entry_id = ?1 AND revision = ?2 AND name = ?3",
           [id, previous, name]
         ) do
      [[description, duck_table, columns, rows]] ->
        {:ok,
         %{
           name: name,
           description: description,
           duck_table: duck_table,
           columns: Jason.decode!(columns),
           row_count: rows
         }}

      [] ->
        {:error, "there is no table #{name} to keep"}
    end
  end

  defp load_table(store, id, revision, %{kind: :rows} = t, _previous) do
    duck_table = duck_name(id, revision, t.name)
    columns = Enum.map(t.columns, &%{"name" => &1.name, "type" => &1.type})
    definition = Enum.map_join(columns, ", ", &"#{ident(&1["name"])} #{&1["type"]}")

    {:ok, _} =
      Duckdbex.query(store.duck, "CREATE OR REPLACE TABLE #{ident(duck_table)} (#{definition})")

    {:ok, appender} = Duckdbex.appender(store.duck, duck_table)
    :ok = Duckdbex.appender_add_rows(appender, t.rows)
    :ok = Duckdbex.appender_close(appender)

    {:ok,
     %{
       name: t.name,
       description: t.description,
       duck_table: duck_table,
       columns: columns,
       row_count: length(t.rows)
     }}
  end

  # CSV and Parquet are written to a private temp file and read by DuckDB itself, which
  # detects the column types (dates, decimals...).
  defp load_table(store, id, revision, %{kind: kind} = t, _previous)
       when kind in [:csv, :parquet] do
    duck_table = duck_name(id, revision, t.name)
    file = Path.join(store.dir, "ingest-#{System.unique_integer([:positive])}.#{kind}")
    File.write!(file, t.data)
    path = "'" <> String.replace(file, "'", "''") <> "'"

    reader =
      if kind == :csv, do: "read_csv(#{path}, header = true)", else: "read_parquet(#{path})"

    try do
      with {:ok, _} <-
             Duckdbex.query(
               store.duck,
               "CREATE OR REPLACE TABLE #{ident(duck_table)} AS SELECT * FROM #{reader}"
             ),
           {:ok, described} <-
             Duckdbex.query(
               store.duck,
               "SELECT column_name, column_type FROM (DESCRIBE #{ident(duck_table)})"
             ),
           {:ok, counted} <-
             Duckdbex.query(store.duck, "SELECT count(*) FROM #{ident(duck_table)}") do
        columns =
          for [n, type] <- Duckdbex.fetch_all(described), do: %{"name" => n, "type" => type}

        [[rows]] = Duckdbex.fetch_all(counted)

        if rows > @max_rows do
          Duckdbex.query(store.duck, "DROP TABLE #{ident(duck_table)}")
          {:error, "tables hold at most #{@max_rows} rows"}
        else
          {:ok,
           %{
             name: t.name,
             description: t.description,
             duck_table: duck_table,
             columns: columns,
             row_count: rows
           }}
        end
      else
        {:error, reason} -> {:error, "could not read the #{kind}: #{reason}"}
      end
    after
      File.rm(file)
    end
  end

  defp duck_name(id, revision, name), do: "data_#{slug(id)}_r#{revision}_#{name}"

  defp insert_revision(store, id, revision, content, tables, by, at) do
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

    for t <- tables do
      exec(store, "INSERT INTO data_tables VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)", [
        id,
        revision,
        t.name,
        t.description,
        t.duck_table,
        Jason.encode!(t.columns),
        t.row_count
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
    # ?1 is the entry id, or NULL for every entry.
    args = [id]

    revisions =
      query(
        store,
        "SELECT entry_id, revision, title, body, tags, links, by, at FROM revisions WHERE ?1 IS NULL OR entry_id = ?1 ORDER BY revision",
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
        "SELECT entry_id, revision, action, note, at FROM reviews WHERE ?1 IS NULL OR entry_id = ?1 ORDER BY rowid",
        args
      )
      |> Enum.group_by(&hd/1, fn [_, rev, action, note, at] ->
        %{revision: rev, action: action, note: note, at: at}
      end)

    tables =
      query(
        store,
        # Only the current revision's tables are shown; older ones stay in the store.
        "SELECT t.entry_id, t.revision, t.name, t.description, t.columns, t.row_count FROM data_tables t JOIN entries e ON e.id = t.entry_id AND e.revision = t.revision WHERE ?1 IS NULL OR t.entry_id = ?1",
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

    for [eid, status, rev, author, created, updated] <-
          query(
            store,
            "SELECT id, status, revision, author, created_at, updated_at FROM entries WHERE ?1 IS NULL OR id = ?1 ORDER BY created_at, rowid",
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
