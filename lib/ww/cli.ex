defmodule Ww.CLI do
  @moduledoc false

  def main(args) do
    case args do
      ["serve" | rest] ->
        serve(rest)

      [command | rest] ->
        {:ok, _} = Application.ensure_all_started(:inets)
        {:ok, _} = Application.ensure_all_started(:ssl)
        client(command, rest)

      [] ->
        usage()
    end
  rescue
    error ->
      IO.puts(:stderr, "ww: #{Exception.message(error)}")
      System.halt(1)
  end

  defp serve(args) do
    {opts, _, invalid} =
      OptionParser.parse(args,
        switches: [
          name: :string,
          join: :string,
          port: :integer,
          bind: :string,
          mnesia_dir: :string,
          allow_host: :keep
        ]
      )

    if invalid != [], do: raise("invalid options: #{inspect(invalid)}")
    if name = opts[:name], do: start_distribution(name)

    admin_token = System.get_env("WW_ADMIN_TOKEN")
    if !admin_token, do: raise("WW_ADMIN_TOKEN is required")
    # It is the only credential that can create endpoints; refuse guessable ones.
    if byte_size(admin_token) < 16, do: raise("WW_ADMIN_TOKEN must be at least 16 characters")

    case Application.load(:ww) do
      :ok -> :ok
      {:error, {:already_loaded, :ww}} -> :ok
    end

    Application.put_env(:ww, :admin_token, admin_token)
    Application.put_env(:ww, :join, opts[:join] || System.get_env("WW_JOIN"))
    Application.put_env(:ww, :http, true)
    Application.put_env(:ww, :port, opts[:port] || 7420)
    Application.put_env(:ww, :ip, parse_ip(opts[:bind] || "127.0.0.1"))
    Application.put_env(:ww, :allowed_hosts, values(opts, :allow_host))
    if dir = opts[:mnesia_dir], do: Application.put_env(:ww, :mnesia_dir, dir)

    {:ok, _} = Application.ensure_all_started(:ww)

    IO.puts(
      :stderr,
      "ww serving #{opts[:bind] || "127.0.0.1"}:#{opts[:port] || 7420} as #{Node.self()}"
    )

    Process.sleep(:infinity)
  end

  defp client("register", args) do
    {opts, _, invalid} =
      OptionParser.parse(args,
        switches: [kind: :string, name: :string, accepts: :keep, emits: :keep, metadata: :keep]
      )

    if invalid != [], do: raise("invalid options: #{inspect(invalid)}")

    body = %{
      kind: required(opts, :kind),
      name: required(opts, :name),
      accepts: values(opts, :accepts),
      emits: values(opts, :emits),
      metadata: metadata(opts)
    }

    admin = System.get_env("WW_ADMIN_TOKEN") || raise("WW_ADMIN_TOKEN is required")

    request(:post, "/v1/endpoints", body, [{"x-ww-admin-token", admin}], false)
    |> print()
  end

  defp client("dashboard", args) do
    {opts, _, invalid} = OptionParser.parse(args, switches: [title: :string])
    if invalid != [], do: raise("invalid options: #{inspect(invalid)}")
    admin = System.get_env("WW_ADMIN_TOKEN") || raise("WW_ADMIN_TOKEN is required")

    %{"endpoint" => endpoint, "token" => token} =
      request(
        :post,
        "/v1/endpoints",
        dashboard_endpoint(opts[:title] || "dashboard"),
        [{"x-ww-admin-token", admin}],
        false
      )

    print(%{endpoint: endpoint, token: token, url: dashboard_url(endpoint["id"], token)})
  end

  defp client("publish", args) do
    {opts, _, invalid} =
      OptionParser.parse(args,
        switches: [to: :string, file: :string, title: :string, watch: :boolean]
      )

    if invalid != [], do: raise("invalid options: #{inspect(invalid)}")
    to = required(opts, :to)
    file = required(opts, :file)

    # Returns what the next delta is computed against: this page and its message id.
    publish = fn html, previous ->
      {type, payload} = page_message(html, previous, opts[:title])

      %{"message" => message} =
        request(:post, "/v1/messages", %{to: to, type: type, payload: payload})

      size = byte_size(Jason.encode!(payload))
      IO.puts(:stderr, "published #{type} (#{size} bytes) as #{message["id"]}")
      {html, message["id"]}
    end

    html = File.read!(file)
    published = publish.(html, nil)
    if opts[:watch], do: watch(file, published, publish)
  end

  defp client("fleet", args) do
    {opts, _, invalid} = OptionParser.parse(args, switches: [interval: :integer, open: :boolean])
    if invalid != [], do: raise("invalid options: #{inspect(invalid)}")
    Ww.Fleet.run((opts[:interval] || 5) * 1000, Keyword.get(opts, :open, true))
  end

  defp client("discover", args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [kind: :string, name: :string, accepts: :string, online: :boolean]
      )

    query = opts |> Enum.reject(&is_nil(elem(&1, 1))) |> URI.encode_query()
    request(:get, "/v1/endpoints" <> query_string(query)) |> print()
  end

  defp client("inspect", [id]), do: request(:get, "/v1/endpoints/#{id}") |> print()

  defp client("history", _),
    do: request(:get, "/v1/endpoints/#{endpoint_id()}/history") |> print()

  defp client("send", args) do
    {opts, _, invalid} =
      OptionParser.parse(args,
        switches: [to: :string, type: :string, data: :string, id: :string, reply_to: :string]
      )

    if invalid != [], do: raise("invalid options: #{inspect(invalid)}")

    payload = Jason.decode!(opts[:data] || "{}")
    if !is_map(payload), do: raise("--data must be a JSON object")

    body =
      %{to: required(opts, :to), type: required(opts, :type), payload: payload}
      |> put_if(:id, opts[:id])
      |> put_if(:reply_to, opts[:reply_to])

    request(:post, "/v1/messages", body) |> print()
  end

  defp client("ack", args) do
    {opts, _, _} = OptionParser.parse(args, switches: [id: :string])
    id = required(opts, :id)
    request(:post, "/v1/endpoints/#{endpoint_id()}/ack", %{id: id}) |> print()
  end

  defp client("tail", args) do
    {opts, _, _} = OptionParser.parse(args, switches: [ack: :boolean])
    stream_tail(if opts[:ack], do: "?ack=1", else: "") |> stream()
  end

  defp client("echo", _args) do
    IO.puts(:stderr, "ww echo connected as #{endpoint_id()}")
    stream_tail("") |> stream_lines("")
  end

  defp client(command, _) do
    IO.puts(:stderr, "ww: unknown command #{command}")
    usage()
    System.halt(1)
  end

  def dashboard_endpoint(title) do
    %{
      kind: "tool",
      name: title,
      accepts: [
        "dashboard.render.v1",
        "dashboard.delta.v1",
        "dashboard.patch.v1",
        "dashboard.data.v1",
        "dashboard.reply.v1",
        "dashboard.clear.v1"
      ],
      emits: ["dashboard.comment.v1", "core.error.v1"],
      metadata: %{tool: "dashboard"}
    }
  end

  # The token rides in the fragment, which browsers never send to the server.
  def dashboard_url(id, token),
    do: base_url() <> "/dashboard#" <> URI.encode_query(%{"endpoint" => id, "token" => token})

  @doc false
  def request(method, path, body \\ nil, extra_headers \\ [], authenticate \\ true) do
    headers = if authenticate, do: auth_headers(), else: []
    headers = http_headers(headers ++ extra_headers)
    url = String.to_charlist(base_url() <> path)

    request =
      if body,
        do: {url, headers, ~c"application/json", Jason.encode!(body)},
        else: {url, headers}

    case :httpc.request(method, request, [], []) do
      {:ok, {{_, status, _}, _, response}} when status in 200..299 -> Jason.decode!(response)
      {:ok, {{_, status, _}, _, response}} -> raise("HTTP #{status}: #{response}")
      {:error, reason} -> raise("request failed: #{inspect(reason)}")
    end
  end

  # Content polling, not mtimes: mtimes have one-second resolution and editors save atomically.
  defp watch(file, {last, _id} = published, publish) do
    Process.sleep(500)

    case File.read(file) do
      {:ok, ^last} -> watch(file, published, publish)
      {:ok, html} -> watch(file, publish.(html, published), publish)
      {:error, _} -> watch(file, published, publish)
    end
  end

  @doc false
  # A delta against the previously published page when under half the page's size, else the page.
  def page_message(html, previous, title) do
    full = {"dashboard.render.v1", put_if(%{html: html}, :title, title)}

    case previous do
      {old, base} ->
        delta = put_if(%{base: base, ops: line_delta(old, html)}, :title, title)

        if byte_size(Jason.encode!(delta)) * 2 < byte_size(html),
          do: {"dashboard.delta.v1", delta},
          else: full

      nil ->
        full
    end
  end

  @doc false
  def line_delta(old, new) do
    String.split(old, "\n")
    |> List.myers_difference(String.split(new, "\n"))
    |> Enum.map(fn
      {:eq, lines} -> %{keep: length(lines)}
      {:del, lines} -> %{drop: length(lines)}
      {:ins, lines} -> %{insert: lines}
    end)
  end

  defp stream_tail(query) do
    url = base_url() <> "/v1/endpoints/#{endpoint_id()}/tail" <> query

    {:ok, ref} =
      :httpc.request(:get, {String.to_charlist(url), http_headers(auth_headers())}, [],
        sync: false,
        stream: :self
      )

    ref
  end

  defp stream(ref) do
    receive do
      {:http, {^ref, :stream_start, _headers}} ->
        stream(ref)

      {:http, {^ref, :stream, body}} ->
        IO.write(body)
        stream(ref)

      {:http, {^ref, :stream_end, _headers}} ->
        :ok

      {:http, {^ref, {{_, status, _}, _, body}}} ->
        raise("HTTP #{status}: #{body}")

      {:http, {^ref, {:error, reason}}} ->
        raise("stream failed: #{inspect(reason)}")
    end
  end

  defp stream_lines(ref, buffer) do
    receive do
      {:http, {^ref, :stream_start, _headers}} ->
        stream_lines(ref, buffer)

      {:http, {^ref, :stream, body}} ->
        parts = String.split(buffer <> body, "\n")
        {lines, [rest]} = Enum.split(parts, -1)
        Enum.each(lines, &handle_echo_line/1)
        stream_lines(ref, rest)

      {:http, {^ref, :stream_end, _headers}} ->
        if buffer != "", do: handle_echo_line(buffer)
        :ok

      {:http, {^ref, {{_, status, _}, _, body}}} ->
        raise("HTTP #{status}: #{body}")

      {:http, {^ref, {:error, reason}}} ->
        raise("stream failed: #{inspect(reason)}")
    end
  end

  defp handle_echo_line(line) do
    case Jason.decode!(line) do
      %{"op" => "message", "message" => message} -> respond_to_echo(message)
      _ -> :ok
    end
  end

  defp respond_to_echo(%{"type" => "demo.echo.v1"} = message) do
    response = %{
      id: "#{message["id"]}-echo",
      to: message["from"],
      type: "demo.echoed.v1",
      payload: %{text: message["payload"]["text"], echoed_by: endpoint_id()},
      reply_to: message["id"]
    }

    _ = request(:post, "/v1/messages", response)
    _ = request(:post, "/v1/endpoints/#{endpoint_id()}/ack", %{id: message["id"]})
    :ok
  end

  defp respond_to_echo(message) do
    IO.puts(:stderr, "ww echo ignoring #{message["type"]}")
    _ = request(:post, "/v1/endpoints/#{endpoint_id()}/ack", %{id: message["id"]})
    :ok
  end

  defp start_distribution(name) do
    unless Node.alive?() do
      flags =
        ["ERL_AFLAGS", "ERL_FLAGS", "ERL_ZFLAGS"]
        |> Enum.map(&System.get_env(&1, ""))
        |> Enum.join(" ")

      cookie_file = Path.join(System.user_home!(), ".erlang.cookie")

      unless Regex.match?(~r/(^|\s)-setcookie\s+\S/, flags) || File.exists?(cookie_file) do
        raise("a distributed node needs a cookie: put it in ~/.erlang.cookie (mode 0400)")
      end

      {_, 0} = System.cmd("epmd", ["-daemon"])
      {:ok, _} = Node.start(String.to_atom(name), :longnames)
    end
  end

  defp auth_headers do
    token = System.get_env("WW_TOKEN") || raise("WW_TOKEN is required")
    [{"x-ww-endpoint", endpoint_id()}, {"authorization", "Bearer #{token}"}]
  end

  defp endpoint_id, do: System.get_env("WW_ENDPOINT") || raise("WW_ENDPOINT is required")

  @doc false
  def base_url,
    do: System.get_env("WW_URL", "http://127.0.0.1:7420") |> String.trim_trailing("/")

  defp http_headers(headers) do
    Enum.map(headers, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
  end

  defp metadata(opts) do
    opts
    |> values(:metadata)
    |> Map.new(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [key, value] -> {key, value}
        _ -> raise("--metadata must be key=value")
      end
    end)
  end

  defp values(opts, key), do: for({^key, value} <- opts, do: value)
  defp required(opts, key), do: opts[key] || raise("--#{key} is required")
  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
  defp query_string(""), do: ""
  defp query_string(query), do: "?" <> query

  defp parse_ip(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, ip} -> ip
      {:error, _} -> raise("invalid --bind address")
    end
  end

  defp print(value), do: IO.puts(Jason.encode!(value, pretty: true))

  defp usage do
    IO.puts("""
    ww serve [--name NODE] [--join NODE] [--port PORT] [--bind IP] [--allow-host HOST] [--mnesia-dir DIR]
    ww register --kind agent|tool --name NAME [--accepts TYPE] [--emits TYPE] [--metadata K=V]
    ww dashboard [--title TITLE]
    ww publish --to DASHBOARD_ID --file PAGE.html [--title TITLE] [--watch]  (--watch sends deltas)
    ww fleet [--interval SECONDS] [--no-open]  (live dashboard of every endpoint)
    ww discover [--kind KIND] [--name NAME] [--accepts TYPE] [--online]
    ww inspect ENDPOINT_ID
    ww send --to ENDPOINT_ID --type TYPE [--data JSON] [--id ID] [--reply-to ID]
    ww tail [--ack]
    ww echo
    ww ack --id MESSAGE_ID
    ww history

    Environment: WW_URL, WW_ENDPOINT, WW_TOKEN, WW_ADMIN_TOKEN, WW_JOIN.
    For distribution, put the shared cookie in ~/.erlang.cookie (mode 0400) on every node.
    """)
  end
end
