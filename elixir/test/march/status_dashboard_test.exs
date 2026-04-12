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
end
