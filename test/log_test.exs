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
             Store.table_rows(reopened, "log_1", "results", 10)

    assert {:error, :unknown_table} = Store.table_rows(reopened, "log_1", "nope", 10)
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
