import Config

# Secrets (WW_ADMIN_TOKEN) and WW_JOIN are read at runtime by `ww serve`, never here:
# config is evaluated at build time and would be baked into the escript.
config :ww,
  http: true,
  port: 7420,
  ip: {127, 0, 0, 1}

import_config "#{config_env()}.exs"
