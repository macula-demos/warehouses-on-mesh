defmodule FreezerController.RouterTest do
  use ExUnit.Case, async: false

  import Plug.Conn, only: [put_req_header: 3]
  import Plug.Test

  alias FreezerController.FreezerSimulator
  alias FreezerController.Router

  setup do
    :ok = FreezerSimulator.reset()
    :ok
  end

  test "the freezer list is open, as the as-is controller exposed it" do
    conn = call(conn(:get, "/api/freezers"))

    assert conn.status == 200
    assert %{"freezers" => freezers} = Jason.decode!(conn.resp_body)
    assert length(freezers) == 4
  end

  test "a write without credentials is refused" do
    conn =
      conn(:post, "/api/freezers/FZ-01/target", Jason.encode!(%{target_c: 50}))
      |> put_req_header("content-type", "application/json")
      |> call()

    assert conn.status == 401
  end

  test "the default admin credentials can change a target" do
    conn =
      conn(:post, "/api/freezers/FZ-01/target", Jason.encode!(%{target_c: 50}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", basic("admin", "admin"))
      |> call()

    assert conn.status == 200
    assert %{"target_c" => 50.0, "mode" => "cooling"} = Jason.decode!(conn.resp_body)
  end

  test "the session endpoint validates the same credentials" do
    ok =
      conn(:get, "/api/session")
      |> put_req_header("authorization", basic("admin", "admin"))
      |> call()

    assert ok.status == 200
    assert %{"user" => "admin"} = Jason.decode!(ok.resp_body)

    refused =
      conn(:get, "/api/session")
      |> put_req_header("authorization", basic("admin", "wrong"))
      |> call()

    assert refused.status == 401
  end

  test "the audit log names the caller and the action" do
    _ =
      conn(:post, "/api/freezers/FZ-01/target", Jason.encode!(%{target_c: 50}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", basic("admin", "admin"))
      |> call()

    conn = call(conn(:get, "/api/audit"))

    assert conn.status == 200
    assert %{"entries" => [entry | _]} = Jason.decode!(conn.resp_body)
    assert entry["user"] == "admin"
    assert entry["action"] == "set_target"
    assert entry["freezer_id"] == "FZ-01"
    assert entry["result"] == "ok"
  end

  defp call(conn), do: Router.call(conn, Router.init([]))

  defp basic(user, password) do
    "Basic " <> Base.encode64("#{user}:#{password}")
  end
end
