defmodule WwWeb.Router do
  @moduledoc false
  use Plug.Router

  plug(:check_host)
  plug(:secure_headers)
  plug(:match)
  plug(:fetch_query_params)
  plug(:dispatch)

  get "/v1/health" do
    json(conn, 200, %{ok: true, node: Node.self()})
  end

  post "/v1/endpoints" do
    with :ok <- Ww.authenticate_admin(header(conn, "x-ww-admin-token")),
         {:ok, body, conn} <- read_json(conn),
         {:ok, endpoint, token} <-
           Ww.register_endpoint(
             %{
               kind: body["kind"],
               name: body["name"],
               accepts: body["accepts"] || [],
               emits: body["emits"] || [],
               metadata: body["metadata"] || %{}
             },
             header(conn, "x-ww-admin-token")
           ) do
      json(conn, 201, %{endpoint: Ww.Wire.endpoint(endpoint), token: token})
    else
      {:error, :invalid_json, conn} -> json(conn, 400, %{error: "invalid_json"})
      {:error, reason} -> error(conn, reason)
    end
  end

  get "/v1/endpoints" do
    id = header(conn, "x-ww-endpoint")
    token = bearer_token(conn)

    with {:ok, endpoints} <- Ww.discover(id, token, filters(conn.query_params)) do
      endpoints = filter_online(endpoints, conn.query_params["online"])
      json(conn, 200, %{endpoints: Enum.map(endpoints, &Ww.Wire.endpoint/1)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  get "/v1/endpoints/:id" do
    caller = header(conn, "x-ww-endpoint")

    case Ww.inspect_endpoint(caller, bearer_token(conn), id) do
      {:ok, endpoint} -> json(conn, 200, %{endpoint: Ww.Wire.endpoint(endpoint)})
      {:error, reason} -> error(conn, reason)
    end
  end

  # Admin token: delete any endpoint. Endpoint credentials: delete only yourself.
  delete "/v1/endpoints/:id" do
    auth =
      case header(conn, "x-ww-admin-token") do
        nil -> {:endpoint, header(conn, "x-ww-endpoint"), bearer_token(conn)}
        admin -> {:admin, admin}
      end

    case Ww.deregister(id, auth) do
      :ok -> json(conn, 200, %{ok: true, id: id})
      {:error, reason} -> error(conn, reason)
    end
  end

  patch "/v1/endpoints/:id" do
    with true <- header(conn, "x-ww-endpoint") == id || {:error, :unauthorized},
         {:ok, body, conn} <- read_json(conn),
         {:ok, endpoint} <-
           Ww.update_endpoint(id, bearer_token(conn), %{
             name: body["name"],
             metadata: body["metadata"]
           }) do
      json(conn, 200, %{endpoint: Ww.Wire.endpoint(endpoint)})
    else
      {:error, :invalid_json, conn} -> json(conn, 400, %{error: "invalid_json"})
      {:error, reason} -> error(conn, reason)
    end
  end

  get "/v1/endpoints/:id/history" do
    case Ww.history(id, bearer_token(conn)) do
      {:ok, messages} -> json(conn, 200, %{messages: Enum.map(messages, &Ww.Wire.message/1)})
      {:error, reason} -> error(conn, reason)
    end
  end

  get "/v1/endpoints/:id/tail" do
    case Ww.inspect_endpoint(id, bearer_token(conn), id) do
      {:ok, _} -> WwWeb.Tail.stream(conn, id)
      {:error, reason} -> error(conn, reason)
    end
  end

  get "/v1/endpoints/:id/socket" do
    token = bearer_token(conn) || subprotocol_token(conn)

    case Ww.inspect_endpoint(id, token, id) do
      {:ok, _} ->
        conn =
          if "ww" in websocket_protocols(conn),
            do: put_resp_header(conn, "sec-websocket-protocol", "ww"),
            else: conn

        WebSockAdapter.upgrade(conn, WwWeb.Socket, %{id: id}, [])

      {:error, reason} ->
        error(conn, reason)
    end
  end

  post "/v1/endpoints/:id/ack" do
    with :ok <- Ww.authenticate(id, bearer_token(conn)),
         {:ok, body, conn} <- read_json(conn),
         :ok <- Ww.acknowledge_as(id, body["id"]) do
      json(conn, 200, %{ok: true, id: body["id"]})
    else
      {:error, :invalid_json, conn} -> json(conn, 400, %{error: "invalid_json"})
      {:error, reason} -> error(conn, reason)
    end
  end

  # Bodies (up to 17 MB) are only read once the caller is authenticated.
  # Lets a sender see whether its message was acknowledged (e.g. broadcast receipts).
  get "/v1/messages/:message_id" do
    case Ww.message_status(header(conn, "x-ww-endpoint"), bearer_token(conn), message_id) do
      {:ok, message, status} ->
        json(conn, 200, %{message: Ww.Wire.message(message), status: status})

      {:error, reason} ->
        error(conn, reason)
    end
  end

  post "/v1/messages" do
    from = header(conn, "x-ww-endpoint")

    with :ok <- Ww.authenticate(from, bearer_token(conn)),
         {:ok, body, conn} <- read_json(conn),
         {to, type, payload, opts} = Ww.Wire.send_args(body),
         {:ok, message} <- Ww.send_as(from, to, type, payload, opts) do
      json(conn, 201, %{message: Ww.Wire.message(message)})
    else
      {:error, :invalid_json, conn} -> json(conn, 400, %{error: "invalid_json"})
      {:error, reason} -> error(conn, reason)
    end
  end

  match _ do
    case conn.method == "GET" && WwWeb.Static.fetch(conn.request_path) do
      {:ok, {type, csp, body}} ->
        conn
        |> put_resp_content_type(type)
        |> put_resp_header("content-security-policy", csp)
        # Pages change with each release: revalidate instead of running a cached old copy.
        |> put_resp_header("cache-control", "no-cache")
        |> send_resp(200, body)

      _ ->
        json(conn, 404, %{error: "not_found"})
    end
  end

  # Rejects requests whose Host is not this daemon (DNS rebinding from a web page). Loopback
  # and the bind address are allowed; `ww serve --allow-host` adds names such as a LAN host.
  defp check_host(conn, _opts) do
    bind = Application.get_env(:ww, :ip, {127, 0, 0, 1}) |> :inet.ntoa() |> to_string()

    allowed = [
      "127.0.0.1",
      "localhost",
      "::1",
      "[::1]",
      bind | Application.get_env(:ww, :allowed_hosts, [])
    ]

    if conn.host in allowed,
      do: conn,
      else: conn |> json(403, %{error: "forbidden_host"}) |> halt()
  end

  defp secure_headers(conn, _opts) do
    conn
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("referrer-policy", "no-referrer")
  end

  defp filters(params) do
    metadata =
      for {"metadata." <> key, value} <- params, into: %{} do
        {key, value}
      end

    %{kind: params["kind"], name: params["name"], accepts: params["accepts"], metadata: metadata}
  end

  defp filter_online(endpoints, "true"), do: Enum.filter(endpoints, & &1.online)
  defp filter_online(endpoints, "false"), do: Enum.reject(endpoints, & &1.online)
  defp filter_online(endpoints, _), do: endpoints

  defp read_json(conn) do
    case Plug.Conn.read_body(conn, length: 17_000_000) do
      {:ok, body, conn} ->
        case Jason.decode(body) do
          {:ok, value} when is_map(value) -> {:ok, value, conn}
          _ -> {:error, :invalid_json, conn}
        end

      _ ->
        {:error, :invalid_json, conn}
    end
  end

  defp header(conn, name), do: conn |> get_req_header(name) |> List.first()

  defp bearer_token(conn) do
    case header(conn, "authorization") do
      "Bearer " <> token -> token
      _ -> nil
    end
  end

  defp subprotocol_token(conn) do
    Enum.find_value(websocket_protocols(conn), fn
      "ww-token." <> token -> token
      _ -> nil
    end)
  end

  defp websocket_protocols(conn) do
    conn
    |> get_req_header("sec-websocket-protocol")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
  end

  defp error(conn, reason) when reason in [:unauthorized, :admin_token_not_configured],
    do: json(conn, 401, %{error: to_string(reason)})

  defp error(conn, :recipient_not_found), do: json(conn, 404, %{error: "recipient_not_found"})
  defp error(conn, :not_found), do: json(conn, 404, %{error: "not_found"})
  defp error(conn, :message_id_conflict), do: json(conn, 409, %{error: "message_id_conflict"})
  defp error(conn, reason), do: json(conn, 400, %{error: to_string(reason)})

  defp json(conn, status, value) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(value))
  end
end
