defmodule WwDashboardTest do
  use ExUnit.Case, async: false

  alias Ww.TestHTTP

  @admin "test-admin-token"
  @chrome "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

  setup do
    if Process.whereis(Ww.Supervisor) do
      Enum.each([:ww_messages, :ww_counters, :ww_endpoints], fn table ->
        {:atomic, :ok} = :mnesia.clear_table(table)
      end)
    end

    :ok
  end

  test "dashboard core logic passes its node tests" do
    {output, status} = System.cmd("node", ["--test", "test/js/"], stderr_to_stdout: true)
    assert status == 0, output
  end

  test "CLI deltas rebuild the page exactly when applied by the browser code" do
    base = Enum.map_join(1..400, "\n", &"<p>row #{&1}</p>") <> "\n"

    edited =
      base
      |> String.replace("<p>row 3</p>", "<h1>changed</h1>\n<p>new</p>")
      |> String.replace("<p>row 200</p>\n", "")
      |> String.replace("<p>row 399</p>", "<p>row 399</p>\n<p>appended</p>")

    for {old, new} <- [{base, edited}, {edited, base}, {"a", ""}, {"", "x\ny"}, {base, base}] do
      ops = Ww.CLI.line_delta(old, new)
      assert apply_in_browser_code(old, ops) == new
    end

    assert {"dashboard.render.v1", %{html: ^base}} = Ww.CLI.page_message(base, nil, nil)

    assert {"dashboard.delta.v1", %{base: "msg_prev", ops: ops, title: "T"}} =
             Ww.CLI.page_message(edited, {base, "msg_prev"}, "T")

    assert apply_in_browser_code(base, ops) == edited
    # A rewrite is not worth a delta.
    assert {"dashboard.render.v1", _} =
             Ww.CLI.page_message("<h1>new</h1>", {base, "msg_prev"}, nil)
  end

  defp apply_in_browser_code(old, ops) do
    script = """
    import { applyLineOps } from "./priv/dashboard/core.js";
    let input = "";
    for await (const chunk of process.stdin) input += chunk;
    const { old, ops } = JSON.parse(input);
    process.stdout.write(JSON.stringify(applyLineOps(old, ops)));
    """

    path = Path.join(System.tmp_dir!(), "ww-apply-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(%{old: old, ops: ops}))

    {output, 0} =
      System.cmd("sh", ["-c", "node --input-type=module -e \"$0\" < \"$1\"", script, path])

    File.rm!(path)
    Jason.decode!(output)
  end

  @tag :transport
  test "dashboard assets are served with a restrictive CSP, agent pages with a sandbox" do
    for path <- ["/dashboard", "/dashboard/app.js", "/dashboard/core.js"] do
      assert csp(path) =~ "script-src 'self'"
    end

    assert csp("/dashboard/frame") ==
             "sandbox allow-scripts allow-popups allow-popups-to-escape-sandbox"
  end

  @tag :transport
  @tag :browser
  @tag timeout: 120_000
  test "panel mode: real browser streams, comments on a region, shows replies, and survives reload" do
    run_browser("test/support/dashboard_browser.mjs")
  end

  @tag :transport
  @tag :browser
  @tag timeout: 120_000
  test "page mode: sandboxed agent HTML, streamed data, frame-aware comments, 5 MB republish, reload" do
    run_browser("test/support/dashboard_page_browser.mjs")
  end

  defp csp(path) do
    {:ok, {{_, 200, _}, headers, _body}} =
      :httpc.request(:get, {~c"http://127.0.0.1:17420#{path}", []}, [], [])

    {~c"content-security-policy", csp} = List.keyfind(headers, ~c"content-security-policy", 0)
    to_string(csp)
  end

  defp run_browser(script) do
    {agent, agent_token} = register(%{kind: "agent", name: "dashboard-agent"})
    {dash, dash_token} = register(Ww.CLI.dashboard_endpoint("Fleet health"))

    {output, status} =
      System.cmd("node", [script],
        stderr_to_stdout: true,
        env: [
          {"WW_URL", "http://127.0.0.1:17420"},
          {"AGENT_ID", agent},
          {"AGENT_TOKEN", agent_token},
          {"DASH_ID", dash},
          {"DASH_TOKEN", dash_token},
          {"CHROME", @chrome}
        ]
      )

    assert status == 0, output
  end

  defp register(body) do
    assert {201, response} =
             TestHTTP.request(:post, "/v1/endpoints", body, [{"x-ww-admin-token", @admin}])

    {response["endpoint"]["id"], response["token"]}
  end
end
