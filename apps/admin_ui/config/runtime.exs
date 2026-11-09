import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/admin_ui start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :admin_ui, AdminUiWeb.Endpoint, server: true
end

port = String.to_integer(System.get_env("PORT", "4000"))

config :admin_ui, AdminUiWeb.Endpoint, http: [port: port]

if url = System.get_env("LEGACY_EDGE_URL") do
  config :admin_ui, :legacy_edge_url, url
end

if path = System.get_env("MESH_CONFIG_PATH") do
  config :admin_ui, :mesh_config_path, path
end

if path = System.get_env("MESH_IDENTITY_PATH") do
  config :admin_ui, :mesh_identity_path, path
end

if path = System.get_env("MESH_STRANGER_IDENTITY_PATH") do
  config :admin_ui, :mesh_stranger_identity_path, path
end

if path = System.get_env("MESH_OPERATOR_NODE_ID_PATH") do
  config :admin_ui, :mesh_operator_node_id_path, path
end

if seed = System.get_env("MESH_STATION_SEEDS") do
  config :admin_ui, :mesh_station_seed, seed
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :admin_ui, AdminUiWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/admin_ui_web/router\.ex$"E,
        ~r"lib/admin_ui_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "localhost"

  config :admin_ui, AdminUiWeb.Endpoint,
    url: [host: host, port: port, scheme: "http"],
    http: [ip: {0, 0, 0, 0}, port: port],
    check_origin: false,
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :admin_ui, AdminUiWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :admin_ui, AdminUiWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
