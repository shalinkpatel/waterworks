defmodule Ww.Tool do
  @moduledoc """
  The layer tool processes (`ww fleet`, `ww log`) are built on. A tool is a client of the
  daemon over HTTP: it registers a tool endpoint (`metadata.tool`) plus a viewer endpoint for
  its first-party page, follows its own mailbox, and pushes state to subscribers.

  Conventions every tool follows (see DESIGN.md, "Tools"):

    * Subscribers are a map of endpoint id to the message type they receive: the tool's own
      state type, or `canvas.data.v1` for canvases (which only take `canvas.*` messages).
    * Anyone may subscribe itself (to watch) or a canvas; see `subscription/4`.
    * The user is the tool's own viewer or a subscribed canvas (`user?/3`); only the user may
      change things.
    * Canvas pages act through `canvas.action.v1 {action, ...}`, unwrapped by `unwrap/3`.
    * Replies and pushes to a canvas ride on `canvas.data.v1 {reply: {type, payload, reply_to}}`;
      state pushes to a canvas are the state itself (`send_to/6`, `push/3`).
    * Bad requests are answered with `core.error.v1 {error}`.
  """

  defmodule HTTPError do
    defexception [:status, :body]
    @impl true
    def message(%{status: status, body: body}), do: "HTTP #{status}: #{body}"
  end

  def base_url,
    do: System.get_env("WW_URL", "http://127.0.0.1:7420") |> String.trim_trailing("/")

  def admin_token!, do: System.get_env("WW_ADMIN_TOKEN") || raise("WW_ADMIN_TOKEN is required")

  @doc "UTC ISO 8601, to the second; views show it in their own time zone."
  def now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  @doc "A JSON request to the daemon. Raises `HTTPError` on a non-2xx answer."
  def request(method, path, body \\ nil, headers \\ []) do
    url = String.to_charlist(base_url() <> path)
    headers = for {k, v} <- headers, do: {String.to_charlist(k), String.to_charlist(v)}

    request =
      if body,
        do: {url, headers, ~c"application/json", Jason.encode!(body)},
        else: {url, headers}

    case :httpc.request(method, request, [], []) do
      {:ok, {{_, status, _}, _, response}} when status in 200..299 ->
        Jason.decode!(response)

      {:ok, {{_, status, _}, _, response}} ->
        raise HTTPError, status: status, body: to_string(response)

      {:error, reason} ->
        raise "request failed: #{inspect(reason)}"
    end
  end

  @doc "Registers an endpoint with the admin token: `%{id, token, headers}`."
  def register(admin, body) do
    %{"endpoint" => %{"id" => id}, "token" => token} =
      request(:post, "/v1/endpoints", body, [{"x-ww-admin-token", admin}])

    %{
      id: id,
      token: token,
      headers: [{"x-ww-endpoint", id}, {"authorization", "Bearer #{token}"}]
    }
  end

  @doc "A daemon-served page's URL for an endpoint; the token rides in the fragment, never sent."
  def view_url(path, %{id: id, token: token}, extra \\ %{}),
    do:
      base_url() <>
        path <> "#" <> URI.encode_query(Map.merge(%{"endpoint" => id, "token" => token}, extra))

  @doc """
  Starts a tool: registers it and its viewer (subscribed up front; the page re-subscribes on
  every connect), prints both, and opens the view on macOS. The view's URL carries the tool id
  under `key` so the page knows whom to trust.
  """
  def start(name, endpoint, viewer_endpoint, open?) do
    admin = admin_token!()
    tool = register(admin, endpoint)
    viewer = register(admin, viewer_endpoint)
    url = view_url("/#{name}", viewer, %{name => tool.id})
    IO.puts(:stderr, "#{name} endpoint: #{tool.id}")
    IO.puts(:stderr, "#{name} view: #{url}")
    if open? and match?({:unix, :darwin}, :os.type()), do: System.cmd("open", [url])
    %{admin: admin, tool: tool, viewer: viewer}
  end

  @doc "A daemon-served page as one self-contained page (its local scripts inlined), for canvases."
  def canvas_page(path) do
    {:ok, {_type, _csp, html}} = WwWeb.Static.fetch(path)

    Regex.replace(~r{<script src="(/[^"]+)"></script>}, html, fn _, src ->
      {:ok, {_type, _csp, js}} = WwWeb.Static.fetch(src)
      "<script>\n#{js}</script>"
    end)
  end

  def send_message(headers, to, type, payload, extra \\ %{}),
    do:
      request(
        :post,
        "/v1/messages",
        Map.merge(%{to: to, type: type, payload: payload}, extra),
        headers
      )

  @doc "Turns `canvas.action.v1 {action, ...}` into `prefix.action.v1` for the listed actions."
  def unwrap(
        %{"type" => "canvas.action.v1", "payload" => %{"action" => action} = p},
        prefix,
        actions
      )
      when is_binary(action) do
    if action in actions,
      do: {"#{prefix}.#{action}.v1", Map.delete(p, "action")},
      else: {"canvas.action.v1", p}
  end

  def unwrap(%{"type" => type} = message, _prefix, _actions),
    do: {type, message["payload"] || %{}}

  @doc "Whether `from` is the user: the tool's own viewer or a subscribed canvas."
  def user?(viewer, subscribers, from),
    do: from == viewer or subscribers[from] == "canvas.data.v1"

  @doc """
  Who a subscribe request adds: `{:ok, target, type}` for the sender itself (`own_type`) or a
  canvas `payload.to` (`canvas.data.v1`), else `{:error, reason}`. A canvas page cannot
  subscribe itself: `unwrap/3` never maps a subscribe action.
  """
  def subscription(headers, from, payload, own_type) do
    target = payload["to"] || from

    cond do
      canvas?(headers, target) -> {:ok, target, "canvas.data.v1"}
      target == from -> {:ok, target, own_type}
      true -> {:error, "can only subscribe yourself or a canvas"}
    end
  end

  defp canvas?(headers, id) do
    "canvas.data.v1" in request(:get, "/v1/endpoints/#{id}", nil, headers)["endpoint"]["accepts"]
  rescue
    _ -> false
  end

  @doc "Sends to one subscriber or requester, wrapped for canvases. Errors are not raised."
  def send_to(headers, subscribers, to, type, payload, reply_to \\ nil) do
    {type, payload} =
      if subscribers[to] == "canvas.data.v1",
        do: {"canvas.data.v1", %{reply: %{type: type, payload: payload, reply_to: reply_to}}},
        else: {type, payload}

    send_message(headers, to, type, payload, %{reply_to: reply_to})
    :ok
  rescue
    error -> {:error, Exception.message(error)}
  end

  def reply(headers, subscribers, message, type, payload),
    do: send_to(headers, subscribers, message["from"], type, payload, message["id"])

  @doc """
  Pushes state to subscribers (each gets its own message type; canvases get the state as
  `canvas.data.v1`). Returns the ids that could not be reached (e.g. deregistered), to drop.
  """
  def push(headers, subscribers, payload) do
    for {to, type} <- subscribers,
        match?({:error, _}, try_send(headers, to, type, payload)),
        do: to
  end

  defp try_send(headers, to, type, payload) do
    send_message(headers, to, type, payload)
  rescue
    error ->
      IO.puts(:stderr, "dropping subscriber #{to}: #{Exception.message(error)}")
      {:error, error}
  end

  @doc """
  Streams the endpoint's mailbox (auto-acknowledged) to the calling process as
  `{:tool_message, message}`, reconnecting if the daemon restarts. Sends `:tool_deregistered`
  if the endpoint is removed (a final "deregistered" line, or a 401).
  """
  def follow(%{id: id, headers: headers}) do
    parent = self()
    spawn_link(fn -> tail(parent, id, headers) end)
  end

  defp tail(parent, id, headers) do
    url = String.to_charlist(base_url() <> "/v1/endpoints/#{id}/tail?ack=1")
    charlists = Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    # Its own httpc profile, so the endless stream never blocks the caller's requests.
    case :inets.start(:httpc, profile: :ww_tool_tail) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case :httpc.request(:get, {url, charlists}, [], [sync: false, stream: :self], :ww_tool_tail) do
      {:ok, ref} -> tail_stream(parent, id, headers, ref, "")
      {:error, _} -> tail_retry(parent, id, headers)
    end
  end

  defp tail_stream(parent, id, headers, ref, buffer) do
    receive do
      {:http, {^ref, :stream_start, _headers}} ->
        tail_stream(parent, id, headers, ref, buffer)

      {:http, {^ref, :stream, chunk}} ->
        [rest | lines] = String.split(buffer <> chunk, "\n") |> Enum.reverse()

        for line <- Enum.reverse(lines), line != "" do
          case Jason.decode!(line) do
            %{"op" => "message", "message" => message} -> send(parent, {:tool_message, message})
            %{"op" => "deregistered"} -> send(parent, :tool_deregistered)
            _ -> :ok
          end
        end

        tail_stream(parent, id, headers, ref, rest)

      {:http, {^ref, {{_, 401, _}, _, _}}} ->
        send(parent, :tool_deregistered)

      {:http, {^ref, _end_or_error}} ->
        tail_retry(parent, id, headers)
    end
  end

  defp tail_retry(parent, id, headers) do
    Process.sleep(1_000)
    tail(parent, id, headers)
  end
end
