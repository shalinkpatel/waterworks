defmodule Ww.Log.Entry do
  @moduledoc """
  Validates and normalizes untrusted entry content from messages: title, markdown body, tags,
  links and data tables. Pure, so the rules are tested directly.
  """

  @types ~w(BIGINT DOUBLE VARCHAR BOOLEAN)
  @max_rows 100_000
  def max_rows, do: @max_rows
  # A whole message is at most 16 MB; base64 Parquet is a third larger than the file.
  @max_file 16_000_000

  @doc """
  `{:ok, content}` or `{:error, reason}`. With `partial: true` (revise, edit) only the fields
  present are validated and returned; otherwise a title is required.
  """
  def validate(payload, opts \\ []) when is_map(payload) do
    partial? = Keyword.get(opts, :partial, false)

    fields = [
      title: &title/1,
      body: &body/1,
      tags: &tags/1,
      links: &links/1,
      tables: &tables/1
    ]

    Enum.reduce_while(fields, {:ok, %{}}, fn {key, check}, {:ok, acc} ->
      case Map.fetch(payload, Atom.to_string(key)) do
        {:ok, value} ->
          case check.(value) do
            {:ok, v} -> {:cont, {:ok, Map.put(acc, key, v)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        :error when partial? ->
          {:cont, {:ok, acc}}

        :error when key == :title ->
          {:halt, {:error, "title is required"}}

        :error ->
          {:cont, {:ok, Map.put(acc, key, default(key))}}
      end
    end)
  end

  defp default(:body), do: ""
  defp default(_), do: []

  defp title(t) when is_binary(t) do
    t = String.trim(t)

    if t != "" and String.length(t) <= 200,
      do: {:ok, t},
      else: {:error, "title must be 1-200 characters"}
  end

  defp title(_), do: {:error, "title must be a string"}

  defp body(b) when is_binary(b) and byte_size(b) <= 200_000, do: {:ok, b}
  defp body(_), do: {:error, "body must be a string up to 200 KB"}

  @doc "Tags are normalized: trimmed, lowercased, spaces to dashes, then must look like `kv-cache`."
  def tags(list) when is_list(list) and length(list) <= 20 do
    tags =
      for t <- list, is_binary(t), uniq: true do
        t |> String.trim() |> String.downcase() |> String.replace(~r/\s+/, "-")
      end

    # Normalizing may merge tags ("Bench", "bench"): they are the same tag.
    if Enum.all?(list, &is_binary/1) and
         Enum.all?(tags, &(&1 =~ ~r/\A[a-z0-9][a-z0-9._-]{0,39}\z/)),
       do: {:ok, tags},
       else: {:error, "tags must be up to 20 short names (letters, digits, . _ -)"}
  end

  def tags(_), do: {:error, "tags must be a list"}

  defp links(list) when is_list(list) and length(list) <= 20 do
    collect(list, &link/1)
  end

  defp links(_), do: {:error, "links must be a list of up to 20"}

  # Only http(s) URLs: links are rendered as anchors in the log view.
  defp link(%{"url" => url} = link) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] or is_nil(uri.host) ->
        {:error, "link urls must be http(s)"}

      link["kind"] not in [nil, "pr", "dashboard", "other"] ->
        {:error, "link kind must be pr, dashboard or other"}

      true ->
        kind = link["kind"] || if(url =~ ~r{/pull/\d+}, do: "pr", else: "other")

        label =
          if is_binary(link["label"]) and link["label"] != "",
            do: String.slice(link["label"], 0, 120),
            else: url

        {:ok, %{"url" => url, "label" => label, "kind" => kind}}
    end
  end

  defp link(url) when is_binary(url), do: link(%{"url" => url})
  defp link(_), do: {:error, "each link needs a url"}

  defp tables(list) when is_list(list) and length(list) <= 10 do
    names = for %{"name" => n} <- list, do: n

    if length(names) != length(Enum.uniq(names)) do
      {:error, "table names must be unique"}
    else
      collect(list, &table/1)
    end
  end

  defp tables(_), do: {:error, "tables must be a list of up to 10"}

  @doc """
  A data table, one of:

    * `{name, description?, columns: [name | {name, type?}], rows: [[...]]}`: types are BIGINT,
      DOUBLE, VARCHAR or BOOLEAN, inferred from the values when missing; values that fit no
      type (objects, lists) are stored as their JSON text in a VARCHAR column.
    * `{name, description?, csv: "text with a header row"}` or
      `{name, description?, parquet: "<base64>"}`: read by DuckDB, which detects the types.
    * `{name, keep: true}`: carry this table over from the previous revision (edits).
  """
  def table(%{"name" => name} = t) when is_binary(name) do
    description =
      if is_binary(t["description"]), do: String.slice(t["description"], 0, 500), else: ""

    with :ok <-
           check(name =~ ~r/\A[a-z][a-z0-9_]{0,40}\z/, "table names look like latency_by_batch") do
      case t do
        %{"keep" => true} ->
          {:ok, %{kind: :keep, name: name}}

        %{"csv" => csv} when is_binary(csv) and byte_size(csv) in 1..@max_file ->
          {:ok, %{kind: :csv, name: name, description: description, data: csv}}

        %{"parquet" => b64} when is_binary(b64) and byte_size(b64) in 1..@max_file ->
          case Base.decode64(b64, ignore: :whitespace) do
            {:ok, data} ->
              {:ok, %{kind: :parquet, name: name, description: description, data: data}}

            :error ->
              {:error, "parquet must be base64"}
          end

        %{"columns" => columns, "rows" => rows} when is_list(columns) and is_list(rows) ->
          rows_table(name, description, columns, rows)

        _ ->
          {:error, "a table needs columns and rows, csv, parquet (base64), or keep"}
      end
    end
  end

  def table(_), do: {:error, "a table needs a name"}

  defp rows_table(name, description, columns, rows) do
    with {:ok, columns} <- columns(columns),
         :ok <- check(length(rows) <= @max_rows, "tables hold at most #{@max_rows} rows"),
         :ok <-
           check(
             Enum.all?(rows, &(is_list(&1) and length(&1) == length(columns))),
             "every row needs one value per column"
           ) do
      columns =
        columns
        |> Enum.with_index()
        |> Enum.map(fn {c, i} ->
          %{c | type: c.type || infer(Enum.map(rows, &Enum.at(&1, i)))}
        end)

      with {:ok, rows} <- coerce_rows(rows, columns) do
        {:ok, %{kind: :rows, name: name, description: description, columns: columns, rows: rows}}
      end
    end
  end

  defp columns(list) when list != [] and length(list) <= 64 do
    columns =
      Enum.map(list, fn
        name when is_binary(name) ->
          %{name: name, type: nil}

        %{"name" => name} = c when is_binary(name) ->
          %{name: name, type: c["type"] && String.upcase(c["type"])}

        _ ->
          nil
      end)

    cond do
      Enum.any?(columns, &is_nil/1) ->
        {:error, "each column is a name or {name, type}"}

      Enum.any?(columns, &(&1.name == "" or String.length(&1.name) > 64)) ->
        {:error, "column names must be 1-64 characters"}

      # DuckDB column names are case-insensitive.
      length(Enum.uniq_by(columns, &String.downcase(&1.name))) != length(columns) ->
        {:error, "column names must be unique"}

      Enum.any?(columns, &(&1.type && &1.type not in @types)) ->
        {:error, "column types are #{Enum.join(@types, ", ")}"}

      true ->
        {:ok, columns}
    end
  end

  defp columns(_), do: {:error, "tables need 1-64 columns"}

  @doc false
  def infer(values) do
    present = Enum.reject(values, &is_nil/1)

    cond do
      present == [] ->
        "VARCHAR"

      Enum.all?(present, &(is_integer(&1) and &1 in -0x8000000000000000..0x7FFFFFFFFFFFFFFF)) ->
        "BIGINT"

      Enum.all?(present, &is_number/1) ->
        "DOUBLE"

      Enum.all?(present, &is_boolean/1) ->
        "BOOLEAN"

      true ->
        "VARCHAR"
    end
  end

  defp coerce_rows(rows, columns) do
    types = Enum.map(columns, & &1.type)

    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      values = Enum.zip_with(row, types, &coerce/2)

      if Enum.any?(values, &(&1 == :invalid)),
        do: {:halt, {:error, "a value does not match its column type"}},
        else: {:cont, {:ok, [values | acc]}}
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp coerce(nil, _), do: nil

  defp coerce(v, "BIGINT") when is_integer(v) and v in -0x8000000000000000..0x7FFFFFFFFFFFFFFF,
    do: v

  defp coerce(v, "DOUBLE") when is_number(v), do: v / 1
  defp coerce(v, "BOOLEAN") when is_boolean(v), do: v
  defp coerce(v, "VARCHAR") when is_binary(v), do: v
  defp coerce(v, "VARCHAR"), do: Jason.encode!(v)
  defp coerce(_, _), do: :invalid

  @doc "Maps each item with `fun` (`{:ok, x}` or an error), stopping at the first error."
  def collect(list, fun) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, x} -> {:cont, {:ok, [x | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp check(true, _), do: :ok
  defp check(false, message), do: {:error, message}
end
