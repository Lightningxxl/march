defmodule March.OrchestratorRuntimeTest do
  use March.TestSupport

  defmodule FakeTracker do
    @table __MODULE__

    def reset(fixtures) when is_map(fixtures) do
      ensure_table!()
      :ets.delete_all_objects(@table)
      true = :ets.insert(@table, {:fixtures, fixtures})
      :ok
    end

    def calls(operation) when is_atom(operation) do
      ensure_table!()

      @table
      |> :ets.lookup({:calls, operation})
      |> Enum.map(fn {{:calls, ^operation}, payload} -> payload end)
    end

    def fetch_candidate_issues do
      record(:fetch_candidate_issues, :called)
      {:ok, Map.get(fixtures(), :candidate_issues, [])}
    end

    def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
      record(:fetch_issue_states_by_ids, issue_ids)

      issues =
        case Map.get(fixtures(), :issues_by_id) do
          fun when is_function(fun, 1) ->
            fun.(issue_ids)

          %{} = issues_by_id ->
            Enum.flat_map(issue_ids, fn issue_id ->
              case Map.get(issues_by_id, issue_id) do
                nil -> []
                issue -> [issue]
              end
            end)

          _ ->
            []
        end

      {:ok, issues}
    end

    defp fixtures do
      ensure_table!()

      case :ets.lookup(@table, :fixtures) do
        [{:fixtures, fixtures}] -> fixtures
        _ -> %{}
      end
    end

    defp record(operation, payload) do
      ensure_table!()
      true = :ets.insert(@table, {{:calls, operation}, payload})
      :ok
    end

    defp ensure_table! do
      case :ets.whereis(@table) do
        :undefined ->
          try do
            :ets.new(@table, [:named_table, :public, :duplicate_bag])
          rescue
            ArgumentError -> @table
          end

        _table ->
          @table
      end
    end
  end

  test "planning lane progress uses the dispatch snapshot instead of refetching" do
    issue = %Issue{
      id: "issue-1",
      identifier: "claworld/t100242",
      state: "Planning",
      description: "desc",
      comments: [
        %{id: "human-1", content: "Please simplify the contract.", created_at: "1", updated_at: "1"}
      ],
      current_plan: "Current Plan",
      extra: "{}"
    }

    fetcher = fn _issue_ids ->
      send(self(), :fetch_called)
      {:ok, [%{issue | current_plan: "Updated"}]}
    end

    assert {:ok, ^issue} =
             Orchestrator.role_progress_issue_for_test(%{issue: issue}, :planner, fetcher)

    refute_received :fetch_called
  end

  test "planner review progress still refreshes from the tracker" do
    issue = %Issue{
      id: "issue-2",
      identifier: "claworld/t100243",
      state: "Building",
      description: "desc",
      comments: [],
      current_plan: "Current Plan",
      builder_workpad: "workpad",
      extra: ~s({"workflow":{"active_role":"planner_review","building_phase":"review"}})
    }

    refreshed_issue = %{issue | current_plan: "Updated Plan"}

    fetcher = fn ["issue-2"] ->
      send(self(), :fetch_called)
      {:ok, [refreshed_issue]}
    end

    assert {:ok, ^refreshed_issue} =
             Orchestrator.role_progress_issue_for_test(%{issue: issue}, :planner, fetcher)

    assert_received :fetch_called
  end

  test "polling seeds hot issues from a full scan and later prunes terminal transitions with hot refreshes" do
    planning_issue = fake_issue("issue-1", "Planning")
    human_review_issue = fake_issue("issue-2", "Human Review")
    done_issue = %{planning_issue | state: "Done"}

    FakeTracker.reset(%{
      candidate_issues: [planning_issue, human_review_issue],
      issues_by_id: %{"issue-1" => done_issue}
    })

    state = base_orchestrator_state()

    assert {:ok, snapshot} = Orchestrator.run_poll_snapshot_for_test(state, FakeTracker)
    assert FakeTracker.calls(:fetch_candidate_issues) == [:called]
    assert FakeTracker.calls(:fetch_issue_states_by_ids) == []

    state = Orchestrator.finish_poll_cycle_for_test(state, snapshot)
    assert state.hot_issue_ids == MapSet.new(["issue-1"])

    assert {:ok, snapshot} = Orchestrator.run_poll_snapshot_for_test(state, FakeTracker)
    assert FakeTracker.calls(:fetch_issue_states_by_ids) == [["issue-1"]]

    state = Orchestrator.finish_poll_cycle_for_test(state, snapshot)
    assert state.hot_issue_ids == MapSet.new()
  end

  test "hot polling preserves previously tracked issues when a targeted refresh returns no result" do
    state =
      base_orchestrator_state(
        hot_issue_ids: MapSet.new(["issue-1"]),
        next_full_scan_due_at_ms: System.monotonic_time(:millisecond) + 60_000
      )

    FakeTracker.reset(%{candidate_issues: [], issues_by_id: %{}})

    assert {:ok, snapshot} = Orchestrator.run_poll_snapshot_for_test(state, FakeTracker)
    assert FakeTracker.calls(:fetch_candidate_issues) == []
    assert FakeTracker.calls(:fetch_issue_states_by_ids) == [["issue-1"]]

    state = Orchestrator.finish_poll_cycle_for_test(state, snapshot)
    assert state.hot_issue_ids == MapSet.new(["issue-1"])
  end

  test "authoritative full scans evict hot issue ids that are no longer visible" do
    FakeTracker.reset(%{candidate_issues: [], issues_by_id: %{}})

    state = base_orchestrator_state(hot_issue_ids: MapSet.new(["ghost-1"]))

    assert {:ok, snapshot} = Orchestrator.run_poll_snapshot_for_test(state, FakeTracker)
    assert FakeTracker.calls(:fetch_candidate_issues) == [:called]
    assert FakeTracker.calls(:fetch_issue_states_by_ids) == [["ghost-1"]]

    state = Orchestrator.finish_poll_cycle_for_test(state, snapshot)
    assert state.hot_issue_ids == MapSet.new()
  end

  test "three empty full scans transition the orchestrator into idle full scan mode" do
    FakeTracker.reset(%{candidate_issues: [], issues_by_id: %{}})

    state =
      1..3
      |> Enum.reduce(base_orchestrator_state(), fn _iteration, state_acc ->
        state_acc = %{state_acc | next_full_scan_due_at_ms: System.monotonic_time(:millisecond) - 1}
        assert {:ok, snapshot} = Orchestrator.run_poll_snapshot_for_test(state_acc, FakeTracker)
        Orchestrator.finish_poll_cycle_for_test(state_acc, snapshot)
      end)

    assert state.full_scan_mode == :idle
    assert state.consecutive_empty_full_scans == 3
    assert_due_in_range(state.next_full_scan_due_at_ms, 280_000, 320_000)
  end

  test "a newly discovered hot issue wakes idle full scan mode back to active cadence" do
    planning_issue = fake_issue("issue-1", "Planning")

    FakeTracker.reset(%{
      candidate_issues: [planning_issue],
      issues_by_id: %{}
    })

    state =
      base_orchestrator_state(
        full_scan_mode: :idle,
        consecutive_empty_full_scans: 3,
        next_full_scan_due_at_ms: System.monotonic_time(:millisecond) - 1
      )

    assert {:ok, snapshot} = Orchestrator.run_poll_snapshot_for_test(state, FakeTracker)
    state = Orchestrator.finish_poll_cycle_for_test(state, snapshot)

    assert state.full_scan_mode == :active
    assert state.consecutive_empty_full_scans == 0
    assert state.hot_issue_ids == MapSet.new(["issue-1"])
    assert_due_in_range(state.next_full_scan_due_at_ms, 40_000, 90_000)
  end

  test "startup workspace cleanup removes workspaces for tasks that are no longer open" do
    workspace_root =
      Path.join(System.tmp_dir!(), "march-startup-cleanup-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(workspace_root) end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    active_workspace = Path.join(workspace_root, "claworld_issue-1")
    stale_workspace = Path.join(workspace_root, "claworld_issue-2")
    file_marker = Path.join(workspace_root, "README.txt")

    File.mkdir_p!(active_workspace)
    File.mkdir_p!(stale_workspace)
    File.write!(file_marker, "keep me")

    FakeTracker.reset(%{
      candidate_issues: [fake_issue("issue-1", "Planning")],
      issues_by_id: %{}
    })

    assert :ok = Orchestrator.run_startup_workspace_cleanup_for_test(FakeTracker)
    assert File.dir?(active_workspace)
    refute File.exists?(stale_workspace)
    assert File.read!(file_marker) == "keep me"
  end

  defp base_orchestrator_state(overrides \\ []) do
    now_ms = System.monotonic_time(:millisecond)

    struct!(
      March.Orchestrator.State,
      Keyword.merge(
        [
          poll_interval_ms: 30_000,
          full_scan_interval_ms: 60_000,
          idle_full_scan_interval_ms: 300_000,
          idle_after_empty_full_scans: 3,
          consecutive_empty_full_scans: 0,
          full_scan_mode: :active,
          max_concurrent_agents: 0,
          next_poll_due_at_ms: nil,
          next_full_scan_due_at_ms: now_ms - 1,
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
          last_repo_sync_status: nil,
          running: %{},
          hot_issue_ids: MapSet.new(),
          completed: MapSet.new(),
          claimed: MapSet.new(),
          retry_attempts: %{},
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          codex_rate_limits: nil
        ],
        overrides
      )
    )
  end

  defp fake_issue(issue_id, state_name) do
    %Issue{
      id: issue_id,
      identifier: "claworld/#{issue_id}",
      title: "Task #{issue_id}",
      state: state_name,
      description: "desc",
      fetched_at: DateTime.utc_now()
    }
  end

  defp assert_due_in_range(due_at_ms, min_delay_ms, max_delay_ms)
       when is_integer(due_at_ms) and is_integer(min_delay_ms) and is_integer(max_delay_ms) do
    delay_ms = due_at_ms - System.monotonic_time(:millisecond)
    assert delay_ms >= min_delay_ms
    assert delay_ms <= max_delay_ms
  end
end
