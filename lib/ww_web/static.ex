defmodule WwWeb.Static do
  @moduledoc false

  @strict "default-src 'self'; connect-src 'self' ws: wss:; script-src 'self'; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'"
  # Agent pages get an opaque origin: they can run scripts and load CDNs but cannot reach the
  # host page, its storage, or the authenticated API.
  @sandbox "sandbox allow-scripts allow-popups allow-popups-to-escape-sandbox"

  @files %{
    "/demo" => {"demo/index.html", "text/html", @strict},
    "/demo/app.js" => {"demo/app.js", "text/javascript", @strict},
    "/dashboard" => {"dashboard/index.html", "text/html", @strict},
    "/dashboard/app.js" => {"dashboard/app.js", "text/javascript", @strict},
    "/dashboard/core.js" => {"dashboard/core.js", "text/javascript", @strict},
    "/dashboard/frame" => {"dashboard/frame.html", "text/html", @sandbox},
    "/dashboard/frame.js" => {"dashboard/frame.js", "text/javascript", @sandbox},
    "/dashboard/helper.js" => {"dashboard/helper.js", "text/javascript", @sandbox}
  }

  for {_route, {file, _type, _csp}} <- @files do
    @external_resource Path.expand("../../priv/#{file}", __DIR__)
  end

  @bodies Map.new(@files, fn {route, {file, type, csp}} ->
            {route, {type, csp, File.read!(Path.expand("../../priv/#{file}", __DIR__))}}
          end)

  def fetch(path), do: Map.fetch(@bodies, path)
end
