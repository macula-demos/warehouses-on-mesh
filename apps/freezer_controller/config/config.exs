import Config

config :freezer_controller,
  start_http: true,
  port: 8080

import_config "#{config_env()}.exs"
