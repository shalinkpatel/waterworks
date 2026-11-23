defmodule Ww.Wire do
  @moduledoc false

  def endpoint(endpoint) do
    Map.update!(endpoint, :created_at, &DateTime.to_iso8601/1)
  end

  def message(message) do
    message
    |> Map.from_struct()
    |> Map.update!(:received_at, &DateTime.to_iso8601/1)
  end

  # A send request as every transport receives it: {"to", "type", "payload", "id"?, "reply_to"?}.
  def send_args(body) do
    opts = [id: body["id"], reply_to: body["reply_to"]] |> Enum.reject(&is_nil(elem(&1, 1)))
    {body["to"], body["type"], body["payload"] || %{}, opts}
  end
end
