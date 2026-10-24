defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker work item in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Codex.ThreadStore
  alias SymphonyElixir.{Config, PromptBuilder, Tracker, Workspace}
  alias SymphonyElixir.Tracker.Issue

  @type worker_host :: String.t() | nil

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issues_by_ids/1)

    with {:ok, resume_thread_id} <- resume_thread_id(issue, worker_host, workspace),
         {:ok, session} <-
           AppServer.start_session(
             workspace,
             worker_host: worker_host,
             resume_thread_id: resume_thread_id
           ) do
      try do
        with :ok <- persist_thread_binding(issue, session.thread_id, worker_host, workspace),
             :ok <- recover_inflight(issue, session.thread_payload) do
          do_run_codex_turns(
            session,
            workspace,
            issue,
            codex_update_recipient,
            opts,
            issue_state_fetcher,
            1,
            max_turns
          )
        end
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    pending_messages = ThreadStore.pending_messages(issue)

    with {:ok, delivery_marker} <- begin_delivery(issue, pending_messages),
         prompt <-
           build_turn_prompt(
             issue,
             opts,
             turn_number,
             max_turns,
             app_session.resumed?,
             pending_messages,
             delivery_marker
           ),
         {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue)
           ),
         :ok <- acknowledge_agent_messages(issue, pending_messages) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_codex_turns(
            app_session,
            workspace,
            refreshed_issue,
            codex_update_recipient,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns, false, pending_messages, delivery_marker) do
    PromptBuilder.build_prompt(issue, opts) <> conversation_prompt(pending_messages, delivery_marker)
  end

  defp build_turn_prompt(_issue, _opts, 1, max_turns, true, pending_messages, delivery_marker) do
    resumed_turn_prompt(max_turns) <> conversation_prompt(pending_messages, delivery_marker)
  end

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns, _resumed?, pending_messages, delivery_marker) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the tracker work item is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
    |> Kernel.<>(conversation_prompt(pending_messages, delivery_marker))
  end

  defp resumed_turn_prompt(max_turns) do
    """
    Continuation guidance:

    - This issue is resuming its existing Codex conversation in a new Symphony run.
    - The original task, prior work, and earlier discussion are already present in this thread.
    - Inspect the current workspace and continue from the latest verified state.
    - This run can use up to #{max_turns} turns. Address any new owner messages below before choosing the next action.
    """
  end

  defp conversation_prompt([], _delivery_marker), do: ""

  defp conversation_prompt(messages, delivery_marker) when is_list(messages) do
    rendered_messages =
      messages
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {message, index} ->
        author = message[:author_name] || message["author_name"] || "Linear user"
        body = message[:body] || message["body"] || ""

        "Message #{index} from #{author}:\n#{body}"
      end)

    """

    New owner messages from the Linear issue conversation:

    Delivery marker: #{delivery_marker}

    #{rendered_messages}

    Treat these messages as the latest user guidance for this issue. Reply through the issue's existing progress comment when a response is useful, and continue authorized work directly.
    """
  end

  defp persist_thread_binding(%Issue{id: issue_id} = issue, thread_id, worker_host, workspace)
       when is_binary(issue_id) do
    case ThreadStore.store_thread(issue, thread_id, worker_host, workspace) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Codex thread binding was not persisted for #{issue_context(issue)} reason=#{inspect(reason)}")
        {:error, {:thread_binding_persistence_failed, reason}}
    end
  end

  defp persist_thread_binding(%Issue{}, _thread_id, _worker_host, _workspace), do: :ok

  defp resume_thread_id(%Issue{id: issue_id} = issue, worker_host, workspace)
       when is_binary(issue_id) do
    ThreadStore.resume_thread_id(issue, worker_host, workspace)
  end

  defp resume_thread_id(%Issue{}, _worker_host, _workspace), do: {:ok, nil}

  defp recover_inflight(%Issue{id: issue_id} = issue, thread_payload)
       when is_binary(issue_id) do
    ThreadStore.recover_inflight(issue, thread_payload)
  end

  defp recover_inflight(%Issue{}, _thread_payload), do: :ok

  defp begin_delivery(%Issue{id: issue_id} = issue, pending_messages)
       when is_binary(issue_id) do
    ThreadStore.begin_delivery(issue, pending_messages)
  end

  defp begin_delivery(%Issue{}, _pending_messages), do: {:ok, nil}

  defp acknowledge_agent_messages(%Issue{id: issue_id} = issue, pending_messages)
       when is_binary(issue_id) do
    case ThreadStore.acknowledge_messages(issue, pending_messages) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Linear conversation delivery was not persisted for #{issue_context(issue)} reason=#{inspect(reason)}")
        {:error, {:conversation_acknowledgement_failed, reason}}
    end
  end

  defp acknowledge_agent_messages(%Issue{}, _pending_messages), do: :ok

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        pending_messages = ThreadStore.pending_messages(refreshed_issue)

        if continue_state?(refreshed_issue, pending_messages) and issue_routable?(refreshed_issue) and
             Issue.repository_labels(issue) == Issue.repository_labels(refreshed_issue) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp continue_state?(%Issue{state: state}, pending_messages) do
    active_issue_state?(state) or
      (pending_messages != [] and comment_wake_state?(state) and not terminal_issue_state?(state))
  end

  defp comment_wake_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.comment_wake_states
    |> Enum.any?(&(normalize_issue_state(&1) == normalized_state))
  end

  defp comment_wake_state?(_state_name), do: false

  defp terminal_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.terminal_states
    |> Enum.any?(&(normalize_issue_state(&1) == normalized_state))
  end

  defp terminal_issue_state?(_state_name), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels, Config.settings!().tracker.excluded_labels)
  end

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
