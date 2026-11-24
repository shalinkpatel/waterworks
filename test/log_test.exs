defmodule WwLogTest do
  use ExUnit.Case, async: true

  alias Ww.Log
  alias Ww.Log.{Entry, Store}

  @moduletag :tmp_dir

  test "entries, revisions, reviews and tables persist and are restored on reopen", %{
    tmp_dir: dir
  } do
    store = Store.open(dir)
    author = %{"endpoint" => "ep_a", "name" => "pi-1", "harness" => "pi", "cwd" => "/w"}

    {:ok, content} =
      Entry.validate(%{
        "title" => "KV hit rate up 12%",
        "body" => "Ran the **bench**.",
        "tags" => ["KV Cache", "bench"],
        "links" => [
          "https://github.com/o/r/pull/7",
          %{"url" => "https://grafana.example/d/x", "kind" => "dashboard"}
        ],
        "tables" => [
          %{
            "name" => "results",
            "columns" => ["batch", "p50_ms", "ok"],
            "rows" => [[1, 2.5, true], [8, 3, nil]]
          }
        ]
      })

    Store.create(store, "log_1", author, content, "2026-11-24T10:00:00Z")

    Store.revise(
      store,
      "log_1",
      %{body: "Ran it twice."},
      "ep_a",
      "revise",
      "pending",
      "2026-11-24T11:00:00Z"
    )

    Store.set_status(store, "log_1", "approved", "approve", "nice", "2026-11-24T12:00:00Z")

    # A fresh open of the same directory sees everything.
    reopened = Store.open(dir)
    [entry] = Store.load_all(reopened)

    assert %{status: "approved", revision: 2, title: "KV hit rate up 12%", body: "Ran it twice."} =
             entry

    assert entry.tags == ["kv-cache", "bench"]

    assert [%{"kind" => "pr"}, %{"kind" => "dashboard", "label" => "https://grafana.example/d/x"}] =
             entry.links

    assert Enum.map(entry.revisions, & &1.body) == ["Ran the **bench**.", "Ran it twice."]
    assert Enum.map(entry.reviews, & &1.action) == ~w(submit revise approve)
    # The revision without new tables keeps the previous revision's table.
    assert [
             %{
               name: "results",
               row_count: 2,
               columns: [%{"type" => "BIGINT"}, %{"type" => "DOUBLE"}, %{"type" => "BOOLEAN"}]
             }
           ] =
             entry.tables

    assert {:ok, %{rows: [[1, 2.5, true], [8, 3.0, nil]]}} =
             Store.table_rows(reopened, "log_1", "results", limit: 10)

    assert {:error, :unknown_table} = Store.table_rows(reopened, "log_1", "nope", [])
  end

  test "CSV and Parquet tables load natively; revisions keep or replace tables", %{tmp_dir: dir} do
    store = Store.open(dir)
    author = %{"endpoint" => "ep_a", "name" => "pi-1"}
    csv = "day,run,hit_rate,note\n2026-11-20,1,0.61,\"warm, cached\"\n2026-11-21,2,0.73,\n"

    # Parquet produced by DuckDB itself, sent base64 like an agent would.
    parquet = Path.join(dir, "in.parquet")
    {:ok, db} = Duckdbex.open()
    {:ok, conn} = Duckdbex.connection(db)

    {:ok, _} =
      Duckdbex.query(
        conn,
        "COPY (SELECT range AS i, range * 1.5 AS x FROM range(5)) TO '#{parquet}' (FORMAT parquet)"
      )

    {:ok, content} =
      Entry.validate(%{
        "title" => "files",
        "tables" => [
          %{"name" => "daily", "csv" => csv},
          %{"name" => "series", "parquet" => Base.encode64(File.read!(parquet))}
        ]
      })

    assert :ok = Store.create(store, "log_f", author, content, "2026-11-24T10:00:00Z")
    [entry] = Store.load_all(store)

    assert [%{name: "daily", row_count: 2, columns: daily}, %{name: "series", row_count: 5}] =
             entry.tables

    assert Enum.map(daily, & &1["type"]) == ~w(DATE BIGINT DOUBLE VARCHAR)

    # Dates come back as text; sorting and paging use known columns only.
    assert {:ok, %{rows: [["2026-11-21", 2, 0.73, nil]], total: 2}} =
             Store.table_rows(store, "log_f", "daily", order_by: "run", desc: true, limit: 1)

    # DECIMAL keeps its exact value as text.
    assert {:ok, %{rows: [[1, "1.5"]], offset: 1}} =
             Store.table_rows(store, "log_f", "series",
               order_by: "i; DROP TABLE x",
               limit: 1,
               offset: 1
             )

    assert {:ok,
            "day,run,hit_rate,note\r\n2026-11-20,1,0.61,\"warm, cached\"\r\n2026-11-21,2,0.73,\r\n"} =
             Store.table_csv(store, "log_f", "daily", [])

    # Keep one table, replace the other; a bad CSV is an error and changes nothing.
    {:ok, changes} =
      Entry.validate(
        %{
          "tables" => [
            %{"name" => "daily", "keep" => true},
            %{"name" => "fresh", "csv" => "a\n1\n"}
          ]
        },
        partial: true
      )

    assert :ok =
             Store.revise(
               store,
               "log_f",
               changes,
               "ep_a",
               "revise",
               "pending",
               "2026-11-24T11:00:00Z"
             )

    assert Enum.map(Store.get(store, "log_f").tables, & &1.name) == ["daily", "fresh"]

    {:ok, bad} =
      Entry.validate(
        %{"tables" => [%{"name" => "broken", "parquet" => Base.encode64("not parquet")}]},
        partial: true
      )

    assert {:error, "could not read the parquet: " <> _} =
             Store.revise(
               store,
               "log_f",
               bad,
               "ep_a",
               "revise",
               "pending",
               "2026-11-24T12:00:00Z"
             )

    assert Store.get(store, "log_f").revision == 2

    assert {:error, "there is no table nope to keep"} =
             Store.revise(
               store,
               "log_f",
               %{tables: [%{kind: :keep, name: "nope"}]},
               "ep_a",
               "revise",
               "pending",
               "t"
             )
  end

  test "validation normalizes tags and links and rejects bad input" do
    assert {:error, "title is required"} = Entry.validate(%{})
    assert {:ok, %{body: "", tags: [], links: [], tables: []}} = Entry.validate(%{"title" => "x"})
    assert {:ok, %{tags: ["a"]}} = Entry.validate(%{"tags" => ["a"]}, partial: true)
    assert {:error, _} = Entry.validate(%{"title" => "x", "tags" => ["no/slash"]})

    assert {:error, "link urls must be http(s)"} =
             Entry.validate(%{"title" => "x", "links" => ["javascript:alert(1)"]})

    assert {:error, "every row needs one value per column"} =
             Entry.table(%{"name" => "t", "columns" => ["a", "b"], "rows" => [[1]]})

    assert {:error, "a value does not match its column type"} =
             Entry.table(%{
               "name" => "t",
               "columns" => [%{"name" => "a", "type" => "bigint"}],
               "rows" => [["x"]]
             })

    # Mixed or structured values fall back to VARCHAR, structured ones as JSON text.
    assert {:ok, %{columns: [%{type: "VARCHAR"}], rows: [["x"], [~s({"k":1})]]}} =
             Entry.table(%{"name" => "t", "columns" => ["a"], "rows" => [["x"], [%{"k" => 1}]]})
  end

  test "review transitions" do
    assert {:ok, "approved"} = Log.transition("pending", "approve")
    assert {:ok, "approved"} = Log.transition("changes_requested", "approve")
    assert {:ok, "changes_requested"} = Log.transition("pending", "request_changes")
    assert {:ok, "rejected"} = Log.transition("approved", "reject")
    assert {:ok, "pending"} = Log.transition("approved", "reopen")
    assert {:error, _} = Log.transition("approved", "approve")
    assert {:error, _} = Log.transition("rejected", "reject")
    assert {:error, _} = Log.transition("changes_requested", "request_changes")
  end

  test "tag counts skip rejected entries" do
    entries = [
      %{status: "approved", tags: ["a", "b"]},
      %{status: "pending", tags: ["a"]},
      %{status: "rejected", tags: ["c"]}
    ]

    assert Log.tags(entries) == [%{name: "a", count: 2}, %{name: "b", count: 1}]
  end
end
