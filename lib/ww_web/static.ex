defmodule WwWeb.Static do
  @moduledoc false

  @strict "default-src 'self'; connect-src 'self' ws: wss:; script-src 'self'; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'"
  # Agent pages get an opaque origin: they can run scripts and load CDNs but cannot reach the
  # host page, its storage, or the authenticated API.
  @sandbox "sandbox allow-scripts allow-popups allow-popups-to-escape-sandbox"
  # The fleet view is first-party like the canvas host, plus the brand web fonts.
  @fleet "default-src 'self'; connect-src 'self' ws: wss:; script-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; frame-ancestors 'none'"

  @files %{
    "/demo" => {"demo/index.html", "text/html", @strict},
    "/demo/app.js" => {"demo/app.js", "text/javascript", @strict},
    "/fleet" => {"fleet/index.html", "text/html", @fleet},
    "/fleet/app.js" => {"fleet/app.js", "text/javascript", @fleet},
    "/canvas" => {"canvas/index.html", "text/html", @strict},
    "/canvas/app.js" => {"canvas/app.js", "text/javascript", @strict},
    "/canvas/core.js" => {"canvas/core.js", "text/javascript", @strict},
    "/canvas/frame" => {"canvas/frame.html", "text/html", @sandbox},
    "/canvas/frame.js" => {"canvas/frame.js", "text/javascript", @sandbox},
    "/canvas/helper.js" => {"canvas/helper.js", "text/javascript", @sandbox}
  }

  for {_route, {file, _type, _csp}} <- @files do
    @external_resource Path.expand("../../priv/#{file}", __DIR__)
  end

  @bodies Map.new(@files, fn {route, {file, type, csp}} ->
            {route, {type, csp, File.read!(Path.expand("../../priv/#{file}", __DIR__))}}
          end)

  def fetch(path), do: Map.fetch(@bodies, path)
end
