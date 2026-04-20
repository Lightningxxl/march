defmodule March.OrchestratorRuntimeTest do
  use March.TestSupport

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
end
