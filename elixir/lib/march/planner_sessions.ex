defmodule March.PlannerSessions do
  @moduledoc """
  Registry helpers for per-issue long-lived planner sessions.
  """

  alias March.{PlannerSession, Workflow}

  @spec run_turn(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(%{id: issue_id} = issue, prompt, opts \\ []) when is_binary(issue_id) do
    with {:ok, pid} <- ensure_session(issue_id) do
      PlannerSession.run_turn(pid, prompt, issue, opts)
    end
  end

  @spec release(String.t()) :: :ok
  def release(issue_id) when is_binary(issue_id) do
    case Registry.lookup(March.PlannerSessionRegistry, issue_id) do
      [{pid, _value}] ->
        DynamicSupervisor.terminate_child(March.PlannerSessionSupervisor, pid)
        :ok

      [] ->
        :ok
    end
  end

  def release(_issue_id), do: :ok

  defp ensure_session(issue_id) do
    case Registry.lookup(March.PlannerSessionRegistry, issue_id) do
      [{pid, _value}] ->
        {:ok, pid}

      [] ->
        start_session(issue_id)
    end
  end

  defp start_session(issue_id) do
    child_spec = %{
      id: {:planner_session, issue_id},
      start:
        {PlannerSession, :start_link,
         [
           [
             name: via_tuple(issue_id),
             issue_id: issue_id,
             workspace: Workflow.repo_root()
           ]
         ]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(March.PlannerSessionSupervisor, child_spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp via_tuple(issue_id) do
    {:via, Registry, {March.PlannerSessionRegistry, issue_id}}
  end
end
