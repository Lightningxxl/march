defmodule March.Orchestrator do
  @moduledoc """
  Polls the configured tracker and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias March.{
    AuditorRunner,
    BuilderRunner,
    CanonicalRepo,
    Config,
    Feishu.TaskState,
    PlannerRunner,
    PlannerSessions,
    StatusDashboard,
    Tracker,
    Workflow,
    Workspace
  }

  alias March.Tracker.Item, as: Issue

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  @stall_retry_grace_ms 500
  @dispatch_revalidate_grace_ms 5_000
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :full_scan_interval_ms,
      :idle_full_scan_interval_ms,
      :idle_after_empty_full_scans,
      :consecutive_empty_full_scans,
      :full_scan_mode,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :next_full_scan_due_at_ms,
      :poll_check_in_progress,
      :poll_task_ref,
      :poll_started_at,
      :poll_started_monotonic_ms,
      :last_poll_completed_at,
      :last_successful_poll_at,
      :last_full_scan_at,
      :last_poll_duration_ms,
      :last_poll_status,
      :last_poll_stats,
      :last_repo_sync_status,
      running: %{},
      hot_issue_ids: MapSet.new(),
      completed: MapSet.new(),
      claimed: MapSet.new(),
      retry_attempts: %{},
      codex_totals: nil,
      codex_rate_limits: nil
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    now_ms = System.monotonic_time(:millisecond)

    state = %State{
      poll_interval_ms: Config.poll_interval_ms(),
      full_scan_interval_ms: Config.full_scan_interval_ms(),
      idle_full_scan_interval_ms: Config.idle_full_scan_interval_ms(),
      idle_after_empty_full_scans: Config.idle_after_empty_full_scans(),
      consecutive_empty_full_scans: 0,
      full_scan_mode: :active,
      max_concurrent_agents: Config.max_concurrent_agents(),
      next_poll_due_at_ms: now_ms,
      next_full_scan_due_at_ms: now_ms,
      poll_check_in_progress: false,
      poll_task_ref: nil,
      poll_started_at: nil,
      poll_started_monotonic_ms: nil,
      last_poll_completed_at: nil,
      last_successful_poll_at: nil,
      last_full_scan_at: nil,
      last_poll_duration_ms: nil,
      last_poll_status: nil,
      last_poll_stats: nil,
      last_repo_sync_status: Application.get_env(:march, :last_repo_sync_status),
      codex_totals: @empty_codex_totals,
      codex_rate_limits: nil
    }

    schedule_startup_workspace_cleanup()
    log_routing_config()
    :ok = schedule_tick(0)

    {:ok, state}
  end

  @impl true
  def handle_info(:run_startup_workspace_cleanup, state) do
    Task.start(fn -> run_startup_workspace_cleanup() end)
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)
    state = %{state | poll_check_in_progress: true, next_poll_due_at_ms: nil}

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = start_poll_task(state)

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({poll_task_ref, {:ok, snapshot}}, %{poll_task_ref: poll_task_ref} = state)
      when is_reference(poll_task_ref) do
    Process.demonitor(poll_task_ref, [:flush])

    state =
      state
      |> refresh_runtime_config()
      |> finish_poll_cycle(snapshot)
      |> record_poll_completion(:ok)

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({poll_task_ref, {:error, reason}}, %{poll_task_ref: poll_task_ref} = state)
      when is_reference(poll_task_ref) do
    Process.demonitor(poll_task_ref, [:flush])
    Logger.error("Poll cycle failed: #{inspect(reason)}")

    state =
      schedule_next_poll(%{
        state
        | poll_task_ref: nil,
          poll_check_in_progress: false
      })
      |> record_poll_completion(:error)

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({poll_task_ref, _result}, %{poll_task_ref: poll_task_ref} = state)
      when is_reference(poll_task_ref) do
    Process.demonitor(poll_task_ref, [:flush])

    state =
      schedule_next_poll(%{
        state
        | poll_task_ref: nil,
          poll_check_in_progress: false
      })
      |> record_poll_completion(:error)

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({:DOWN, poll_task_ref, :process, _pid, reason}, %{poll_task_ref: poll_task_ref} = state)
      when is_reference(poll_task_ref) do
    Logger.error("Poll worker exited: #{inspect(reason)}")

    state =
      schedule_next_poll(%{
        state
        | poll_task_ref: nil,
          poll_check_in_progress: false
      })
      |> record_poll_completion(:error)

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)

        state =
          case reason do
            :normal ->
              handle_successful_run(state, issue_id, running_entry, session_id)

            _ ->
              Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

              next_attempt = next_retry_attempt_from_running(running_entry)

              schedule_issue_retry(state, issue_id, next_attempt, %{
                identifier: running_entry.identifier,
                error: "agent exited: #{inspect(reason)}"
              })
          end

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp start_poll_task(%State{poll_task_ref: nil} = state) do
    poll_started_at = DateTime.utc_now()
    poll_started_monotonic_ms = System.monotonic_time(:millisecond)

    task =
      Task.Supervisor.async_nolink(March.TaskSupervisor, fn ->
        run_poll_snapshot(state)
      end)

    %{
      state
      | poll_task_ref: task.ref,
        poll_started_at: poll_started_at,
        poll_started_monotonic_ms: poll_started_monotonic_ms
    }
  end

  defp start_poll_task(%State{} = state), do: state

  defp run_poll_snapshot(%State{} = state) do
    run_poll_snapshot(state, Tracker, fn -> Config.validate!() end)
  rescue
    error -> {:error, {:poll_snapshot_failed, error, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {:poll_snapshot_threw, kind, reason}}
  end

  defp run_poll_snapshot(%State{} = state, tracker, validator)
       when is_atom(tracker) and is_function(validator, 0) do
    now_ms = System.monotonic_time(:millisecond)
    reset_tracker_fetch_stats()
    tracked_hot_issue_ids = tracked_hot_issue_ids(state)
    validation_result = validator.()
    full_scan_due? = full_scan_due?(state, now_ms)

    {issues_result, full_scan_attempted?, authoritative_hot_issue_set?} =
      if full_scan_due? do
        case tracker.fetch_candidate_issues() do
          {:ok, issues} ->
            seen_issue_ids = issue_ids_set(issues)
            leftover_hot_issue_ids = MapSet.difference(tracked_hot_issue_ids, seen_issue_ids)

            case fetch_issues_by_ids(tracker, leftover_hot_issue_ids) do
              {:ok, leftover_issues} ->
                {{:ok, merge_issue_results(issues, leftover_issues)}, true, true}

              {:error, reason} ->
                Logger.debug("Failed to refresh leftover hot issues after full scan: #{inspect(reason)}")
                {{:ok, issues}, true, true}
            end

          {:error, reason} ->
            Logger.warning("Full tracker scan failed during poll: #{inspect(reason)}")
            {fetch_issues_by_ids(tracker, tracked_hot_issue_ids), true, false}
        end
      else
        {fetch_issues_by_ids(tracker, tracked_hot_issue_ids), false, false}
      end

    {:ok,
     %{
       validation_result: validation_result,
       issues_result: issues_result,
       tracked_hot_issue_ids: tracked_hot_issue_ids,
       full_scan_attempted?: full_scan_attempted?,
       authoritative_hot_issue_set?: authoritative_hot_issue_set?
     }}
  end

  defp finish_poll_cycle(%State{} = state, snapshot) when is_map(snapshot) do
    state =
      state
      |> apply_hot_issue_refresh(
        Map.get(snapshot, :issues_result, {:ok, []}),
        Map.get(snapshot, :tracked_hot_issue_ids, MapSet.new()),
        Map.get(snapshot, :authoritative_hot_issue_set?, false)
      )
      |> apply_running_issue_refresh(Map.get(snapshot, :issues_result, {:ok, []}))
      |> apply_candidate_dispatch(
        Map.get(snapshot, :validation_result, {:error, :unknown_poll_validation}),
        Map.get(snapshot, :issues_result, :skipped)
      )
      |> reconcile_full_scan_cadence(Map.get(snapshot, :full_scan_attempted?, false))

    schedule_next_poll(%{
      state
      | poll_task_ref: nil,
        poll_check_in_progress: false
    })
  end

  defp record_poll_completion(%State{} = state, status) when status in [:ok, :error] do
    completed_at = DateTime.utc_now()

    duration_ms =
      case state.poll_started_monotonic_ms do
        started_ms when is_integer(started_ms) ->
          max(0, System.monotonic_time(:millisecond) - started_ms)

        _ ->
          nil
      end

    stats =
      case Application.get_env(:march, :last_feishu_tracker_fetch_stats) do
        %{} = stats_by_mode -> summarize_tracker_fetch_stats(stats_by_mode)
        _ -> nil
      end

    %{
      state
      | poll_started_at: nil,
        poll_started_monotonic_ms: nil,
        last_poll_completed_at: completed_at,
        last_successful_poll_at: if(status == :ok, do: completed_at, else: state.last_successful_poll_at),
        last_poll_duration_ms: duration_ms,
        last_poll_status: status,
        last_poll_stats: stats
    }
  end

  defp schedule_next_poll(%State{} = state) do
    now_ms = System.monotonic_time(:millisecond)
    next_poll_due_at_ms = now_ms + state.poll_interval_ms
    :ok = schedule_tick(state.poll_interval_ms)
    %{state | next_poll_due_at_ms: next_poll_due_at_ms}
  end

  defp reconcile_full_scan_cadence(%State{} = state, true) do
    now_ms = System.monotonic_time(:millisecond)
    idle_candidate? = idle_full_scan_candidate?(state)

    consecutive_empty_full_scans =
      if idle_candidate? do
        state.consecutive_empty_full_scans + 1
      else
        0
      end

    full_scan_mode =
      if consecutive_empty_full_scans >= state.idle_after_empty_full_scans do
        :idle
      else
        :active
      end

    %{
      state
      | last_full_scan_at: DateTime.utc_now(),
        next_full_scan_due_at_ms: now_ms + full_scan_interval_for_mode(state, full_scan_mode),
        consecutive_empty_full_scans: consecutive_empty_full_scans,
        full_scan_mode: full_scan_mode
    }
  end

  defp reconcile_full_scan_cadence(%State{} = state, _full_scan_attempted?) do
    cond do
      idle_full_scan_candidate?(state) ->
        state

      state.full_scan_mode == :idle ->
        wake_full_scan_cadence(state)

      state.consecutive_empty_full_scans > 0 ->
        %{state | consecutive_empty_full_scans: 0, full_scan_mode: :active}

      true ->
        %{state | full_scan_mode: :active}
    end
  end

  defp wake_full_scan_cadence(%State{} = state) do
    now_ms = System.monotonic_time(:millisecond)
    next_due_at_ms = sooner_due_at_ms(state.next_full_scan_due_at_ms, now_ms + state.full_scan_interval_ms)

    %{
      state
      | next_full_scan_due_at_ms: next_due_at_ms,
        consecutive_empty_full_scans: 0,
        full_scan_mode: :active
    }
  end

  defp full_scan_interval_for_mode(%State{} = state, :idle) do
    max(state.idle_full_scan_interval_ms, state.full_scan_interval_ms)
  end

  defp full_scan_interval_for_mode(%State{} = state, _mode), do: state.full_scan_interval_ms

  defp idle_full_scan_candidate?(%State{} = state) do
    map_size(state.running) == 0 and MapSet.size(state.hot_issue_ids) == 0 and
      map_size(state.retry_attempts) == 0
  end

  defp sooner_due_at_ms(existing_due_at_ms, desired_due_at_ms)
       when is_integer(existing_due_at_ms) and is_integer(desired_due_at_ms) do
    min(existing_due_at_ms, desired_due_at_ms)
  end

  defp sooner_due_at_ms(_existing_due_at_ms, desired_due_at_ms), do: desired_due_at_ms

  defp apply_hot_issue_refresh(
         %State{} = state,
         {:ok, issues},
         tracked_hot_issue_ids,
         authoritative_hot_issue_set?
       )
       when is_list(issues) do
    seen_issue_ids = issue_ids_set(issues)

    refreshed_hot_issue_ids =
      issues
      |> Enum.reduce(MapSet.new(), fn
        %Issue{id: issue_id, state: state_name}, acc when is_binary(issue_id) ->
          if hot_issue_state?(state_name) do
            MapSet.put(acc, issue_id)
          else
            acc
          end

        _issue, acc ->
          acc
      end)

    hot_issue_ids =
      if authoritative_hot_issue_set? do
        refreshed_hot_issue_ids
      else
        missing_hot_issue_ids =
          tracked_hot_issue_ids
          |> ensure_map_set()
          |> MapSet.difference(seen_issue_ids)

        MapSet.union(refreshed_hot_issue_ids, missing_hot_issue_ids)
      end

    %{state | hot_issue_ids: hot_issue_ids}
  end

  defp apply_hot_issue_refresh(%State{} = state, {:error, reason}, _tracked_hot_issue_ids, _authoritative_hot_issue_set?) do
    Logger.debug("Failed to refresh hot issue set: #{inspect(reason)}; keeping previous hot issues")
    state
  end

  defp apply_hot_issue_refresh(%State{} = state, _result, _tracked_hot_issue_ids, _authoritative_hot_issue_set?),
    do: state

  defp apply_running_issue_refresh(%State{} = state, {:ok, issues}) when is_list(issues) do
    reconcile_running_issue_states(
      issues,
      reconcile_stalled_running_issues(state),
      automation_state_set(),
      terminal_state_set()
    )
  end

  defp apply_running_issue_refresh(%State{} = state, {:error, reason}) do
    Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")
    reconcile_stalled_running_issues(state)
  end

  defp apply_running_issue_refresh(%State{} = state, _result) do
    reconcile_stalled_running_issues(state)
  end

  defp fetch_issues_by_ids(tracker, issue_ids) when is_atom(tracker) do
    if empty_issue_ids?(issue_ids) do
      {:ok, []}
    else
      issue_ids
      |> MapSet.to_list()
      |> tracker.fetch_issue_states_by_ids()
    end
  end

  defp tracked_hot_issue_ids(%State{} = state) do
    state.hot_issue_ids
    |> ensure_map_set()
    |> MapSet.union(MapSet.new(Map.keys(state.running)))
  end

  defp full_scan_due?(%State{next_full_scan_due_at_ms: nil}, _now_ms), do: true

  defp full_scan_due?(%State{next_full_scan_due_at_ms: due_at_ms}, now_ms)
       when is_integer(due_at_ms) and is_integer(now_ms) do
    due_at_ms <= now_ms
  end

  defp issue_ids_set(issues) when is_list(issues) do
    issues
    |> Enum.reduce(MapSet.new(), fn
      %Issue{id: issue_id}, acc when is_binary(issue_id) -> MapSet.put(acc, issue_id)
      _issue, acc -> acc
    end)
  end

  defp merge_issue_results(primary_issues, secondary_issues)
       when is_list(primary_issues) and is_list(secondary_issues) do
    {merged, _seen_ids} =
      Enum.reduce(primary_issues ++ secondary_issues, {[], MapSet.new()}, fn
        %Issue{id: issue_id} = issue, {acc, seen_ids} when is_binary(issue_id) ->
          if MapSet.member?(seen_ids, issue_id) do
            {acc, seen_ids}
          else
            {[issue | acc], MapSet.put(seen_ids, issue_id)}
          end

        issue, {acc, seen_ids} ->
          {[issue | acc], seen_ids}
      end)

    Enum.reverse(merged)
  end

  defp hot_issue_state?(state_name) when is_binary(state_name) do
    MapSet.member?(automation_state_set(), normalize_issue_state(state_name))
  end

  defp hot_issue_state?(_state_name), do: false

  defp ensure_map_set(%MapSet{} = value), do: value
  defp ensure_map_set(list) when is_list(list), do: MapSet.new(list)
  defp ensure_map_set(_value), do: MapSet.new()

  defp empty_issue_ids?(%MapSet{} = issue_ids), do: MapSet.size(issue_ids) == 0
  defp empty_issue_ids?(issue_ids) when is_list(issue_ids), do: issue_ids == []
  defp empty_issue_ids?(_issue_ids), do: true

  defp reset_tracker_fetch_stats do
    Application.put_env(:march, :last_feishu_tracker_fetch_stats, %{})
  end

  defp summarize_tracker_fetch_stats(stats_by_mode) when is_map(stats_by_mode) do
    full_scan_stats = Map.get(stats_by_mode, :full_scan)
    hot_poll_stats = Map.get(stats_by_mode, :hot_poll)

    case {full_scan_stats, hot_poll_stats} do
      {%{} = full_scan_stats, %{} = hot_poll_stats} ->
        full_scan_stats
        |> merge_tracker_fetch_stats(hot_poll_stats)
        |> Map.put(:mode, :full_scan_plus_hot)

      {%{} = full_scan_stats, _} ->
        full_scan_stats

      {_, %{} = hot_poll_stats} ->
        hot_poll_stats

      _ ->
        nil
    end
  end

  defp summarize_tracker_fetch_stats(_stats_by_mode), do: nil

  defp merge_tracker_fetch_stats(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      cond do
        is_integer(left_value) and is_integer(right_value) -> left_value + right_value
        true -> right_value
      end
    end)
  end

  defp apply_candidate_dispatch(%State{} = state, :ok, {:ok, issues}) when is_list(issues) do
    if available_slots(state) > 0 do
      choose_issues(issues, state)
    else
      state
    end
  end

  defp apply_candidate_dispatch(%State{} = state, :ok, :skipped), do: state

  defp apply_candidate_dispatch(%State{} = state, {:error, :missing_feishu_tasklist_guid}, _candidate_result) do
    Logger.error("Feishu tasklist guid missing in MARCH.yml")
    state
  end

  defp apply_candidate_dispatch(%State{} = state, {:error, :missing_tracker_kind}, _candidate_result) do
    Logger.error("Tracker kind missing in MARCH.yml")
    state
  end

  defp apply_candidate_dispatch(
         %State{} = state,
         {:error, {:unsupported_tracker_kind, kind}},
         _candidate_result
       ) do
    Logger.error("Unsupported tracker kind in MARCH.yml: #{inspect(kind)}")
    state
  end

  defp apply_candidate_dispatch(%State{} = state, {:error, :missing_codex_command}, _candidate_result) do
    Logger.error("Codex command missing in MARCH.yml")
    state
  end

  defp apply_candidate_dispatch(
         %State{} = state,
         {:error, {:invalid_codex_approval_policy, value}},
         _candidate_result
       ) do
    Logger.error("Invalid codex.approval_policy in MARCH.yml: #{inspect(value)}")
    state
  end

  defp apply_candidate_dispatch(
         %State{} = state,
         {:error, {:invalid_codex_thread_sandbox, value}},
         _candidate_result
       ) do
    Logger.error("Invalid codex.thread_sandbox in MARCH.yml: #{inspect(value)}")
    state
  end

  defp apply_candidate_dispatch(
         %State{} = state,
         {:error, {:invalid_codex_turn_sandbox_policy, reason}},
         _candidate_result
       ) do
    Logger.error("Invalid codex.turn_sandbox_policy in MARCH.yml: #{inspect(reason)}")
    state
  end

  defp apply_candidate_dispatch(
         %State{} = state,
         {:error, {:missing_config_file, path, reason}},
         _candidate_result
       ) do
    Logger.error("Missing MARCH.yml at #{path}: #{inspect(reason)}")
    state
  end

  defp apply_candidate_dispatch(
         %State{} = state,
         {:error, {:missing_workflow_file, path, reason}},
         _candidate_result
       ) do
    Logger.error("Missing BUILDER.md at #{path}: #{inspect(reason)}")
    state
  end

  defp apply_candidate_dispatch(
         %State{} = state,
         {:error, {:missing_planner_file, path, reason}},
         _candidate_result
       ) do
    Logger.error("Missing PLANNER.md at #{path}: #{inspect(reason)}")
    state
  end

  defp apply_candidate_dispatch(
         %State{} = state,
         {:error, {:missing_auditor_file, path, reason}},
         _candidate_result
       ) do
    Logger.error("Missing AUDITOR.md at #{path}: #{inspect(reason)}")
    state
  end

  defp apply_candidate_dispatch(%State{} = state, {:error, :workflow_config_not_a_map}, _candidate_result) do
    Logger.error("Failed to parse MARCH.yml: top-level YAML must decode to a map")
    state
  end

  defp apply_candidate_dispatch(
         %State{} = state,
         {:error, {:workflow_config_parse_error, reason}},
         _candidate_result
       ) do
    Logger.error("Failed to parse MARCH.yml: #{inspect(reason)}")
    state
  end

  defp apply_candidate_dispatch(%State{} = state, :ok, {:error, reason}) do
    Logger.error("Failed to fetch from tracker: #{inspect(reason)}")
    state
  end

  defp apply_candidate_dispatch(%State{} = state, {:error, reason}, _candidate_result) do
    Logger.error("Failed to fetch from tracker: #{inspect(reason)}")
    state
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, automation_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, automation_state_set(), terminal_state_set())
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, automation_state_set(), terminal_state_set())
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec run_poll_snapshot_for_test(term(), module(), (-> term())) ::
          {:ok, map()} | {:error, term()}
  def run_poll_snapshot_for_test(%State{} = state, tracker, validator \\ fn -> :ok end)
      when is_atom(tracker) and is_function(validator, 0) do
    run_poll_snapshot(state, tracker, validator)
  end

  @doc false
  @spec finish_poll_cycle_for_test(term(), map()) :: term()
  def finish_poll_cycle_for_test(%State{} = state, snapshot) when is_map(snapshot) do
    finish_poll_cycle(state, snapshot)
  end

  @doc false
  @spec run_startup_workspace_cleanup_for_test(module(), (-> term())) :: :ok
  def run_startup_workspace_cleanup_for_test(tracker, validator \\ fn -> :ok end)
      when is_atom(tracker) and is_function(validator, 0) do
    run_startup_workspace_cleanup(tracker, validator)
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    running_role = state.running |> Map.get(issue.id, %{}) |> Map.get(:role)
    desired_role = issue_role(issue)

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        PlannerSessions.release(issue.id)
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true)

      !issue_routable_to_worker?(issue) ->
        PlannerSessions.release(issue.id)
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      not is_nil(running_role) and not is_nil(desired_role) and running_role != desired_role ->
        Logger.info("Issue changed automation lane: #{issue_context(issue)} state=#{issue.state} from=#{running_role} to=#{desired_role}; restarting in the new lane")

        terminate_running_issue(state, issue.id, false)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        PlannerSessions.release(issue.id)
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)

        if cleanup_workspace do
          cleanup_issue_workspace(identifier)
        end

        if is_pid(pid) do
          terminate_task(pid)
        end

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.codex_stall_timeout_ms()

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

      next_attempt = next_retry_attempt_from_running(running_entry)

      state
      |> terminate_running_issue(issue_id, false)
      |> schedule_issue_retry(issue_id, next_attempt, %{
        identifier: identifier,
        delay_type: :stall,
        error: "stalled for #{elapsed_ms}ms without codex activity"
      })
    else
      state
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(March.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp choose_issues(issues, state) do
    active_states = automation_state_set()
    terminal_states = terminal_state_set()
    log_non_routable_issues(issues)

    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      if should_dispatch_issue?(issue, state_acc, active_states, terminal_states) do
        dispatch_issue(state_acc, issue)
      else
        state_acc
      end
    end)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed} = state,
         active_states,
         terminal_states
       ) do
    candidate_issue?(issue, active_states, terminal_states) and
      dispatchable_issue?(issue) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable_to_worker?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp dispatchable_issue?(%Issue{} = issue) do
    case issue_role(issue) do
      :planner ->
        planner_dispatch_required?(issue)

      :auditor ->
        auditor_dispatch_required?(issue)

      :builder ->
        true

      _ ->
        false
    end
  end

  defp dispatchable_issue?(_issue), do: false

  defp issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
       when is_boolean(assigned_to_worker),
       do: assigned_to_worker

  defp issue_routable_to_worker?(_issue), do: true

  defp log_routing_config do
    Logger.info(
      "Routing config loaded: tracker_kind=#{inspect(Config.tracker_kind())} " <>
        "tasklist_guid=#{inspect(Config.feishu_tasklist_guid())} " <>
        "identity=#{inspect(Config.feishu_identity())} " <>
        "builder_states=#{inspect(Config.builder_states())} " <>
        "planner_states=#{inspect(Config.planner_states())} " <>
        "auditor_states=#{inspect(Config.auditor_states())}"
    )
  end

  defp log_non_routable_issues(issues) when is_list(issues) do
    skipped_identifiers =
      issues
      |> Enum.filter(fn
        %Issue{} = issue -> not issue_routable_to_worker?(issue)
        _ -> false
      end)
      |> Enum.map(&(&1.identifier || &1.id))
      |> Enum.reject(&is_nil/1)

    if skipped_identifiers != [] do
      Logger.info(
        "Skipping non-routable issues for this worker count=#{length(skipped_identifiers)} " <>
          "sample=#{inspect(Enum.take(skipped_identifiers, 5))}"
      )
    end
  end

  defp log_non_routable_issues(_issues), do: :ok

  defp todo_issue_blocked_by_non_terminal?(
         %Issue{state: issue_state, blocked_by: blockers},
         terminal_states
       )
       when is_binary(issue_state) and is_list(blockers) do
    normalize_issue_state(issue_state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  defp todo_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set do
    Config.terminal_states()
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp automation_state_set do
    Config.automation_states()
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(%State{} = state, issue, attempt \\ nil) do
    if issue_fresh_for_dispatch?(issue) do
      do_dispatch_issue(state, issue, attempt)
    else
      case revalidate_issue_for_dispatch(issue, &Tracker.fetch_issue_states_by_ids/1, terminal_state_set()) do
        {:ok, %Issue{} = refreshed_issue} ->
          do_dispatch_issue(state, refreshed_issue, attempt)

        {:skip, :missing} ->
          Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
          state

        {:skip, %Issue{} = refreshed_issue} ->
          Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

          state

        {:error, reason} ->
          Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
          state
      end
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt) do
    recipient = self()
    role = issue_role(issue) || :builder

    with {:ok, issue, runner_opts} <- prepare_issue_for_dispatch(issue, role, attempt) do
      runner =
        case role do
          :planner -> fn -> PlannerRunner.run(issue, recipient, runner_opts) end
          :auditor -> fn -> AuditorRunner.run(issue, recipient, runner_opts) end
          _ -> fn -> BuilderRunner.run(issue, recipient, runner_opts) end
        end

      case Task.Supervisor.start_child(March.TaskSupervisor, runner) do
        {:ok, pid} ->
          ref = Process.monitor(pid)
          run_mode = dispatch_mode_for_issue(role, issue, runner_opts)

          Logger.info("Dispatching issue to #{role} lane: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)}")

          running =
            Map.put(state.running, issue.id, %{
              pid: pid,
              ref: ref,
              identifier: issue.identifier,
              role: role,
              mode: run_mode,
              issue: issue,
              session_id: nil,
              last_codex_message: nil,
              last_codex_timestamp: nil,
              last_codex_event: nil,
              codex_app_server_pid: nil,
              codex_input_tokens: 0,
              codex_output_tokens: 0,
              codex_total_tokens: 0,
              codex_last_reported_input_tokens: 0,
              codex_last_reported_output_tokens: 0,
              codex_last_reported_total_tokens: 0,
              turn_count: 0,
              retry_attempt: normalize_retry_attempt(attempt),
              started_at: DateTime.utc_now()
            })

          %{
            state
            | running: running,
              claimed: MapSet.put(state.claimed, issue.id),
              retry_attempts: Map.delete(state.retry_attempts, issue.id)
          }

        {:error, reason} ->
          Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
          next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

          schedule_issue_retry(state, issue.id, next_attempt, %{
            identifier: issue.identifier,
            error: "failed to spawn agent: #{inspect(reason)}"
          })
      end
    else
      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue preparation failed for #{issue_context(issue)}: #{inspect(reason)}")

        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          error: "failed to prepare issue for dispatch: #{inspect(reason)}"
        })
    end
  end

  defp prepare_issue_for_dispatch(%Issue{} = issue, :builder, attempt) do
    runner_opts = [attempt: attempt]

    case normalize_issue_state(issue.state) do
      "building" ->
        mode = TaskState.builder_mode(issue)

        with {:ok, prepared_issue} <- maybe_sync_building_hook(issue, :builder, builder_phase_for_mode(mode)) do
          {:ok, prepared_issue, Keyword.put(runner_opts, :mode, mode)}
        end

      _ ->
        {:ok, issue, runner_opts}
    end
  end

  defp prepare_issue_for_dispatch(%Issue{} = issue, :planner, attempt) do
    prepared_result =
      case {normalize_issue_state(issue.state), TaskState.planner_mode(issue)} do
        {"building", "review"} ->
          maybe_sync_building_hook(issue, :planner, "review")

        _ ->
          {:ok, issue}
      end

    with {:ok, prepared_issue} <- prepared_result do
      {:ok, prepared_issue, [attempt: attempt, mode: TaskState.planner_mode(prepared_issue)]}
    end
  end

  defp prepare_issue_for_dispatch(%Issue{} = issue, _role, attempt) do
    {:ok, issue, [attempt: attempt]}
  end

  defp dispatch_mode_for_issue(:builder, %Issue{} = issue, runner_opts) do
    Keyword.get(runner_opts, :mode, TaskState.builder_mode(issue))
  end

  defp dispatch_mode_for_issue(:planner, %Issue{} = issue, runner_opts) do
    Keyword.get(runner_opts, :mode, TaskState.planner_mode(issue))
  end

  defp dispatch_mode_for_issue(_role, _issue, _runner_opts), do: nil

  defp maybe_sync_building_hook(%Issue{} = issue, role, phase) when is_binary(phase) do
    desired_extra =
      case role do
        :planner -> TaskState.set_building_hook(issue, "planner_review", phase)
        _ -> TaskState.set_building_hook(issue, "builder", phase)
      end

    if TaskState.parse(issue.extra) == TaskState.parse(desired_extra) do
      {:ok, issue}
    else
      with :ok <- Tracker.update_issue_extra(issue.id, desired_extra) do
        {:ok, %{issue | extra: desired_extra}}
      end
    end
  end

  defp builder_phase_for_mode("pickup"), do: "pickup"
  defp builder_phase_for_mode("rework"), do: "rework"
  defp builder_phase_for_mode("merge"), do: "merge"
  defp builder_phase_for_mode(_mode), do: "execute"

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp issue_fresh_for_dispatch?(%Issue{fetched_at: %DateTime{} = fetched_at}) do
    DateTime.diff(DateTime.utc_now(), fetched_at, :millisecond) <= @dispatch_revalidate_grace_ms
  end

  defp issue_fresh_for_dispatch?(_issue), do: false

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            due_at_ms: due_at_ms,
            identifier: identifier,
            error: error
          })
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_issue_states_by_ids([issue_id]) do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry refresh failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry refresh failed: #{inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue.identifier)
        {:noreply, release_issue_claim(state, issue_id)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier)
  end

  defp cleanup_issue_workspace(_identifier), do: :ok

  defp schedule_startup_workspace_cleanup do
    send(self(), :run_startup_workspace_cleanup)
    :ok
  end

  defp run_startup_workspace_cleanup do
    run_startup_workspace_cleanup(Tracker, fn -> Config.validate!() end)
  end

  defp run_startup_workspace_cleanup(tracker, validator)
       when is_atom(tracker) and is_function(validator, 0) do
    Logger.info("Starting asynchronous startup workspace cleanup")

    case validator.() do
      :ok ->
        case tracker.fetch_candidate_issues() do
          {:ok, issues} ->
            active_identifiers =
              issues
              |> Enum.map(fn
                %Issue{identifier: identifier} when is_binary(identifier) -> identifier
                _issue -> nil
              end)
              |> Enum.reject(&is_nil/1)

            Workspace.remove_stale_issue_workspaces(active_identifiers)

          {:error, reason} ->
            Logger.warning("Skipping startup workspace cleanup; failed to fetch visible tasks: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.debug("Skipping startup workspace cleanup; tracker not ready: #{inspect(reason)}")
    end

    Logger.info("Finished asynchronous startup workspace cleanup")
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    if retry_candidate_issue?(issue, terminal_state_set()) and
         dispatch_slots_available?(issue, state) do
      {:noreply, dispatch_issue(state, issue, attempt)}
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt + 1,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           error: "no available orchestrator slots"
         })
       )}
    end
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{state | claimed: MapSet.delete(state.claimed, issue_id)}
  end

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    cond do
      metadata[:delay_type] == :continuation and attempt == 1 ->
        @continuation_retry_delay_ms

      metadata[:delay_type] == :stall ->
        failure_retry_delay(attempt) + @stall_retry_grace_ms

      true ->
        failure_retry_delay(attempt)
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.max_retry_backoff_ms())
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.max_concurrent_agents()) - map_size(state.running),
      0
    )
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          role: Map.get(metadata, :role, issue_role(metadata.issue) || :builder),
          state: metadata.issue.state,
          session_id: metadata.session_id,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          error: Map.get(retry, :error)
        }
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       codex_totals: state.codex_totals,
       rate_limits: Map.get(state, :codex_rate_limits),
       repo_sync: state.last_repo_sync_status,
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms,
         full_scan_interval_ms: full_scan_interval_for_mode(state, state.full_scan_mode),
         full_scan_mode: state.full_scan_mode,
         consecutive_empty_full_scans: state.consecutive_empty_full_scans,
         next_full_scan_in_ms: next_poll_in_ms(state.next_full_scan_due_at_ms, now_ms),
         last_completed_at: state.last_poll_completed_at,
         last_successful_at: state.last_successful_poll_at,
         last_full_scan_at: state.last_full_scan_at,
         last_duration_ms: state.last_poll_duration_ms,
         last_status: state.last_poll_status,
         last_stats: state.last_poll_stats,
         hot_issue_count: MapSet.size(state.hot_issue_ids)
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?

    unless coalesced do
      :ok = schedule_tick(0)
    end

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        last_codex_event: event,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update)
      }),
      token_delta
    }
  end

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp schedule_tick(delay_ms) do
    :timer.send_after(delay_ms, self(), :tick)
    :ok
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    %{
      state
      | poll_interval_ms: Config.poll_interval_ms(),
        full_scan_interval_ms: Config.full_scan_interval_ms(),
        idle_full_scan_interval_ms: Config.idle_full_scan_interval_ms(),
        idle_after_empty_full_scans: Config.idle_after_empty_full_scans(),
        max_concurrent_agents: Config.max_concurrent_agents()
    }
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, automation_state_set(), terminal_states) and
      dispatchable_issue?(issue) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  defp planner_dispatch_required?(%Issue{id: issue_id, state: state_name} = issue)
       when is_binary(issue_id) and is_binary(state_name) do
    TaskState.planner_pending?(issue)
  end

  defp planner_dispatch_required?(_issue), do: false

  defp auditor_dispatch_required?(%Issue{} = issue) do
    TaskState.auditor_pending?(issue)
  end

  defp auditor_dispatch_required?(_issue), do: false

  defp handle_successful_run(state, issue_id, running_entry, session_id) do
    role = Map.get(running_entry, :role, :builder)

    case role do
      :builder ->
        state = maybe_sync_canonical_repo_after_merge(state, running_entry)

        Logger.info("Builder task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

        state
        |> complete_issue(issue_id)
        |> schedule_issue_retry(issue_id, 1, %{
          identifier: running_entry.identifier,
          delay_type: :continuation
        })

      :planner ->
        maybe_record_role_progress(running_entry, :planner)

        Logger.info("planner lane completed for issue_id=#{issue_id} session_id=#{session_id}; waiting for new tracker input")

        state
        |> complete_issue(issue_id)
        |> release_issue_claim(issue_id)

      :auditor ->
        maybe_record_role_progress(running_entry, :auditor)

        Logger.info("auditor lane completed for issue_id=#{issue_id} session_id=#{session_id}; waiting for new tracker input")

        state
        |> complete_issue(issue_id)
        |> release_issue_claim(issue_id)
    end
  end

  defp maybe_record_role_progress(%{issue: %Issue{id: issue_id}} = running_entry, role)
       when is_binary(issue_id) and role in [:planner, :auditor] do
    with {:ok, %Issue{} = progress_issue} <- role_progress_issue(running_entry, role, &Tracker.fetch_issue_states_by_ids/1),
         extra <- TaskState.mark_role_processed(progress_issue, role),
         :ok <- Tracker.update_issue_extra(issue_id, extra) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Failed to record #{role} progress for #{issue_context(Map.get(running_entry, :issue))}: #{inspect(reason)}")

        :ok

      other ->
        Logger.warning("Failed to record #{role} progress for #{issue_context(Map.get(running_entry, :issue))}: #{inspect(other)}")

        :ok
    end
  end

  defp maybe_record_role_progress(_running_entry, _role), do: :ok

  defp role_progress_issue(%{issue: %Issue{} = issue}, :planner, fetcher)
       when is_function(fetcher, 1) do
    if normalize_issue_state(issue.state) == "planning" do
      {:ok, issue}
    else
      fetch_role_progress_issue(issue.id, fetcher)
    end
  end

  defp role_progress_issue(%{issue: %Issue{id: issue_id}}, role, fetcher)
       when is_binary(issue_id) and role in [:planner, :auditor] and is_function(fetcher, 1) do
    fetch_role_progress_issue(issue_id, fetcher)
  end

  defp role_progress_issue(_running_entry, _role, _fetcher), do: {:error, :missing_issue}

  defp fetch_role_progress_issue(issue_id, fetcher)
       when is_binary(issue_id) and is_function(fetcher, 1) do
    case fetcher.([issue_id]) do
      {:ok, [%Issue{} = issue | _]} -> {:ok, issue}
      {:ok, []} -> {:error, :issue_missing}
      other -> other
    end
  end

  @doc false
  def role_progress_issue_for_test(running_entry, role, fetcher) when is_function(fetcher, 1) do
    role_progress_issue(running_entry, role, fetcher)
  end

  defp maybe_sync_canonical_repo_after_merge(
         %State{} = state,
         %{issue: %Issue{identifier: identifier}} = running_entry
       ) do
    if merge_sync_run?(running_entry) do
      repo_root = Workflow.repo_root()
      canonical_branch = Config.canonical_branch()
      checking_status = repo_sync_status(:merge, :checking, repo_root, nil)
      Application.put_env(:march, :last_repo_sync_status, checking_status)
      notify_dashboard()

      case CanonicalRepo.ensure_ready(repo_root, branch: canonical_branch) do
        {:ok, :up_to_date} ->
          Logger.info("Canonical planner repo already up to date on #{canonical_branch} after merge for #{identifier}")
          set_repo_sync_status(state, repo_sync_status(:merge, :up_to_date, repo_root, nil))

        {:ok, :pulled} ->
          Logger.info("Canonical planner repo fast-forwarded to #{canonical_branch} after merge for #{identifier}")
          set_repo_sync_status(state, repo_sync_status(:merge, :pulled, repo_root, nil))

        {:error, reason} ->
          Logger.warning("Failed to sync canonical planner repo after merge for #{identifier}: #{reason}")
          set_repo_sync_status(state, repo_sync_status(:merge, :error, repo_root, reason))
      end
    else
      state
    end
  end

  defp maybe_sync_canonical_repo_after_merge(%State{} = state, _running_entry), do: state

  @doc false
  @spec merge_sync_run?(map()) :: boolean()
  def merge_sync_run?(%{role: :builder, mode: "merge"}), do: true

  def merge_sync_run?(%{role: :builder, issue: %Issue{state: state_name}})
      when is_binary(state_name) do
    normalize_issue_state(state_name) == "merging"
  end

  def merge_sync_run?(_running_entry), do: false

  defp set_repo_sync_status(%State{} = state, status) when is_map(status) do
    Application.put_env(:march, :last_repo_sync_status, status)
    notify_dashboard()
    %{state | last_repo_sync_status: status}
  end

  defp repo_sync_status(phase, status, repo_root, detail) do
    %{
      phase: phase,
      status: status,
      repo_root: repo_root,
      detail: detail,
      at: DateTime.utc_now()
    }
  end

  defp issue_role(%Issue{} = issue) do
    TaskState.role_for_issue(issue) || Config.issue_role(issue.state)
  end

  defp issue_role(_issue), do: nil

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
