defmodule FreezerController.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        FreezerController.AuditLog,
        FreezerController.FreezerSimulator
      ] ++ http_children()

    opts = [strategy: :one_for_one, name: FreezerController.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp http_children do
    if Application.get_env(:freezer_controller, :start_http, true) do
      [
        {Bandit,
         scheme: :http,
         plug: FreezerController.Router,
         port: Application.get_env(:freezer_controller, :port, 8080),
         ip: {0, 0, 0, 0}}
      ]
    else
      []
    end
  end
end
