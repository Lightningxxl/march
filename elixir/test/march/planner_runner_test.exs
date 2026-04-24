defmodule March.PlannerRunnerTest do
  use March.TestSupport

  alias March.PlannerRunner
  alias March.Tracker.Item, as: Issue

  test "syncs the canonical repo before starting the planner turn" do
    test_pid = self()

    issue = %Issue{
      id: "planner-runner-sync",
      identifier: "claworld/t100001",
      title: "Keep planner repo fresh",
      state: "Planning",
      url: "https://example.test/tasks/planner-runner-sync",
      comments: []
    }

    repo_sync = fn repo_root, opts ->
      send(test_pid, {:repo_sync, repo_root, opts})
      {:ok, :pulled}
    end

    planner_run_turn = fn ^issue, prompt, opts ->
      send(test_pid, {:planner_run_turn, prompt, opts})
      {:ok, %{result: :ok}}
    end

    assert :ok =
             PlannerRunner.run(
               issue,
               self(),
               repo_sync: repo_sync,
               planner_run_turn: planner_run_turn
             )

    assert_receive {:repo_sync, repo_root, [branch: "testing"]}
    assert repo_root == March.Workflow.repo_root()

    assert_receive {:planner_run_turn, prompt, opts}
    assert is_binary(prompt)
    assert is_function(Keyword.fetch!(opts, :on_message), 1)
  end

  test "fails the planner turn when canonical repo sync fails" do
    issue = %Issue{
      id: "planner-runner-sync-error",
      identifier: "claworld/t100002",
      title: "Stop planner when repo is stale",
      state: "Planning",
      url: "https://example.test/tasks/planner-runner-sync-error",
      comments: []
    }

    repo_sync = fn _repo_root, _opts -> {:error, "repo is dirty"} end

    assert_raise RuntimeError, ~r/Planner sync failed.*repo is dirty/, fn ->
      PlannerRunner.run(
        issue,
        nil,
        repo_sync: repo_sync,
        planner_run_turn: fn _issue, _prompt, _opts ->
          flunk("planner turn should not start when repo sync fails")
        end
      )
    end
  end
end
