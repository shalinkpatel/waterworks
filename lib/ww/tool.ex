defmodule Ww.Tool do
  @moduledoc """
  Plumbing shared by tool processes (`ww fleet`, `ww log`) that talk to the daemon over HTTP:
  registering endpoints, sending as an endpoint, and following an endpoint's mailbox.
  """

  alias Ww.CLI

  @doc "Registers an endpoint with the admin token; returns its id and request headers."
  def register(admin, body) do
    %{"endpoint" => %{"id" => id}, "token" => token} =
      CLI.request(:post, "/v1/endpoints", body, [{"x-ww-admin-token", admin}], false)

    {id, [{"x-ww-endpoint", id}, {"authorization", "Bearer #{token}"}]}
  end

  @doc "A viewer URL for a daemon-served page: the token rides in the fragment, never sent."
  def view_url(path, viewer_id, viewer_headers, extra) do
    "Bearer " <> token = :proplists.get_value("authorization", viewer_headers)
    query = URI.encode_query(Map.merge(%{"endpoint" => viewer_id, "token" => token}, extra))
    CLI.base_url() <> path <> "#" <> query
  end

  def request(method, path, body, headers), do: CLI.request(method, path, body, headers, false)

  def send_message(headers, to, type, payload, extra \\ %{}),
    do:
      request(
        :post,
        "/v1/messages",
        Map.merge(%{to: to, type: type, payload: payload}, extra),
        headers
      )

  @doc """
  Streams the endpoint's mailbox (auto-acknowledged) to the calling process as
  `{:tool_message, message}`, reconnecting if the daemon restarts. Sends `:tool_deregistered`
  if the endpoint is removed (a final "deregistered" line, or a 401).
  """
  def follow(id, headers) do
    parent = self()
    spawn_link(fn -> tail(parent, id, headers) end)
  end

  defp tail(parent, id, headers) do
    url = String.to_charlist(CLI.base_url() <> "/v1/endpoints/#{id}/tail?ack=1")
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
