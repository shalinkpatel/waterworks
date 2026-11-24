defmodule Ww.TransportCase do
  @moduledoc """
  Shared setup for tests against the test daemon (port 17420): a clean store, endpoint
  registration, waiting, and reading mailboxes. `start_tool/1` runs a tool process (fleet,
  log) against the daemon and stops it after the test.
  """
  use ExUnit.CaseTemplate

  alias Ww.TestHTTP

  @admin "test-admin-token"
  @url "http://127.0.0.1:17420"

  using do
    quote do
      @moduletag :transport
      import Ww.TransportCase
      alias Ww.TestHTTP
    end
  end

  setup do
    Enum.each([:ww_messages, :ww_counters, :ww_endpoints], fn table ->
      {:atomic, :ok} = :mnesia.clear_table(table)
    end)

    :ok
  end

  def admin, do: @admin

  @doc "Runs `fun` (e.g. `fn -> Ww.Fleet.run(200, false) end`) with the tool environment set."
  def start_tool(fun) do
    System.put_env("WW_URL", @url)
    System.put_env("WW_ADMIN_TOKEN", @admin)
    pid = spawn(fun)

    ExUnit.Callbacks.on_exit(fn ->
      Process.exit(pid, :kill)
      System.delete_env("WW_URL")
      System.delete_env("WW_ADMIN_TOKEN")
    end)

    pid
  end

  @doc "Registers an endpoint; returns `{id, token}`."
  def register!(kind, name, accepts \\ [], metadata \\ %{}) do
    {201, %{"endpoint" => %{"id" => id}, "token" => token}} =
      TestHTTP.request(
        :post,
        "/v1/endpoints",
        %{kind: kind, name: name, accepts: accepts, metadata: metadata},
        [{"x-ww-admin-token", @admin}]
      )

    {id, token}
  end

  @doc "The id of the online endpoint accepting `type` (e.g. a tool that has started)."
  def wait_for_endpoint({id, token}, type) do
    wait_until(fn ->
      query = URI.encode_query(%{accepts: type, online: true})

      {200, %{"endpoints" => found}} =
        TestHTTP.request(:get, "/v1/endpoints?" <> query, nil, TestHTTP.auth(id, token))

      case found do
        [%{"id" => found_id}] -> found_id
        _ -> false
      end
    end)
  end

  def send_raw({id, token}, to, type, payload, message_id \\ nil) do
    message_id = message_id || "msg_#{System.unique_integer([:positive])}"

    {201, _} =
      TestHTTP.request(
        :post,
        "/v1/messages",
        %{id: message_id, to: to, type: type, payload: payload},
        TestHTTP.auth(id, token)
      )

    message_id
  end

  @doc "Sends and waits for the reply (matched by reply_to)."
  def ask(sender, to, type, payload) do
    message_id = send_raw(sender, to, type, payload)
    wait_until(fn -> Enum.find(history(sender), &(&1["reply_to"] == message_id)) end)
  end

  def history({id, token}) do
    {200, %{"messages" => messages}} =
      TestHTTP.request(:get, "/v1/endpoints/#{id}/history", nil, TestHTTP.auth(id, token))

    messages
  end

  @doc "Retries `fun` until it returns a truthy value (returned), for up to 5 seconds."
  def wait_until(fun, attempts \\ 100) do
    case fun.() do
      result when result in [nil, false] and attempts > 0 ->
        Process.sleep(50)
        wait_until(fun, attempts - 1)

      result when result in [nil, false] ->
        ExUnit.Assertions.flunk("timed out waiting")

      result ->
        result
    end
  end
end
