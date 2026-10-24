defmodule SymphonyElixir.UniversalRoutingTest do
  use SymphonyElixir.TestSupport

  defmodule GraphQLPlug do
    @spec init(pid()) :: pid()
    def init(parent), do: parent

    @spec call(Plug.Conn.t(), pid()) :: Plug.Conn.t()
    def call(conn, parent) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:graphql_request, Jason.decode!(body)})

      nodes =
        Enum.map([{"issue-a", "repo:pantheon"}, {"issue-b", "repo:deduva"}], fn {id, label} ->
          %{
            "id" => id,
            "identifier" => id,
            "title" => id,
            "state" => %{"name" => "Todo"},
            "labels" => %{"nodes" => [%{"name" => "symphony"}, %{"name" => label}]},
            "inverseRelations" => %{"nodes" => []}
          }
        end)

      payload = %{"data" => %{"issues" => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}}
      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, Jason.encode!(payload))
    end
  end

  test "cross-project polling sends an opt-in query and returns different repository routes" do
    server = start_supervised!({Bandit, plug: {GraphQLPlug, self()}, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    labels = ["symphony", "repo:*"]
    endpoint = "http://127.0.0.1:#{port}/graphql"
    options = [tracker_project_slug: "*", tracker_required_labels: labels, tracker_endpoint: endpoint]
    write_workflow_file!(Workflow.workflow_file_path(), options)
    assert {:ok, issues} = Client.fetch_issues_by_states(["Todo"])
    assert Enum.map(issues, &Issue.repository_labels/1) == [["repo:pantheon"], ["repo:deduva"]]
    assert_receive {:graphql_request, %{"query" => query, "variables" => variables}}
    refute query =~ "$projectSlug"
    assert query =~ "labels: {some: {name: {eq: \"symphony\"}}}"
    assert variables["stateNames"] == ["Todo"]
  end

  test "wildcard polling refuses a missing opt-in configuration before making requests" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_project_slug: "*")
    assert {:error, :universal_scope_requires_symphony_label} = Client.fetch_issues_by_states(["Todo"])
  end

  test "universal routing requires opt in, exactly one safe repo, and honors drain exclusions" do
    required = ["symphony", "repo:*"]
    good = %Issue{dispatchable: true, labels: ["symphony", "repo:pantheon"]}
    assert Issue.routable?(good, required)
    refute Issue.routable?(good, required, ["repo:pantheon"])
    refute Issue.routable?(%{good | labels: ["repo:pantheon"]}, required)
    refute Issue.routable?(%{good | labels: ["symphony"]}, required)
    refute Issue.routable?(%{good | labels: ["symphony", "repo:a", "repo:b"]}, required)
    refute Issue.routable?(%{good | labels: ["symphony", "repo:../escape"]}, required)
    refute Issue.routable?(%{good | dispatchable: false}, required)
  end

  test "repository identity ignores unrelated labels, case and duplicates, and tolerates absent prior state" do
    issue = %Issue{labels: ["Feature", "repo:Pantheon", "repo:pantheon", "symphony"]}
    assert Issue.repository_labels(issue) == ["repo:pantheon"]
    assert Issue.repository_labels(nil) == []
    refute Issue.repository_labels(issue) == Issue.repository_labels(%Issue{labels: ["repo:deduva"]})
  end

  test "wildcard reconciliation preserves state query and restricts to opted-in issues" do
    query_fun = fn query, variables ->
      refute query =~ "$projectSlug"
      refute query =~ "slugId"
      assert query =~ "labels: {some: {name: {eq: \"symphony\"}}}"
      assert variables.ids == ["issue-1"]
      {:ok, %{"data" => %{"issues" => %{"nodes" => []}}}}
    end

    assert {:ok, []} = Client.fetch_issues_by_ids_for_test(["issue-1"], query_fun, "*")
  end

  test "local hooks receive issue routing as data and validate it again before retries" do
    root = Path.join(System.tmp_dir!(), "symphony-universal-hook-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: root,
      hook_after_create: ~s(printf '%s' "$SYMPHONY_ISSUE_LABELS" > labels.json),
      hook_before_run: ~s(printf '%s' "$SYMPHONY_ISSUE_ID" > issue-id)
    )

    issue = %Issue{id: "uuid-1", identifier: "DAT-20", labels: ["symphony", "repo:pantheon"]}
    assert {:ok, workspace} = Workspace.create_for_issue(issue)
    assert Jason.decode!(File.read!(Path.join(workspace, "labels.json"))) == issue.labels
    assert :ok = Workspace.run_before_run_hook(workspace, issue)
    assert File.read!(Path.join(workspace, "issue-id")) == "uuid-1"
  end
end
