defmodule March.Feishu.TaskAdapter do
  @moduledoc """
  Feishu Task-backed tracker adapter.
  """

  @behaviour March.Tracker
  require Logger

  alias March.Config
  alias March.Feishu.{TaskClient, TaskDescription}
  alias March.Tracker.Item

  @current_plan_field "Current Plan"
  @builder_workpad_field "Builder Workpad"
  @auditor_verdict_field "Auditor Verdict"
  @pr_field "PR"
  @task_kind_field "Task Kind"
  @task_key_field "Task Key"
  @backlog_stage "Backlog"
  @context_cache_ttl_ms 300_000
  @comments_cache_ttl_ms 15_000
  @task_fetch_max_concurrency 6
  @context_cache_key {__MODULE__, :context_cache}
  @issue_cache_key {__MODULE__, :issue_cache}

  @spec fetch_candidate_issues() :: {:ok, [Item.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tasklist_guid = Config.feishu_tasklist_guid()

    with {:ok, guids} <- task_client().list_tasklist_task_guids(tasklist_guid),
         {:ok, context} <- tasklist_context(tasklist_guid) do
      {issues, stats} = fetch_and_normalize_tasks(guids, context)
      store_candidate_fetch_stats(stats)
      {:ok, issues}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Item.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    wanted =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    with {:ok, issues} <- fetch_candidate_issues() do
      {:ok,
       Enum.filter(issues, fn %Item{state: state} ->
         MapSet.member?(wanted, normalize_state(state))
       end)}
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Item.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    tasklist_guid = Config.feishu_tasklist_guid()

    with {:ok, context} <- tasklist_context(tasklist_guid) do
      {issues, _stats} = fetch_and_normalize_tasks(Enum.uniq(issue_ids), context)
      {:ok, issues}
    end
  end

  @spec fetch_issue_comments(String.t()) :: {:ok, [map()]} | {:error, term()}
  def fetch_issue_comments(issue_id) when is_binary(issue_id) do
    with {:ok, comments} <- task_client().list_comments(issue_id) do
      {:ok, normalize_comments(comments)}
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    task_client().create_comment(issue_id, body)
  end

  @spec create_comment(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def create_comment(issue_id, body, _opts) when is_binary(issue_id) and is_binary(body) do
    create_comment(issue_id, body)
  end

  @spec update_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def update_comment(_comment_id, _body), do: {:error, :unsupported}

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, task} <- task_client().get_task(issue_id),
         tasklist_guid <- selected_tasklist_guid(task),
         {:ok, sections} <- task_client().list_sections(tasklist_guid),
         {:ok, section_guid} <- section_guid_for_state(sections, state_name),
         :ok <- task_client().move_task_to_section(issue_id, tasklist_guid, section_guid) do
      :ok
    else
      nil -> {:error, :missing_feishu_tasklist_guid}
      other -> other
    end
  end

  @spec update_issue_extra(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_extra(issue_id, extra) when is_binary(issue_id) and is_binary(extra) do
    with {:ok, _task} <- task_client().patch_task(issue_id, ["extra"], %{"extra" => extra}) do
      :ok
    end
  end

  @doc false
  def clear_context_cache_for_test do
    :persistent_term.put(@context_cache_key, %{})
    :persistent_term.put(@issue_cache_key, %{})

    :ok
  end

  @doc false
  def comments_required_for_stage_for_test(stage_name), do: comments_required_for_stage?(stage_name)

  @doc false
  def issue_cache_entry_for_test(task_guid) when is_binary(task_guid) do
    issue_cache()
    |> Map.get(task_guid)
  end

  @doc false
  @spec normalize_task_payload(map(), [map()], map()) :: Item.t()
  def normalize_task_payload(task, comments, context) when is_map(task) and is_list(comments) and is_map(context) do
    description = TaskDescription.parse(Map.get(task, "description"))
    tasklists = Map.get(task, "tasklists", [])
    selected_tasklist = select_tasklist(tasklists)
    section_guid = Map.get(selected_tasklist || %{}, "section_guid")
    extra = Map.get(task, "extra")
    custom_fields = Map.get(task, "custom_fields", [])
    task_key = custom_field_text(custom_fields, @task_key_field)
    identifier = task_identifier(task, task_key)

    %Item{
      id: Map.get(task, "guid"),
      identifier: identifier,
      task_key: task_key,
      title: Map.get(task, "summary"),
      description: description.raw,
      body: description.body,
      state: stage_name(section_guid, context),
      url: Map.get(task, "url"),
      assignee_id: assignee_id(task),
      tasklist_guid: Map.get(selected_tasklist || %{}, "tasklist_guid"),
      task_section_guid: section_guid,
      task_section_guids_by_name: Map.get(context, :section_guids_by_name, %{}),
      task_custom_field_guids: Map.get(context, :custom_field_guids_by_name, %{}),
      task_kind_option_guids: Map.get(context, :task_kind_option_guids_by_name, %{}),
      task_status: Map.get(task, "status"),
      extra: extra,
      current_plan: custom_field_text(custom_fields, @current_plan_field),
      builder_workpad: custom_field_text(custom_fields, @builder_workpad_field),
      auditor_verdict: custom_field_text(custom_fields, @auditor_verdict_field),
      pr_url: custom_field_text(custom_fields, @pr_field),
      task_kind: custom_field_single_select(custom_fields, @task_kind_field, Map.get(context, :task_kind_options_by_guid, %{})),
      comments: normalize_comments(comments),
      tracker_payload: task,
      fetched_at: DateTime.utc_now(),
      created_at: parse_unix_ms(Map.get(task, "created_at")),
      updated_at: parse_unix_ms(Map.get(task, "updated_at"))
    }
  end

  defp fetch_and_normalize_tasks(task_guids, context) when is_list(task_guids) and is_map(context) do
    task_guids
    |> Enum.with_index()
    |> Task.async_stream(
      fn {task_guid, index} ->
        {index, task_guid, fetch_and_normalize_task(task_guid, context)}
      end,
      ordered: false,
      max_concurrency: task_fetch_max_concurrency(task_guids),
      timeout: task_fetch_timeout_ms(),
      on_timeout: :kill_task
    )
    |> Enum.reduce({[], default_fetch_stats(length(task_guids))}, fn
      {:ok, {index, _task_guid, {:ok, issue, task_stats}}}, {acc, stats} ->
        {[{index, issue} | acc], merge_fetch_stats(stats, task_stats)}

      {:ok, {index, task_guid, {:error, reason}}}, {acc, stats} ->
        Logger.warning("Skipping Feishu task during poll task_guid=#{task_guid} index=#{index}: #{inspect(reason)}")
        {acc, merge_fetch_stats(stats, %{skipped: 1})}

      {:exit, reason}, {acc, stats} ->
        Logger.warning("Skipping Feishu task during poll after worker exit: #{inspect(reason)}")
        {acc, merge_fetch_stats(stats, %{skipped: 1})}
    end)
    |> then(fn {entries, stats} ->
      issues =
        entries
        |> Enum.sort_by(fn {index, _issue} -> index end)
        |> Enum.map(fn {_index, issue} -> issue end)

      {issues, %{stats | loaded: length(issues)}}
    end)
  end

  defp fetch_and_normalize_task(task_guid, context) do
    with {:ok, task} <- task_client().get_task(task_guid),
         {:ok, task, sync_stats} <- maybe_sync_task_key(task, context),
         {:ok, issue, cache_stats} <- normalize_task_with_cache(task, task_guid, context) do
      {:ok, issue, merge_fetch_stats(sync_stats, cache_stats)}
    end
  end

  defp tasklist_context(tasklist_guid) when is_binary(tasklist_guid) do
    now_ms = System.monotonic_time(:millisecond)

    case get_cached_tasklist_context(tasklist_guid, now_ms) do
      {:ok, context} ->
        {:ok, context}

      :miss ->
        with {:ok, sections} <- task_client().list_sections(tasklist_guid),
             {:ok, custom_fields} <- task_client().list_custom_fields(tasklist_guid) do
          context = %{
            section_names_by_guid: section_names_by_guid(sections),
            section_guids_by_name: section_guids_by_name(sections),
            default_section_guids: default_section_guids(sections),
            custom_field_guids_by_name: custom_field_guids_by_name(custom_fields),
            task_kind_options_by_guid: task_kind_options_by_guid(custom_fields),
            task_kind_option_guids_by_name: task_kind_option_guids_by_name(custom_fields)
          }

          put_cached_tasklist_context(tasklist_guid, context, now_ms)
          {:ok, context}
        else
          {:error, reason} = error ->
            case get_stale_cached_tasklist_context(tasklist_guid) do
              {:ok, cached_context} ->
                Logger.warning("Using stale Feishu tasklist context cache tasklist_guid=#{tasklist_guid}: #{inspect(reason)}")

                {:ok, cached_context}

              :miss ->
                error
            end
        end
    end
  end

  defp tasklist_context(_tasklist_guid), do: {:error, :missing_feishu_tasklist_guid}

  defp maybe_sync_task_key(task, context) when is_map(task) and is_map(context) do
    custom_fields = Map.get(task, "custom_fields", [])
    current_task_key = custom_field_text(custom_fields, @task_key_field)
    desired_task_key = desired_task_key(task)
    task_guid = Map.get(task, "guid")
    task_key_field_guid = get_in(context, [:custom_field_guids_by_name, @task_key_field])

    cond do
      is_nil(desired_task_key) ->
        {:ok, task, default_fetch_stats()}

      current_task_key == desired_task_key ->
        {:ok, task, default_fetch_stats()}

      not is_binary(task_guid) or not is_binary(task_key_field_guid) ->
        {:ok, task, default_fetch_stats()}

      true ->
        case task_client().patch_task(task_guid, ["custom_fields"], %{
               "custom_fields" => [
                 %{"guid" => task_key_field_guid, "text_value" => desired_task_key}
               ]
             }) do
          {:ok, patched_task} ->
            {:ok, patched_task, %{patches: 1}}

          {:error, reason} ->
            Logger.warning("Failed to sync Task Key for task_guid=#{task_guid} desired_task_key=#{desired_task_key}: #{inspect(reason)}")

            {:ok, task, default_fetch_stats()}
        end
    end
  end

  defp assignee_id(%{"members" => members}) when is_list(members) do
    members
    |> Enum.find(fn member -> Map.get(member, "role") == "assignee" end)
    |> case do
      %{} = member -> Map.get(member, "id")
      _ -> nil
    end
  end

  defp assignee_id(_task), do: nil

  defp task_identifier(task, task_key) when is_map(task) do
    task_key || Map.get(task, "task_id") || Map.get(task, "guid")
  end

  defp desired_task_key(task) when is_map(task) do
    case {Config.feishu_task_key_prefix(), Map.get(task, "task_id")} do
      {prefix, task_id} when is_binary(prefix) and is_binary(task_id) ->
        prefix = String.trim(prefix)
        task_id = String.trim(task_id)

        cond do
          prefix == "" -> nil
          task_id == "" -> nil
          true -> "#{prefix}/#{task_id}"
        end

      _ ->
        nil
    end
  end

  defp selected_tasklist_guid(task) when is_map(task) do
    task
    |> Map.get("tasklists", [])
    |> select_tasklist()
    |> case do
      %{} = tasklist -> Map.get(tasklist, "tasklist_guid")
      _ -> Config.feishu_tasklist_guid()
    end
  end

  defp select_tasklist(tasklists) when is_list(tasklists) do
    configured_guid = Config.feishu_tasklist_guid()

    Enum.find(tasklists, fn
      %{"tasklist_guid" => ^configured_guid} when is_binary(configured_guid) -> true
      _ -> false
    end) || List.first(tasklists)
  end

  defp section_guid_for_state(sections, state_name) when is_list(sections) and is_binary(state_name) do
    normalized_state = normalize_state(state_name)

    case Enum.find(sections, fn section -> normalize_state(section_name(section)) == normalized_state end) do
      %{"guid" => guid} when is_binary(guid) ->
        {:ok, guid}

      _ ->
        {:error, {:unknown_feishu_task_section, state_name}}
    end
  end

  defp section_name(section) when is_map(section) do
    cond do
      Map.get(section, "is_default") == true -> @backlog_stage
      true -> Map.get(section, "name") || ""
    end
  end

  defp stage_name(section_guid, context) when is_binary(section_guid) and is_map(context) do
    cond do
      MapSet.member?(Map.get(context, :default_section_guids, MapSet.new()), section_guid) ->
        @backlog_stage

      true ->
        context
        |> Map.get(:section_names_by_guid, %{})
        |> Map.get(section_guid)
        |> blank_to_default_stage()
    end
  end

  defp stage_name(_section_guid, _context), do: Config.default_tracker_stage()

  defp custom_field_text(custom_fields, field_name) do
    custom_fields
    |> Enum.find(fn field -> Map.get(field, "name") == field_name end)
    |> case do
      %{} = field -> blank_to_nil(Map.get(field, "text_value"))
      _ -> nil
    end
  end

  defp custom_field_single_select(custom_fields, field_name, options_by_guid) do
    custom_fields
    |> Enum.find(fn field -> Map.get(field, "name") == field_name end)
    |> case do
      %{} = field ->
        field
        |> Map.get("single_select_value")
        |> case do
          value when is_binary(value) -> Map.get(options_by_guid, value)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp task_kind_options_by_guid(custom_fields) when is_list(custom_fields) do
    custom_fields
    |> Enum.find(fn field -> Map.get(field, "name") == @task_kind_field end)
    |> case do
      %{} = field ->
        field
        |> get_in(["single_select_setting", "options"])
        |> List.wrap()
        |> Map.new(fn option -> {Map.get(option, "guid"), Map.get(option, "name")} end)

      _ ->
        %{}
    end
  end

  defp task_kind_option_guids_by_name(custom_fields) when is_list(custom_fields) do
    custom_fields
    |> Enum.find(fn field -> Map.get(field, "name") == @task_kind_field end)
    |> case do
      %{} = field ->
        field
        |> get_in(["single_select_setting", "options"])
        |> List.wrap()
        |> Map.new(fn option -> {Map.get(option, "name"), Map.get(option, "guid")} end)

      _ ->
        %{}
    end
  end

  defp section_names_by_guid(sections) when is_list(sections) do
    Map.new(sections, fn section -> {Map.get(section, "guid"), section_name(section)} end)
  end

  defp section_guids_by_name(sections) when is_list(sections) do
    Map.new(sections, fn section -> {section_name(section), Map.get(section, "guid")} end)
  end

  defp default_section_guids(sections) when is_list(sections) do
    sections
    |> Enum.filter(&(Map.get(&1, "is_default") == true))
    |> Enum.map(&Map.get(&1, "guid"))
    |> MapSet.new()
  end

  defp custom_field_guids_by_name(custom_fields) when is_list(custom_fields) do
    Map.new(custom_fields, fn field -> {Map.get(field, "name"), Map.get(field, "guid")} end)
  end

  defp normalize_comments(comments) when is_list(comments) do
    comments
    |> Enum.map(fn comment ->
      %{
        id: Map.get(comment, "id"),
        content: Map.get(comment, "content"),
        resource_id: Map.get(comment, "resource_id"),
        resource_type: Map.get(comment, "resource_type"),
        creator_id: get_in(comment, ["creator", "id"]),
        created_at: Map.get(comment, "created_at"),
        updated_at: Map.get(comment, "updated_at")
      }
    end)
    |> Enum.sort_by(fn comment -> {comment.created_at || "", comment.id || ""} end)
  end

  defp parse_unix_ms(value) when is_binary(value) do
    case Integer.parse(value) do
      {milliseconds, ""} ->
        DateTime.from_unix!(milliseconds, :millisecond)

      _ ->
        nil
    end
  rescue
    _error -> nil
  end

  defp parse_unix_ms(_value), do: nil

  defp normalize_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state_name), do: ""

  defp blank_to_default_stage(nil), do: Config.default_tracker_stage()

  defp blank_to_default_stage(value) when is_binary(value) do
    case String.trim(value) do
      "" -> Config.default_tracker_stage()
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_task_with_cache(task, task_guid, context)
       when is_map(task) and is_binary(task_guid) and is_map(context) do
    now_ms = System.monotonic_time(:millisecond)
    comments_required? = comments_required_for_task?(task, context)
    task_updated_at = blank_to_nil(Map.get(task, "updated_at"))

    case cached_issue_for(task_guid, task_updated_at, comments_required?, now_ms) do
      {:ok, %Item{} = issue, cache_stats} ->
        {:ok, refresh_cached_issue(issue, task), cache_stats}

      :miss ->
        with {:ok, comments, comment_stats} <- fetch_comments_for_task(task, task_guid, context, task_updated_at, now_ms) do
          issue = normalize_task_payload(task, comments, context)
          cache_issue(task_guid, task_updated_at, issue, now_ms, comments_required?)
          {:ok, issue, comment_stats}
        end
    end
  end

  defp maybe_fetch_comments(task, task_guid, context)
       when is_map(task) and is_binary(task_guid) and is_map(context) do
    if comments_required_for_task?(task, context) do
      task_client().list_comments(task_guid)
    else
      {:ok, []}
    end
  end

  defp fetch_comments_for_task(task, task_guid, context, task_updated_at, now_ms)
       when is_map(task) and is_binary(task_guid) and is_map(context) and is_integer(now_ms) do
    cond do
      not comments_required_for_task?(task, context) ->
        {:ok, [], default_fetch_stats()}

      true ->
        case cached_comments_for(task_guid, task_updated_at, now_ms) do
          {:ok, comments} ->
            {:ok, comments, %{comment_cache_hits: 1}}

          :miss ->
            with {:ok, comments} <- maybe_fetch_comments(task, task_guid, context) do
              {:ok, comments, %{comment_fetches: 1}}
            end
        end
    end
  end

  defp comments_required_for_task?(task, context) when is_map(task) and is_map(context) do
    task
    |> Map.get("tasklists", [])
    |> select_tasklist()
    |> case do
      %{} = tasklist -> stage_name(Map.get(tasklist, "section_guid"), context)
      _ -> Config.default_tracker_stage()
    end
    |> comments_required_for_stage?()
  end

  defp comments_required_for_stage?(stage_name) when is_binary(stage_name) do
    case normalize_state(stage_name) do
      "planning" -> true
      "building" -> true
      _ -> false
    end
  end

  defp comments_required_for_stage?(_stage_name), do: false

  defp task_fetch_max_concurrency(task_guids) when is_list(task_guids) do
    task_guids
    |> length()
    |> min(@task_fetch_max_concurrency)
    |> max(1)
  end

  defp task_fetch_timeout_ms do
    Config.lark_cli_timeout_ms() + 1_000
  end

  defp task_client do
    Application.get_env(:march, :feishu_task_client, TaskClient)
  end

  defp cached_issue_for(task_guid, task_updated_at, comments_required?, now_ms)
       when is_binary(task_guid) and is_integer(now_ms) and is_boolean(comments_required?) do
    case issue_cache() |> Map.get(task_guid) do
      %{
        task_updated_at: ^task_updated_at,
        issue: %Item{} = issue,
        comments_required?: cached_comments_required?,
        comments_synced_at_ms: comments_synced_at_ms
      } ->
        cond do
          is_nil(task_updated_at) ->
            :miss

          comments_required? and comments_cache_stale?(comments_synced_at_ms, now_ms) ->
            :miss

          comments_required? and not cached_comments_required? ->
            :miss

          true ->
            {:ok, issue, %{issue_cache_hits: 1}}
        end

      _ ->
        :miss
    end
  end

  defp cached_comments_for(task_guid, task_updated_at, now_ms)
       when is_binary(task_guid) and is_integer(now_ms) do
    case issue_cache() |> Map.get(task_guid) do
      %{
        task_updated_at: ^task_updated_at,
        comments: comments,
        comments_synced_at_ms: comments_synced_at_ms
      }
      when is_list(comments) ->
        if is_nil(task_updated_at) or comments_cache_stale?(comments_synced_at_ms, now_ms) do
          :miss
        else
          {:ok, comments}
        end

      _ ->
        :miss
    end
  end

  defp cache_issue(task_guid, task_updated_at, issue, now_ms, comments_required?)
       when is_binary(task_guid) and is_map(issue) and is_integer(now_ms) and is_boolean(comments_required?) do
    comments_synced_at_ms = if comments_required?, do: now_ms, else: nil

    put_issue_cache(
      Map.put(issue_cache(), task_guid, %{
        task_updated_at: task_updated_at,
        issue: issue,
        comments: issue.comments || [],
        comments_required?: comments_required?,
        comments_synced_at_ms: comments_synced_at_ms
      })
    )

    :ok
  end

  defp refresh_cached_issue(%Item{} = issue, task) when is_map(task) do
    %{
      issue
      | tracker_payload: task,
        fetched_at: DateTime.utc_now()
    }
  end

  defp comments_cache_stale?(comments_synced_at_ms, now_ms)
       when is_integer(comments_synced_at_ms) and is_integer(now_ms) do
    now_ms - comments_synced_at_ms > @comments_cache_ttl_ms
  end

  defp comments_cache_stale?(_comments_synced_at_ms, _now_ms), do: true

  defp get_cached_tasklist_context(tasklist_guid, now_ms)
       when is_binary(tasklist_guid) and is_integer(now_ms) do
    case context_cache() |> Map.get(tasklist_guid) do
      %{context: context, cached_at_ms: cached_at_ms}
      when is_map(context) and is_integer(cached_at_ms) and now_ms - cached_at_ms <= @context_cache_ttl_ms ->
        {:ok, context}

      _ ->
        :miss
    end
  end

  defp get_stale_cached_tasklist_context(tasklist_guid) when is_binary(tasklist_guid) do
    case context_cache() |> Map.get(tasklist_guid) do
      %{context: context} when is_map(context) -> {:ok, context}
      _ -> :miss
    end
  end

  defp put_cached_tasklist_context(tasklist_guid, context, now_ms)
       when is_binary(tasklist_guid) and is_map(context) and is_integer(now_ms) do
    put_context_cache(Map.put(context_cache(), tasklist_guid, %{context: context, cached_at_ms: now_ms}))

    :ok
  end

  defp context_cache, do: :persistent_term.get(@context_cache_key, %{})
  defp issue_cache, do: :persistent_term.get(@issue_cache_key, %{})
  defp put_context_cache(cache) when is_map(cache), do: :persistent_term.put(@context_cache_key, cache)
  defp put_issue_cache(cache) when is_map(cache), do: :persistent_term.put(@issue_cache_key, cache)

  defp store_candidate_fetch_stats(stats) when is_map(stats) do
    Application.put_env(
      :march,
      :last_feishu_candidate_fetch_stats,
      Map.put(stats, :captured_at, DateTime.utc_now())
    )
  end

  defp default_fetch_stats(scanned \\ 0) do
    %{
      scanned: scanned,
      loaded: 0,
      skipped: 0,
      issue_cache_hits: 0,
      comment_cache_hits: 0,
      comment_fetches: 0,
      patches: 0
    }
  end

  defp merge_fetch_stats(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      cond do
        is_integer(left_value) and is_integer(right_value) -> left_value + right_value
        true -> right_value
      end
    end)
  end
end
