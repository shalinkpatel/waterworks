defmodule Ww.TestHTTP do
  @moduledoc false

  @port 17_420

  def request(method, path, body \\ nil, headers \\ []) do
    headers =
      Enum.map(headers, fn {key, value} ->
        {String.to_charlist(key), String.to_charlist(value)}
      end)

    url = String.to_charlist("http://127.0.0.1:#{@port}" <> path)

    request =
      if body do
        {url, headers, ~c"application/json", Jason.encode!(body)}
      else
        {url, headers}
      end

    {:ok, {{_, status, _}, _headers, response}} = :httpc.request(method, request, [], [])

    decoded =
      case Jason.decode(response) do
        {:ok, value} -> value
        _ -> response
      end

    {status, decoded}
  end

  def auth(id, token), do: [{"x-ww-endpoint", id}, {"authorization", "Bearer #{token}"}]
end
