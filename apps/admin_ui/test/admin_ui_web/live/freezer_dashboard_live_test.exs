defmodule AdminUiWeb.FreezerDashboardLiveTest do
  use AdminUiWeb.ConnCase

  import Phoenix.LiveViewTest

  setup do
    previous = Application.get_env(:admin_ui, :legacy_edge_url)

    pid =
      start_supervised!(
        {Bandit, plug: AdminUiWeb.ControllerStub, port: 0, ip: {127, 0, 0, 1}, scheme: :http}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    Application.put_env(:admin_ui, :legacy_edge_url, "http://127.0.0.1:#{port}")

    on_exit(fn -> Application.put_env(:admin_ui, :legacy_edge_url, previous) end)
    :ok
  end

  test "renders the legacy dashboard and the controller audit", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#freezer-FZ-01")
    assert has_element?(view, "#freezer-FZ-01", "Frozen aisle 1")
    assert has_element?(view, "#audit")
    assert has_element?(view, "#login-form")
    assert has_element?(view, "#login-form button", "Sign in to write")
  end

  test "the attacker panel writes with the default credentials", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("button", "Set FZ-01 to +50°C")
    |> render_click()

    assert render(view) =~ "Set FZ-01 to +50°C using the default admin/admin credentials."
  end
end
