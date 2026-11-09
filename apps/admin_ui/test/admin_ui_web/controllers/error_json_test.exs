defmodule AdminUiWeb.ErrorJSONTest do
  use AdminUiWeb.ConnCase, async: true

  test "renders 404" do
    assert AdminUiWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert AdminUiWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
