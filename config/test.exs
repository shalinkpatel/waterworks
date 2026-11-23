import Config

config :ww,
  admin_token: "test-admin-token",
  mnesia_dir: Path.expand("../tmp/mnesia-test-#{node()}", __DIR__),
  http: System.get_env("WW_TEST_HTTP") == "1",
  port: 17_420
