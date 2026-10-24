defmodule SymphonyElixir.ConversationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.ThreadStore
  alias SymphonyElixir.Linear.AgentTool
  alias SymphonyElixir.Orchestrator.State

  test "thread bindings survive runs and conversation messages resume the existing thread" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-conversation-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEX_TRACE}"
      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          *'"method":"thread/start"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-conversation"}}}'
            ;;
          *'"method":"thread/resume"'*)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-conversation"}}}'
            ;;
          *'"method":"turn/start"'*)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-conversation"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEX_TRACE", trace_file)
      on_exit(fn -> System.delete_env("SYMP_TEST_CODEX_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-conversation",
        identifier: "MT-CHAT",
        title: "Keep one conversation",
        description: "Initial task",
        state: "In Progress",
        dispatchable: true,
        labels: ["repo:test"]
      }

      done_fetcher = fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: done_fetcher)

      message_time = DateTime.utc_now()

      follow_up = %{
        issue
        | state: "In Review",
          agent_messages: [
            %{
              id: "comment-1",
              body: "@symphony Please explain the validation result.",
              author_name: "Owner",
              created_at: message_time,
              updated_at: message_time
            }
          ]
      }

      assert :ok = AgentRunner.run(follow_up, nil, issue_state_fetcher: done_fetcher)
      assert ThreadStore.pending_messages(follow_up) == []

      payloads =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)

      assert Enum.count(payloads, &(&1["method"] == "thread/start")) == 1
      assert Enum.count(payloads, &(&1["method"] == "thread/resume")) == 1

      [first_turn, second_turn] = Enum.filter(payloads, &(&1["method"] == "turn/start"))
      first_prompt = get_in(first_turn, ["params", "input", Access.at(0), "text"])
      second_prompt = get_in(second_turn, ["params", "input", Access.at(0), "text"])

      assert first_prompt =~ "You are an agent for this repository."
      assert second_prompt =~ "resuming its existing Codex conversation"
      assert second_prompt =~ "@symphony Please explain the validation result."
      refute second_prompt =~ "Initial task"
    after
      System.delete_env("SYMP_TEST_CODEX_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "conversation delivery suppresses duplicate IDs, including edited commands" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-conversation-cursor-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: test_root,
      tracker_comment_command_prefix: "@symphony",
      tracker_comment_wake_states: ["In Review"]
    )

    issue = %Issue{
      id: "issue-cursor",
      identifier: "MT-CURSOR",
      title: "Cursor",
      labels: ["repo:test"],
      created_at: ~U[2026-10-24 12:00:00Z],
      agent_messages: [
        %{
          id: "historical",
          body: "@symphony old command",
          updated_at: ~U[2020-01-01 00:00:00Z]
        }
      ]
    }

    workspace = Path.join(test_root, "MT-CURSOR")
    assert :ok = ThreadStore.store_thread(issue, "thread-cursor", nil, workspace)
    assert ThreadStore.pending_messages(issue) == []

    first_time = DateTime.add(DateTime.utc_now(), 1, :second)
    second_time = DateTime.add(first_time, 1, :second)

    issue = %{
      issue
      | agent_messages: [
          %{id: "one", body: "@symphony first", updated_at: first_time},
          %{id: "two", body: "@symphony second", updated_at: second_time}
        ]
    }

    assert Enum.map(ThreadStore.pending_messages(issue), & &1.id) == ["one", "two"]
    assert :ok = ThreadStore.acknowledge_messages(issue, issue.agent_messages)
    assert ThreadStore.pending_messages(issue) == []

    edited_time = DateTime.add(second_time, 60, :second)
    edited = %{issue | agent_messages: [%{id: "one", body: "@symphony revised", updated_at: edited_time}]}
    assert ThreadStore.pending_messages(edited) == []

    File.rm_rf(test_root)
  end

  test "an in-flight command remains pending until its marker appears in thread history" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-inflight-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: test_root,
      tracker_comment_command_prefix: "@symphony",
      tracker_comment_wake_states: ["In Review"]
    )

    issue = %Issue{
      id: "issue-inflight",
      identifier: "MT-INFLIGHT",
      title: "Recover delivery",
      labels: ["repo:test"],
      created_at: ~U[2026-10-24 12:00:00Z]
    }

    workspace = Path.join(test_root, "MT-INFLIGHT")
    assert :ok = ThreadStore.store_thread(issue, "thread-inflight", nil, workspace)

    command_time = DateTime.add(DateTime.utc_now(), 1, :second)

    issue = %{
      issue
      | agent_messages: [
          %{
            id: "command-1",
            body: "continue",
            created_at: command_time,
            updated_at: command_time
          }
        ]
    }

    assert {:ok, marker} = ThreadStore.begin_delivery(issue, issue.agent_messages)
    assert Enum.map(ThreadStore.pending_messages(issue), & &1.id) == ["command-1"]

    assert :ok = ThreadStore.recover_inflight(issue, %{"turns" => []})
    assert Enum.map(ThreadStore.pending_messages(issue), & &1.id) == ["command-1"]

    assert :ok = ThreadStore.recover_inflight(issue, %{"turns" => [%{"input" => marker}]})
    assert ThreadStore.pending_messages(issue) == []

    assert {:error, {:thread_binding_mismatch, :workspace}} =
             ThreadStore.resume_thread_id(issue, nil, workspace <> "-other")

    File.rm_rf(test_root)
  end

  test "non-active non-terminal issues with pending conversation messages are dispatchable" do
    test_root = Path.join(System.tmp_dir!(), "symphony-elixir-wake-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: test_root,
      tracker_comment_command_prefix: "@symphony",
      tracker_comment_wake_states: ["In Review"]
    )

    issue = %Issue{
      id: "issue-review-message",
      identifier: "MT-REVIEW",
      title: "Review reply",
      state: "In Review",
      dispatchable: true,
      labels: ["repo:test"],
      created_at: ~U[2026-10-24 12:00:00Z]
    }

    assert :ok = ThreadStore.store_thread(issue, "thread-review", nil, Path.join(test_root, "MT-REVIEW"))

    command_time = DateTime.add(DateTime.utc_now(), 1, :second)

    issue = %{
      issue
      | agent_messages: [
          %{
            id: "comment",
            body: "continue",
            created_at: command_time,
            updated_at: command_time
          }
        ]
    }

    assert Orchestrator.should_dispatch_issue_for_test(issue, %State{})
    refute Orchestrator.should_dispatch_issue_for_test(%{issue | state: "Done"}, %State{})

    File.rm_rf(test_root)
  end

  test "Linear normalization accepts only owner commands at the start of a comment" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_comment_command_prefix: "@symphony",
      tracker_comment_wake_states: ["In Review"]
    )

    raw_issue = %{
      "id" => "linear-conversation",
      "identifier" => "DAT-99",
      "title" => "Conversation",
      "description" => "Test comments",
      "priority" => 3,
      "state" => %{"name" => "In Review"},
      "branchName" => "dat-99",
      "url" => "https://linear.app/example/issue/DAT-99",
      "assignee" => nil,
      "labels" => %{"nodes" => [%{"name" => "symphony"}]},
      "inverseRelations" => %{"nodes" => []},
      "comments" => %{
        "nodes" => [
          %{
            "id" => "progress",
            "body" => "## Codex progress\nAll tests passed.",
            "createdAt" => "2026-10-24T12:00:00Z",
            "updatedAt" => "2026-10-24T12:00:00Z",
            "user" => %{"id" => "owner", "name" => "Owner"}
          },
          %{
            "id" => "reply",
            "body" => "@symphony: Please continue",
            "createdAt" => "2026-10-24T12:01:00Z",
            "updatedAt" => "2026-10-24T12:01:00Z",
            "user" => %{"id" => "owner", "name" => "Owner"}
          },
          %{
            "id" => "hash-reply",
            "body" => "#symphony explain the failure",
            "createdAt" => "2026-10-24T12:02:00Z",
            "updatedAt" => "2026-10-24T12:02:00Z",
            "user" => %{"id" => "owner", "name" => "Owner"}
          },
          %{
            "id" => "other-user",
            "body" => "@symphony: do something unsafe",
            "createdAt" => "2026-10-24T12:03:00Z",
            "updatedAt" => "2026-10-24T12:03:00Z",
            "user" => %{"id" => "someone-else", "name" => "Other"}
          }
        ]
      },
      "createdAt" => "2026-10-24T11:00:00Z",
      "updatedAt" => "2026-10-24T12:02:00Z"
    }

    issue = Client.normalize_issue_for_test(raw_issue, nil, "owner")

    assert Enum.map(issue.agent_messages, & &1.id) == ["reply"]
    assert hd(issue.agent_messages).body == "Please continue"
    assert hd(issue.agent_messages).author_name == "Owner"
  end

  test "Linear agent tool cannot create a comment using the owner command prefix" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_comment_command_prefix: "@symphony",
      tracker_comment_wake_states: ["In Review"]
    )

    forbidden =
      AgentTool.execute(
        "linear_graphql",
        %{
          "query" => "mutation Reply($input: CommentCreateInput!) { commentCreate(input: $input) { success } }",
          "variables" => %{"input" => %{"body" => "@symphony: loop"}}
        },
        linear_client: fn _query, _variables, _opts -> flunk("reserved command reached Linear") end
      )

    refute forbidden["success"]
    assert forbidden["output"] =~ "reserved for owner-to-Symphony messages"

    forbidden_list =
      AgentTool.execute(
        "linear_graphql",
        %{
          "query" => "mutation Reply($input: CommentUpdateInput!) { commentUpdate(input: $input) { success } }",
          "variables" => %{"input" => ["ordinary text", %{"@symphony: key" => "value"}]}
        },
        linear_client: fn _query, _variables, _opts -> flunk("reserved list command reached Linear") end
      )

    refute forbidden_list["success"]

    allowed =
      AgentTool.execute(
        "linear_graphql",
        %{
          "query" => "mutation Reply($input: CommentCreateInput!) { commentCreate(input: $input) { success } }",
          "variables" => %{"input" => %{"body" => "## Codex progress\nDone"}}
        },
        linear_client: fn _query, _variables, _opts -> {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}} end
      )

    assert allowed["success"]

    allowed_non_string =
      AgentTool.execute(
        "linear_graphql",
        %{
          "query" => "mutation Reply($input: CommentUpdateInput!) { commentUpdate(input: $input) { success } }",
          "variables" => %{"input" => [42, "ordinary text"]}
        },
        linear_client: fn _query, _variables, _opts -> {:ok, %{"data" => %{"commentUpdate" => %{"success" => true}}}} end
      )

    assert allowed_non_string["success"]

    write_workflow_file!(Workflow.workflow_file_path())

    allowed_without_prefix =
      AgentTool.execute(
        "linear_graphql",
        %{
          "query" => "mutation Reply($input: CommentCreateInput!) { commentCreate(input: $input) { success } }",
          "variables" => %{"input" => %{"body" => "@symphony: ordinary when disabled"}}
        },
        linear_client: fn _query, _variables, _opts -> {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}} end
      )

    assert allowed_without_prefix["success"]
  end
end
