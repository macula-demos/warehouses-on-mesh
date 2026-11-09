defmodule AdminUiWeb.Router do
  use AdminUiWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AdminUiWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", AdminUiWeb do
    pipe_through :browser

    live "/", FreezerDashboardLive, :index
  end

  get "/health", AdminUiWeb.HealthController, :show
end
