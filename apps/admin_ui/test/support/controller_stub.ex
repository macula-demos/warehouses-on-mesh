defmodule AdminUiWeb.ControllerStub do
  @moduledoc false

  use Plug.Router

  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :dispatch

  @freezer %{
    "id" => "FZ-01",
    "name" => "Frozen aisle 1",
    "kind" => "frozen",
    "current_c" => -18.0,
    "target_c" => -18.0,
    "mode" => "cooling",
    "door_open" => false,
    "safe_min_c" => -25.0,
    "safe_max_c" => -15.0,
    "alarm" => "ok",
    "stock_value_eur" => 15_000,
    "last_changed_at_ms" => nil
  }

  get "/api/freezers" do
    json(conn, %{"freezers" => [@freezer]})
  end

  get "/api/audit" do
    json(conn, %{
      "entries" => [
        %{
          "at_ms" => 1_794_067_956_211,
          "user" => "admin",
          "source_ip" => "10.89.1.3",
          "action" => "set_target",
          "freezer_id" => "FZ-01",
          "detail" => %{"target_c" => 50},
          "result" => "ok"
        }
      ]
    })
  end

  get "/api/session" do
    json(conn, %{"user" => "admin"})
  end

  post "/api/freezers/:id/target" do
    json(conn, %{@freezer | "target_c" => 50.0})
  end

  post "/api/freezers/:id/defrost" do
    json(conn, %{@freezer | "mode" => "defrost"})
  end

  post "/api/freezers/:id/stop" do
    json(conn, @freezer)
  end

  post "/api/reset" do
    json(conn, %{"ok" => true})
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp json(conn, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(body))
  end
end
