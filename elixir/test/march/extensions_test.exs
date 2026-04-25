defmodule March.ExtensionsTest do
  use March.TestSupport

  alias March.Config
  alias March.Feishu.TaskAdapter
  alias March.Tracker.Memory

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Second prompt")
    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    File.write!(Workflow.config_file_path(), "- broken\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "THIRD_WORKFLOW.md")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = Supervisor.terminate_child(March.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, _pid} = Supervisor.restart_child(March.Supervisor, WorkflowStore)
  end

  test "workflow store init stops on missing config file" do
    missing_root = Path.join(System.tmp_dir!(), "missing-config-#{System.unique_integer([:positive])}")
    File.mkdir_p!(missing_root)
    Workflow.set_repo_root(missing_root)

    missing_path = Path.join(missing_root, "MARCH.yml")
    assert {:stop, {:missing_config_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "MANUAL_WORKFLOW.md")
    config_path = Workflow.config_file_path()
    missing_config_path = Path.join(Path.dirname(existing_path), "MANUAL_MISSING_MARCH.yml")

    assert :ok = Supervisor.terminate_child(March.Supervisor, WorkflowStore)

    Application.put_env(:march, :config_file_path, missing_config_path)

    assert {:error, {:missing_config_file, ^missing_config_path, :enoent}} =
             WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)
    Application.delete_env(:march, :config_file_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    state = :sys.get_state(manual_pid)
    File.write!(config_path, "- broken\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil
    assert_receive :poll, 1_100

    Application.put_env(:march, :config_file_path, missing_config_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Application.delete_env(:march, :config_file_path)
    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Process.exit(manual_pid, :normal)
    restart_result = Supervisor.restart_child(March.Supervisor, WorkflowStore)

    assert match?({:ok, _pid}, restart_result) or
             match?({:error, {:already_started, _pid}}, restart_result)

    Workflow.set_workflow_file_path(existing_path)
    Application.delete_env(:march, :config_file_path)
    WorkflowStore.force_reload()
  end

  test "tracker delegates to memory and feishu task adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    Application.put_env(:march, :memory_tracker_issues, [issue, %{id: "ignored"}])
    Application.put_env(:march, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.tracker_kind() == "memory"
    assert March.Tracker.adapter() == Memory
    assert {:ok, [^issue]} = March.Tracker.fetch_candidate_issues()
    assert {:ok, [^issue]} = March.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^issue]} = March.Tracker.fetch_issue_states_by_ids(["issue-1"])
    assert :ok = March.Tracker.create_comment("issue-1", "comment")
    assert :ok = March.Tracker.update_issue_state("issue-1", "Done")
    assert_receive {:memory_tracker_comment, "issue-1", "comment"}
    assert_receive {:memory_tracker_state_update, "issue-1", "Done"}

    Application.delete_env(:march, :memory_tracker_recipient)
    assert :ok = Memory.create_comment("issue-1", "quiet")
    assert :ok = Memory.update_issue_state("issue-1", "Quiet")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "feishu_task",
      tracker_tasklist_guid: "tasklist-guid"
    )

    assert March.Tracker.adapter() == TaskAdapter
  end

  test "polling config accepts explicit hot/full scan intervals and idle scan backoff" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_comments_cache_ttl_ms: 45_000,
      tracker_task_fetch_max_concurrency: 4,
      hot_poll_interval_ms: 15_000,
      full_scan_interval_ms: 60_000,
      idle_full_scan_interval_ms: 180_000,
      idle_after_empty_full_scans: 2
    )

    assert Config.poll_interval_ms() == 15_000
    assert Config.hot_poll_interval_ms() == 15_000
    assert Config.full_scan_interval_ms() == 60_000
    assert Config.idle_full_scan_interval_ms() == 180_000
    assert Config.idle_after_empty_full_scans() == 2
    assert Config.feishu_comments_cache_ttl_ms() == 45_000
    assert Config.feishu_task_fetch_max_concurrency() == 4

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_comments_cache_ttl_ms: 90_000,
      tracker_task_fetch_max_concurrency: 2,
      hot_poll_interval_ms: 30_000,
      full_scan_interval_ms: 90_000,
      idle_full_scan_interval_ms: 420_000,
      idle_after_empty_full_scans: 4
    )

    assert Config.poll_interval_ms() == 30_000
    assert Config.hot_poll_interval_ms() == 30_000
    assert Config.full_scan_interval_ms() == 90_000
    assert Config.idle_full_scan_interval_ms() == 420_000
    assert Config.idle_after_empty_full_scans() == 4
    assert Config.feishu_comments_cache_ttl_ms() == 90_000
    assert Config.feishu_task_fetch_max_concurrency() == 2
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp ensure_workflow_store_running do
    if Process.whereis(WorkflowStore) do
      :ok
    else
      case Supervisor.restart_child(March.Supervisor, WorkflowStore) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end
end
