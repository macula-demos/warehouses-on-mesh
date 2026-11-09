defmodule FreezerController.Router do
  @moduledoc false

  use Plug.Router

  alias FreezerController.AuditLog
  alias FreezerController.FreezerSimulator

  plug :match
  plug Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason
  plug :dispatch

  get "/" do
    send_resp(conn, 200, """
    <!doctype html>
    <html lang="en">
      <head><meta charset="utf-8"><title>ColdChain Controller 2000</title></head>
      <body style="font-family: system-ui, sans-serif; max-width: 42rem; margin: 3rem auto;">
        <h1>ColdChain Controller 2000</h1>
        <p>Remote management module for refrigeration equipment.</p>
        <p>Firmware 2.4.1 &middot; <a href="/api/freezers">REST API</a></p>
      </body>
    </html>
    """)
  end

  get "/api/health" do
    json(conn, 200, %{status: "ok", service: "freezer-controller"})
  end

  get "/api/freezers" do
    {:ok, freezers} = FreezerSimulator.list()
    json(conn, 200, %{freezers: freezers, simulated_at_ms: System.system_time(:millisecond)})
  end

  get "/api/freezers/:id" do
    case FreezerSimulator.get(id) do
      {:ok, freezer} -> json(conn, 200, freezer)
      {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
    end
  end

  get "/api/session" do
    with_auth(conn, fn conn, user -> json(conn, 200, %{user: user}) end)
  end

  get "/api/audit" do
    json(conn, 200, %{entries: AuditLog.list(50)})
  end

  post "/api/freezers/:id/target" do
    with_auth(conn, fn conn, user ->
      target_c = conn.body_params["target_c"]
      result = FreezerSimulator.set_target(id, target_c)
      audit(conn, user, "set_target", id, %{"target_c" => target_c}, result)

      case result do
        {:ok, freezer} ->
          json(conn, 200, freezer)

        {:error, :not_found} ->
          json(conn, 404, %{error: "not_found"})

        {:error, :invalid_target} ->
          json(conn, 422, %{error: "invalid_target", min: -40, max: 60})
      end
    end)
  end

  post "/api/freezers/:id/defrost" do
    with_auth(conn, fn conn, user ->
      result = FreezerSimulator.start_defrost(id)
      audit(conn, user, "start_defrost", id, %{}, result)
      freezer_result(conn, result)
    end)
  end

  post "/api/freezers/:id/stop" do
    with_auth(conn, fn conn, user ->
      result = FreezerSimulator.stop_defrost(id)
      audit(conn, user, "stop_defrost", id, %{}, result)
      freezer_result(conn, result)
    end)
  end

  post "/api/reset" do
    with_auth(conn, fn conn, user ->
      :ok = FreezerSimulator.reset()
      audit(conn, user, "reset", nil, %{}, :ok)
      json(conn, 200, %{ok: true})
    end)
  end

  match _ do
    json(conn, 404, %{error: "not_found"})
  end

  defp freezer_result(conn, {:ok, freezer}), do: json(conn, 200, freezer)
  defp freezer_result(conn, {:error, :not_found}), do: json(conn, 404, %{error: "not_found"})

  defp with_auth(conn, fun) do
    case authenticate(conn) do
      {:ok, user} ->
        fun.(conn, user)

      :error ->
        conn
        |> put_resp_header("www-authenticate", ~s(Basic realm="freezer-controller"))
        |> json(401, %{error: "unauthorized"})
        |> halt()
    end
  end

  defp authenticate(conn) do
    with ["Basic " <> encoded] <- get_req_header(conn, "authorization"),
         {:ok, decoded} <- Base.decode64(encoded),
         [user, password] <- String.split(decoded, ":", parts: 2),
         true <- valid_credentials?(user, password) do
      {:ok, user}
    else
      _ -> :error
    end
  end

  defp valid_credentials?(user, password) do
    admin_user = System.get_env("LEGACY_ADMIN_USER", "admin")
    admin_password = System.get_env("LEGACY_ADMIN_PASSWORD", "admin")
    gateway_user = System.get_env("GATEWAY_USER", "gateway")
    gateway_password = System.get_env("GATEWAY_PASSWORD", "gateway-demo-password")

    (secure_compare(user, admin_user) and secure_compare(password, admin_password)) or
      (secure_compare(user, gateway_user) and secure_compare(password, gateway_password))
  end

  defp secure_compare(left, right) when is_binary(left) and is_binary(right) do
    Plug.Crypto.secure_compare(left, right)
  end

  defp secure_compare(_left, _right), do: false

  defp audit(conn, user, action, freezer_id, detail, result) do
    AuditLog.record(%{
      at_ms: System.system_time(:millisecond),
      user: user,
      source_ip: source_ip(conn),
      action: action,
      freezer_id: freezer_id,
      detail: detail,
      result: result_string(result)
    })
  end

  defp result_string({:ok, _value}), do: "ok"
  defp result_string({:error, reason}), do: Atom.to_string(reason)
  defp result_string(:ok), do: "ok"

  defp source_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] -> forwarded |> String.split(",") |> hd() |> String.trim()
      [] -> format_ip(conn.remote_ip)
    end
  end

  defp format_ip(ip) do
    ip
    |> :inet.ntoa()
    |> List.to_string()
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
