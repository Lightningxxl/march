defmodule March.RepoSyncRuntimeTest do
  use March.TestSupport

  test "dashboard render snapshots preserve repo sync state" do
    repo_sync = %{
      phase: :startup,
      status: :pulled,
      repo_root: Workflow.repo_root(),
      at: DateTime.add(DateTime.utc_now(), -30, :second)
    }

    snapshot =
      StatusDashboard.snapshot_for_render_for_test(%{
        running: [],
        retrying: [],
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        rate_limits: nil,
        polling: %{checking?: false, next_poll_in_ms: 5_000},
        repo_sync: repo_sync
      })

    content = StatusDashboard.format_snapshot_content_for_test({:ok, snapshot}, 0.0)

    assert snapshot.repo_sync == repo_sync
    assert content =~ "Last repo sync:"
    assert content =~ "startup"
    assert content =~ "pulled latest"
  end

  test "merge completion keeps repo sync enabled for merge runs even after the task reached done" do
    assert Orchestrator.merge_sync_run?(%{
             role: :builder,
             mode: "merge",
             issue: %Issue{state: "Done", identifier: "HAC-123"}
           })
  end

  test "merge completion still recognizes explicit merging state without stored mode" do
    assert Orchestrator.merge_sync_run?(%{
             role: :builder,
             issue: %Issue{state: "Merging", identifier: "HAC-124"}
           })

    refute Orchestrator.merge_sync_run?(%{
             role: :builder,
             mode: "execute",
             issue: %Issue{state: "Building", identifier: "HAC-125"}
           })
  end
end
