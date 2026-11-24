defmodule Ww do
  @moduledoc "Public API for Waterworks endpoint registration and mailboxes."

  alias Ww.{Endpoint, Mailbox, Store}

  # Whole agent-authored pages travel as payloads (real report pages with embedded data reach ~5 MB).
  @max_payload_bytes 16_000_000

  def register_endpoint(attrs, admin_token) when is_map(attrs) do
    with :ok <- authenticate_admin(admin_token),
         :ok <- validate_registration(attrs) do
      token = random_token()

      endpoint = %Endpoint{
        id: random_id("ep"),
        kind: attrs.kind,
        name: attrs.name,
        accepts: Map.get(attrs, :accepts, []),
        emits: Map.get(attrs, :emits, []),
        metadata: Map.get(attrs, :metadata, %{}),
        token_hash: hash(token),
        created_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      :ok = Store.put_endpoint(endpoint)
      {:ok, Endpoint.public(endpoint), token}
    end
  end

  @doc """
  Deletes an endpoint with its messages, and disconnects it. Authorized by the admin token
  ({:admin, token}) or by the endpoint's own credentials ({:endpoint, id, token}); an
  endpoint may only delete itself.
  """
  def deregister(target, auth) do
    with :ok <- authorize_target(target, auth),
         :ok <- Store.delete_endpoint(target) do
      Mailbox.stop(target)
    end
  end

  @doc "Lets an endpoint change its own name and/or metadata (e.g. a renamed agent session)."
  def update_endpoint(id, token, attrs) do
    with :ok <- authenticate(id, token),
         %Endpoint{} = endpoint <- Store.get_endpoint(id) || {:error, :not_found},
         updated = %{
           endpoint
           | name: Map.get(attrs, :name) || endpoint.name,
             metadata: Map.get(attrs, :metadata) || endpoint.metadata
         },
         :ok <-
           validate_registration(Map.take(Map.from_struct(updated), [:kind, :name, :metadata])),
         :ok <- Store.put_endpoint(updated) do
      {:ok, Endpoint.public(updated)}
    end
  end

  defp authorize_target(_target, {:admin, token}), do: authenticate_admin(token)
  defp authorize_target(target, {:endpoint, target, token}), do: authenticate(target, token)
  defp authorize_target(_target, _auth), do: {:error, :unauthorized}

  def discover(id, token, filters \\ %{}) do
    with :ok <- authenticate(id, token) do
      endpoints =
        Store.list_endpoints()
        |> Enum.filter(&matches?(&1, filters))
        |> Enum.map(&Endpoint.public/1)

      {:ok, endpoints}
    end
  end

  def inspect_endpoint(id, token, target) do
    with :ok <- authenticate(id, token),
         %Endpoint{} = endpoint <- Store.get_endpoint(target) || {:error, :not_found} do
      {:ok, Endpoint.public(endpoint)}
    end
  end

  def send_message(from, token, to, type, payload, opts \\ []) do
    with :ok <- authenticate(from, token), do: send_as(from, to, type, payload, opts)
  end

  def subscribe(id, token, pid \\ self()) when is_pid(pid) do
    with :ok <- authenticate(id, token), do: subscribe_as(id, pid)
  end

  def acknowledge(id, token, message_id) do
    with :ok <- authenticate(id, token), do: acknowledge_as(id, message_id)
  end

  def history(id, token) do
    with :ok <- authenticate(id, token), do: {:ok, Store.history(id)}
  end

  # Transports authenticate once (per request or connection) with authenticate/2, then act
  # through these so they never have to keep the raw token in process state.

  @doc false
  def send_as(from, to, type, payload, opts \\ []) do
    id = Keyword.get(opts, :id, random_id("msg"))
    reply_to = Keyword.get(opts, :reply_to)

    with :ok <- validate_message(id, to, type, payload, reply_to),
         %Endpoint{} <- Store.get_endpoint(to) || {:error, :recipient_not_found},
         {:ok, message, created?} <- Store.append(id, from, to, type, payload, reply_to) do
      if created?, do: Mailbox.notify(to)
      {:ok, message}
    end
  end

  @doc false
  def subscribe_as(id, pid \\ self()) when is_pid(pid) do
    with true <- node(pid) == node() || {:error, :subscriber_must_be_local} do
      :pg.leave(:ww, {:endpoint, id}, pid)
      :pg.join(:ww, {:endpoint, id}, pid)

      case Mailbox.subscribe(id, pid) do
        :ok ->
          :ok

        {:error, _} = error ->
          :pg.leave(:ww, {:endpoint, id}, pid)
          error
      end
    end
  end

  @doc false
  def acknowledge_as(id, message_id), do: Store.ack(id, message_id)

  def random_id(prefix), do: "#{prefix}_" <> random_token(18)

  def authenticate_admin(token) do
    case Application.get_env(:ww, :admin_token) do
      expected when is_binary(expected) and expected != "" ->
        if secure_compare(token, expected), do: :ok, else: {:error, :unauthorized}

      _ ->
        {:error, :admin_token_not_configured}
    end
  end

  def authenticate(id, token) do
    case Store.get_endpoint(id) do
      %Endpoint{token_hash: expected} ->
        if is_binary(token) && :crypto.hash_equals(hash(token), expected),
          do: :ok,
          else: {:error, :unauthorized}

      nil ->
        {:error, :unauthorized}
    end
  end

  defp secure_compare(a, b) when is_binary(a) and is_binary(b),
    do: :crypto.hash_equals(hash(a), hash(b))

  defp secure_compare(_, _), do: false
  defp hash(value), do: :crypto.hash(:sha256, value)

  defp random_token(bytes \\ 32),
    do: Base.url_encode64(:crypto.strong_rand_bytes(bytes), padding: false)

  defp validate_registration(attrs) do
    valid? =
      attrs[:kind] in ["agent", "tool"] && is_binary(attrs[:name]) &&
        String.trim(attrs.name) != "" && string_list?(Map.get(attrs, :accepts, [])) &&
        string_list?(Map.get(attrs, :emits, [])) && is_map(Map.get(attrs, :metadata, %{}))

    if valid?, do: :ok, else: {:error, :invalid_endpoint}
  end

  defp validate_message(id, to, type, payload, reply_to) do
    cond do
      !valid_string?(id) || !valid_string?(to) || !valid_string?(type) ->
        {:error, :invalid_message}

      !(is_nil(reply_to) || valid_string?(reply_to)) || !is_map(payload) ->
        {:error, :invalid_message}

      :erlang.external_size(payload) > @max_payload_bytes ->
        {:error, :payload_too_large}

      true ->
        :ok
    end
  end

  defp valid_string?(value), do: is_binary(value) && byte_size(value) in 1..256
  defp string_list?(value), do: is_list(value) && Enum.all?(value, &valid_string?/1)

  defp matches?(endpoint, filters) do
    kind_matches = !filters[:kind] || endpoint.kind == filters[:kind]
    name_matches = !filters[:name] || endpoint.name == filters[:name]

    accepts_matches =
      !filters[:accepts] || filters[:accepts] in endpoint.accepts

    metadata_matches =
      Enum.all?(Map.get(filters, :metadata, %{}), fn {key, value} ->
        Map.get(endpoint.metadata, key) == value
      end)

    kind_matches && name_matches && accepts_matches && metadata_matches
  end
end
