defmodule AdminUiWeb.HealthController do
  use AdminUiWeb, :controller

  def show(conn, _params) do
    send_resp(conn, 200, "ok")
  end
end
