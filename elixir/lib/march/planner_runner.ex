defmodule March.PlannerRunner do
  @moduledoc """
  Single-turn planner lane that reuses a persistent per-issue Codex session.
  """

  require Logger

  alias March.{CanonicalRepo, Config, Feishu.TaskState, PlannerSessions, PromptBuilder, Workflow}

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(%{id: issue_id} = issue, codex_update_recipient \\ nil, opts \\ []) when is_binary(issue_id) do
    with :ok <- ensure_canonical_repo_ready(issue, opts) do
      mode = TaskState.planner_mode(issue)

      prompt =
        PromptBuilder.build_planner_prompt(
          issue,
          attempt: Keyword.get(opts, :attempt),
          max_turns: 1,
          mode: mode,
          turn_number: 1,
          turn_phase: "single_turn",
          ticket:
            issue
            |> TaskState.prompt_context()
            |> Map.put(:mode, mode)
            |> Map.put(:turn_phase, "single_turn")
            |> Map.put(:turn_number, 1)
            |> Map.put(:max_turns, 1)
            |> maybe_put_attempt(Keyword.get(opts, :attempt))
        )

      run_turn = Keyword.get(opts, :planner_run_turn, &PlannerSessions.run_turn/3)

      case run_turn.(
             issue,
             prompt,
             on_message: codex_message_handler(codex_update_recipient, issue)
           ) do
        {:ok, _result} ->
          :ok

        {:error, reason} ->
          Logger.error("Planner run failed issue_id=#{issue.id} issue_identifier=#{issue.identifier}: #{inspect(reason)}")
          raise RuntimeError, "Planner run failed issue_id=#{issue.id} issue_identifier=#{issue.identifier}: #{inspect(reason)}"
      end
    else
      {:error, reason} ->
        Logger.error("Planner sync failed issue_id=#{issue.id} issue_identifier=#{issue.identifier}: #{inspect(reason)}")
        raise RuntimeError, "Planner sync failed issue_id=#{issue.id} issue_identifier=#{issue.identifier}: #{inspect(reason)}"
    end
  end

  defp maybe_put_attempt(ticket, attempt) when is_integer(attempt), do: Map.put(ticket, :attempt, attempt)
  defp maybe_put_attempt(ticket, _attempt), do: ticket

  defp ensure_canonical_repo_ready(%{id: issue_id, identifier: identifier}, opts) do
    repo_root = Workflow.repo_root()
    branch = Config.canonical_branch()
    repo_sync = Keyword.get(opts, :repo_sync, &CanonicalRepo.ensure_ready/2)

    case repo_sync.(repo_root, branch: branch) do
      {:ok, :up_to_date} ->
        Logger.info(
          "Canonical planner repo already up to date on #{branch} before planner turn " <>
            "issue_id=#{issue_id} issue_identifier=#{identifier}"
        )

        :ok

      {:ok, :pulled} ->
        Logger.info(
          "Canonical planner repo fast-forwarded to #{branch} before planner turn " <>
            "issue_id=#{issue_id} issue_identifier=#{identifier}"
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to sync canonical planner repo before planner turn " <>
            "issue_id=#{issue_id} issue_identifier=#{identifier}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, %{id: issue_id}) when is_pid(recipient) and is_binary(issue_id) do
    fn message ->
      send(recipient, {:codex_worker_update, issue_id, message})
      :ok
    end
  end

  defp codex_message_handler(_recipient, _issue), do: fn _message -> :ok end
end
