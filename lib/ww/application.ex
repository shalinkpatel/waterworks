defmodule Ww.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    :ok = Ww.Store.setup()

    http =
      if Application.get_env(:ww, :http, true) do
        [
          {
            Bandit,
            # Tails and sockets are endless streams; don't wait the default 15 s for them on stop.
            plug: WwWeb.Router,
            port: Application.get_env(:ww, :port, 7420),
            ip: Application.get_env(:ww, :ip, {127, 0, 0, 1}),
            thousand_island_options: [shutdown_timeout: 1_000]
          }
        ]
      else
        []
      end

    children =
      [
        %{id: :ww_pg, start: {:pg, :start_link, [:ww]}},
        {DynamicSupervisor, name: Ww.MailboxSupervisor, strategy: :one_for_one}
      ] ++ http

    Supervisor.start_link(children, strategy: :one_for_one, name: Ww.Supervisor)
  end
end
