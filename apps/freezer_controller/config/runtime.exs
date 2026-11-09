import Config

if port = System.get_env("PORT") do
  config :freezer_controller, port: String.to_integer(port)
end
