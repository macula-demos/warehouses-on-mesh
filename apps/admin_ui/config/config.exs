# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :admin_ui,
  generators: [timestamp_type: :utc_datetime],
  legacy_edge_url: "http://localhost:8080",
  mesh_config_path: "/mesh/realm.json",
  mesh_identity_path: "/data/operator.key",
  mesh_stranger_identity_path: "/data/stranger.key",
  mesh_operator_node_id_path: "/mesh/operator-node-id",
  mesh_station_seed: "station:4433"

config :macula, crypto_profile: :pq_hybrid

# Configure the endpoint
config :admin_ui, AdminUiWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AdminUiWeb.ErrorHTML, json: AdminUiWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: AdminUi.PubSub,
  live_view: [signing_salt: "l6EnFs2m"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  admin_ui: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  admin_ui: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
