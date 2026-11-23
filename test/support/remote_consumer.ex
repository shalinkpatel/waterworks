defmodule Ww.TestRemoteConsumer do
  @moduledoc false

  def start(id, token, parent) do
    :ok = Ww.subscribe(id, token)
    forward(parent)
  end

  defp forward(parent) do
    receive do
      {:ww_message, _} = message ->
        send(parent, message)
        forward(parent)
    end
  end
end
