defmodule AdminUiWeb.FreezerDashboardLiveTest do
  use AdminUiWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders the two-site mesh dashboard", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "h1", "Two warehouses, one mesh")
    assert has_element?(view, "button[phx-value-site='A']")
    assert has_element?(view, "button[phx-value-site='B']")
    assert has_element?(view, "#freezers")
    assert render(view) =~ "Providers"
    assert render(view) =~ "Gateway A audit"
  end

  test "switching to site B selects the relay view", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("button[phx-value-site='B']")
    |> render_click()

    assert render(view) =~ "Site B freezers"
    assert render(view) =~ "via relay"
    assert render(view) =~ "Gateway B audit"
  end
end
