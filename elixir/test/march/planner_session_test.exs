defmodule March.PlannerSessionTest do
  use ExUnit.Case

  alias March.PlannerSession

  setup do
    previous = Process.flag(:trap_exit, true)

    on_exit(fn ->
      Process.flag(:trap_exit, previous)
    end)

    :ok
  end

  test "terminates the session after a failed run_turn so the next turn can rebuild" do
    test_pid = self()
    issue_id = "planner-session-test-#{System.unique_integer([:positive])}"

    app_server = %{
      start_session: fn _workspace, _opts -> {:ok, :fake_session} end,
      run_turn: fn :fake_session, "prompt", %{id: ^issue_id}, [] -> {:error, :boom} end,
      stop_session: fn :fake_session ->
        send(test_pid, :stop_session_called)
        :ok
      end
    }

    {:ok, pid} =
      PlannerSession.start_link(
        name: {:via, Registry, {March.PlannerSessionRegistry, issue_id}},
        issue_id: issue_id,
        workspace: System.tmp_dir!(),
        app_server: app_server
      )

    ref = Process.monitor(pid)

    assert PlannerSession.run_turn(pid, "prompt", %{id: issue_id}) == {:error, :boom}
    assert_receive :stop_session_called
    assert_receive {:DOWN, ^ref, :process, ^pid, {:run_turn_failed, :boom}}
  end

  test "terminates the session when the underlying Codex port exits" do
    test_pid = self()
    issue_id = "planner-session-test-#{System.unique_integer([:positive])}"

    app_server = %{
      start_session: fn _workspace, _opts -> {:ok, :fake_session} end,
      run_turn: fn _session, _prompt, _issue, _opts -> {:ok, %{}} end,
      stop_session: fn :fake_session ->
        send(test_pid, :stop_session_called)
        :ok
      end
    }

    {:ok, pid} =
      PlannerSession.start_link(
        name: {:via, Registry, {March.PlannerSessionRegistry, issue_id}},
        issue_id: issue_id,
        workspace: System.tmp_dir!(),
        app_server: app_server
      )

    ref = Process.monitor(pid)
    send(pid, {self(), {:exit_status, 137}})

    assert_receive :stop_session_called
    assert_receive {:DOWN, ^ref, :process, ^pid, {:codex_session_exited, 137}}
  end
end
