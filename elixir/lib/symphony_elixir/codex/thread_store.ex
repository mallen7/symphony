defmodule SymphonyElixir.Codex.ThreadStore do
  @moduledoc """
  Persists the Codex thread and Linear command delivery state for each issue.

  The binding lives outside managed issue workspaces so workspace cleanup does
  not discard the conversation. A binding is valid only for the same issue,
  repository route, worker host, workspace, and Codex home.
  """

  require Logger
  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  @state_directory ".symphony/issue-threads"
  @schema_version 1
  @max_delivered_ids 2_000

  @type worker_host :: String.t() | nil
  @type binding :: map()

  @spec binding_for_run(Issue.t(), worker_host(), Path.t()) ::
          {:ok, binding() | nil} | {:error, term()}
  def binding_for_run(%Issue{id: issue_id} = issue, worker_host, workspace)
      when is_binary(issue_id) and is_binary(workspace) do
    with {:ok, state} <- read(issue_id) do
      validate_binding(state, issue, worker_host, workspace)
    end
  end

  def binding_for_run(%Issue{}, _worker_host, _workspace), do: {:error, :invalid_thread_binding_context}

  @spec bound?(Issue.t()) :: boolean()
  def bound?(%Issue{} = issue) do
    case read_binding(issue) do
      {:ok, %{"thread_id" => thread_id}} when is_binary(thread_id) and thread_id != "" -> true
      _ -> false
    end
  end

  @spec worker_affinity(Issue.t()) :: {:bound, worker_host()} | :unbound | {:error, term()}
  def worker_affinity(%Issue{} = issue) do
    case read_binding(issue) do
      {:ok, %{"thread_id" => thread_id} = state} when is_binary(thread_id) and thread_id != "" ->
        {:bound, normalize_worker_host(state["worker_host"])}

      {:ok, _state} ->
        :unbound

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec resume_thread_id(Issue.t(), worker_host(), Path.t()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def resume_thread_id(%Issue{} = issue, worker_host, workspace) do
    case binding_for_run(issue, worker_host, workspace) do
      {:ok, %{"thread_id" => thread_id}} -> {:ok, thread_id}
      {:ok, nil} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec store_thread(Issue.t(), String.t(), worker_host(), Path.t()) :: :ok | {:error, term()}
  def store_thread(%Issue{id: issue_id} = issue, thread_id, worker_host, workspace)
      when is_binary(issue_id) and is_binary(thread_id) and thread_id != "" and is_binary(workspace) do
    locked_update(issue_id, fn state ->
      with :ok <- ensure_thread_unchanged(state, thread_id),
           :ok <- ensure_context_unchanged(state, issue, worker_host, workspace) do
        {:ok,
         state
         |> Map.put("schema_version", @schema_version)
         |> Map.put("issue_id", issue_id)
         |> Map.put("thread_id", thread_id)
         |> Map.put("worker_host", normalize_worker_host(worker_host))
         |> Map.put("workspace", canonical_path(workspace))
         |> Map.put("codex_home", codex_home())
         |> Map.put("repository_labels", Issue.repository_labels(issue))
         |> Map.put_new("bootstrap_at", bootstrap_at(issue))
         |> Map.put_new("delivered_ids", [])}
      end
    end)
  end

  def store_thread(%Issue{}, _thread_id, _worker_host, _workspace),
    do: {:error, :invalid_thread_binding_context}

  @spec pending_messages(Issue.t()) :: [map()]
  def pending_messages(%Issue{} = issue) do
    case issue.agent_messages do
      messages when is_list(messages) ->
        case read_binding(issue) do
          {:ok, %{} = state} when map_size(state) > 0 -> pending_messages_from_state(messages, state)
          _ -> []
        end

      _ ->
        []
    end
  end

  @spec begin_delivery(Issue.t(), [map()]) :: {:ok, String.t() | nil} | {:error, term()}
  def begin_delivery(%Issue{id: issue_id}, []) when is_binary(issue_id), do: {:ok, nil}

  def begin_delivery(%Issue{id: issue_id}, messages)
      when is_binary(issue_id) and is_list(messages) do
    marker = "symphony-linear-batch:" <> batch_digest(messages)

    case locked_update(issue_id, fn state ->
           inflight = %{
             "marker" => marker,
             "ids" => message_ids(messages),
             "messages" => Enum.map(messages, &serialize_message/1)
           }

           {:ok, Map.put(state, "inflight", inflight)}
         end) do
      :ok -> {:ok, marker}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec recover_inflight(Issue.t(), map()) :: :ok | {:error, term()}
  def recover_inflight(%Issue{id: issue_id}, thread_payload)
      when is_binary(issue_id) and is_map(thread_payload) do
    locked_update(issue_id, &recover_inflight_state(&1, thread_payload))
  end

  def recover_inflight(%Issue{}, _thread_payload), do: {:error, :invalid_thread_history}

  @spec acknowledge_messages(Issue.t(), [map()]) :: :ok | {:error, term()}
  def acknowledge_messages(%Issue{id: issue_id}, messages)
      when is_binary(issue_id) and is_list(messages) do
    ids = message_ids(messages)
    locked_update(issue_id, fn state -> {:ok, acknowledge_ids(state, ids)} end)
  end

  def acknowledge_messages(%Issue{}, _messages), do: {:error, :invalid_thread_binding_context}

  defp validate_binding(%{} = state, _issue, _worker_host, _workspace) when map_size(state) == 0,
    do: {:ok, nil}

  defp validate_binding(state, issue, worker_host, workspace) do
    expected = %{
      "issue_id" => issue.id,
      "worker_host" => normalize_worker_host(worker_host),
      "workspace" => canonical_path(workspace),
      "codex_home" => codex_home(),
      "repository_labels" => Issue.repository_labels(issue)
    }

    case Enum.find(expected, fn {key, value} -> Map.get(state, key) != value end) do
      nil -> {:ok, state}
      {key, _value} -> {:error, {:thread_binding_mismatch, String.to_atom(key)}}
    end
  end

  defp ensure_thread_unchanged(%{"thread_id" => stored}, requested)
       when is_binary(stored) and stored != requested,
       do: {:error, :thread_id_replacement_refused}

  defp ensure_thread_unchanged(_state, _requested), do: :ok

  defp ensure_context_unchanged(%{} = state, issue, worker_host, workspace) do
    case validate_binding(state, issue, worker_host, workspace) do
      {:ok, _state} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_binding(%Issue{id: issue_id} = issue) when is_binary(issue_id) do
    with {:ok, state} <- read(issue_id) do
      validate_repository_binding(state, issue)
    end
  end

  defp read_binding(_issue), do: {:error, :invalid_thread_binding_context}

  defp recover_inflight_state(
         %{"inflight" => %{"marker" => marker, "ids" => ids}} = state,
         thread_payload
       )
       when is_binary(marker) and is_list(ids) do
    if payload_contains_marker?(thread_payload, marker),
      do: {:ok, acknowledge_ids(state, ids)},
      else: {:ok, state}
  end

  defp recover_inflight_state(state, _thread_payload), do: {:ok, state}

  defp validate_repository_binding(%{"repository_labels" => labels} = state, issue)
       when is_list(labels) do
    if labels == Issue.repository_labels(issue),
      do: {:ok, state},
      else: {:error, {:thread_binding_mismatch, :repository_labels}}
  end

  defp validate_repository_binding(%{} = state, _issue) when map_size(state) == 0, do: {:ok, state}
  defp validate_repository_binding(%{}, _issue), do: {:error, :incomplete_thread_binding}

  defp pending_messages_from_state(messages, state) do
    delivered = MapSet.new(state["delivered_ids"] || [])
    bootstrap_at = parse_datetime(state["bootstrap_at"])

    inflight_messages =
      case state["inflight"] do
        %{"messages" => stored} when is_list(stored) -> Enum.map(stored, &deserialize_message/1)
        _ -> []
      end

    (inflight_messages ++ messages)
    |> Enum.reject(&MapSet.member?(delivered, message_id(&1)))
    |> Enum.filter(&message_at_or_after?(&1, bootstrap_at))
    |> Enum.uniq_by(&message_id/1)
    |> Enum.sort_by(&message_sort_key/1)
  end

  defp acknowledge_ids(state, ids) do
    delivered =
      (state["delivered_ids"] || [])
      |> Kernel.++(ids)
      |> Enum.uniq()
      |> Enum.take(-@max_delivered_ids)

    state
    |> Map.put("delivered_ids", delivered)
    |> Map.delete("inflight")
  end

  defp locked_update(issue_id, update_fun)
       when is_binary(issue_id) and is_function(update_fun, 1) do
    :global.trans({__MODULE__, issue_id}, fn ->
      with {:ok, current} <- read(issue_id),
           {:ok, updated} <- update_fun.(current) do
        write(issue_id, updated)
      end
    end)
  end

  defp read(issue_id) do
    path = state_path(issue_id)

    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{"issue_id" => ^issue_id} = state} -> {:ok, state}
          {:ok, _state} -> {:error, :thread_state_issue_mismatch}
          {:error, reason} -> {:error, {:invalid_thread_state, reason}}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, {:thread_state_read_failed, reason}}
    end
  end

  defp write(issue_id, state) when is_binary(issue_id) and is_map(state) do
    path = state_path(issue_id)
    directory = Path.dirname(path)
    temporary_path = path <> ".tmp-#{System.unique_integer([:positive, :monotonic])}"

    with :ok <- File.mkdir_p(directory),
         :ok <- File.write(temporary_path, Jason.encode!(state) <> "\n", [:binary]),
         :ok <- File.chmod(temporary_path, 0o600),
         :ok <- File.rename(temporary_path, path) do
      :ok
    else
      {:error, reason} = error ->
        File.rm(temporary_path)
        Logger.warning("Unable to persist Codex thread state issue_id=#{issue_id} reason=#{inspect(reason)}")
        error
    end
  end

  defp state_path(issue_id) when is_binary(issue_id) do
    digest = :crypto.hash(:sha256, issue_id) |> Base.encode16(case: :lower)
    Path.join([Config.local_workspace_root(), @state_directory, digest <> ".json"])
  end

  defp canonical_path(path), do: Path.expand(path)

  defp codex_home do
    case System.get_env("CODEX_HOME") do
      value when is_binary(value) and value != "" -> Path.expand(value)
      _ -> Path.join(System.user_home!(), ".codex")
    end
  end

  defp bootstrap_at(_issue), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp batch_digest(messages) do
    messages
    |> Enum.map_join("\n", fn message -> "#{message_id(message)}:#{message_body(message)}" end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp message_ids(messages), do: messages |> Enum.map(&message_id/1) |> Enum.reject(&is_nil/1)

  defp serialize_message(message) do
    %{
      "id" => message_id(message),
      "body" => message_body(message),
      "author_name" => message_value(message, :author_name),
      "created_at" => serialize_datetime(message_value(message, :created_at)),
      "updated_at" => serialize_datetime(message_value(message, :updated_at))
    }
  end

  defp deserialize_message(message) when is_map(message) do
    %{
      id: message["id"],
      body: message["body"],
      author_name: message["author_name"],
      created_at: parse_datetime(message["created_at"]),
      updated_at: parse_datetime(message["updated_at"])
    }
  end

  defp message_value(message, key) when is_map(message), do: Map.get(message, key) || Map.get(message, to_string(key))
  defp message_id(message), do: message_value(message, :id)
  defp message_body(message), do: message_value(message, :body) || ""

  defp message_sort_key(message) do
    case message_value(message, :updated_at) || message_value(message, :created_at) do
      %DateTime{} = datetime -> {DateTime.to_unix(datetime, :microsecond), message_id(message) || ""}
      _ -> {0, message_id(message) || ""}
    end
  end

  defp message_at_or_after?(_message, nil), do: true

  defp message_at_or_after?(message, %DateTime{} = bootstrap_at) do
    case message_value(message, :updated_at) || message_value(message, :created_at) do
      %DateTime{} = datetime -> DateTime.compare(datetime, bootstrap_at) in [:gt, :eq]
      _ -> false
    end
  end

  defp payload_contains_marker?(payload, marker) when is_map(payload) do
    Enum.any?(payload, fn {key, value} ->
      payload_contains_marker?(key, marker) or payload_contains_marker?(value, marker)
    end)
  end

  defp payload_contains_marker?(payload, marker) when is_list(payload),
    do: Enum.any?(payload, &payload_contains_marker?(&1, marker))

  defp payload_contains_marker?(payload, marker) when is_binary(payload),
    do: String.contains?(payload, marker)

  defp payload_contains_marker?(_payload, _marker), do: false

  defp serialize_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp serialize_datetime(_datetime), do: nil

  defp parse_datetime(%DateTime{} = datetime), do: datetime

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp normalize_worker_host(worker_host) when is_binary(worker_host) do
    case String.trim(worker_host) do
      "" -> nil
      host -> host
    end
  end

  defp normalize_worker_host(_worker_host), do: nil
end
