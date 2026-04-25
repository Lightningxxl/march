defmodule March.StatusDashboardTest do
  use ExUnit.Case, async: true

  alias March.StatusDashboard

  test "renders repo sync status in the dashboard snapshot" do
    content =
      StatusDashboard.format_snapshot_content_for_test(
        {:ok,
         %{
           running: [],
           retrying: [],
           codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
           rate_limits: nil,
           polling: %{checking?: false, next_poll_in_ms: 5_000},
           repo_sync: %{
             phase: :startup,
             status: :pulled,
             at: DateTime.add(DateTime.utc_now(), -120, :second)
           }
         }},
        0.0
      )

    assert content =~ "Last repo sync:"
    assert content =~ "startup"
    assert content =~ "pulled latest"
    assert content =~ "ago"
  end

  test "renders hot poll cadence and poll mode details" do
    content =
      StatusDashboard.format_snapshot_content_for_test(
        {:ok,
         %{
           running: [],
           retrying: [],
           codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
           rate_limits: nil,
           polling: %{
             checking?: false,
             next_poll_in_ms: 5_000,
             next_full_scan_in_ms: 60_000,
             hot_issue_count: 3,
             last_status: :ok,
             last_stats: %{mode: :full_scan_plus_hot, scanned: 6, comment_fetches: 2}
           },
           repo_sync: nil
         }},
        0.0
      )

    assert content =~ "Next refresh:"
    assert content =~ "full=60s"
    assert content =~ "hot=3"
    assert content =~ "mode=full+hot"
    assert content =~ "tasks=6"
  end

  test "renders idle full scan mode in the refresh line" do
    content =
      StatusDashboard.format_snapshot_content_for_test(
        {:ok,
         %{
           running: [],
           retrying: [],
           codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
           rate_limits: nil,
           polling: %{
             checking?: false,
             next_poll_in_ms: 5_000,
             next_full_scan_in_ms: 300_000,
             full_scan_mode: :idle,
             hot_issue_count: 0
           },
           repo_sync: nil
         }},
        0.0
      )

    assert content =~ "full=300s idle"
    assert content =~ "hot=0"
  end
end
