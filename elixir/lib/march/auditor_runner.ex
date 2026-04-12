defmodule March.AuditorRunner do
  @moduledoc """
  Single-turn auditor lane that reuses the isolated builder workspace.
  """

  require Logger

  alias March.Codex.AppServer
  alias March.{Feishu.TaskState, PromptBuilder, Workspace}

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(%{id: issue_id} = issue, codex_update_recipient \\ nil, opts \\ []) when is_binary(issue_id) do
    with {:ok, workspace} <- Workspace.create_for_issue(issue),
         :ok <- Workspace.run_before_run_hook(workspace, issue) do
      mode = auditor_mode(issue.auditor_verdict)

      prompt =
        PromptBuilder.build_auditor_prompt(
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

      with {:ok, session} <- AppServer.start_session(workspace) do
        try do
          case AppServer.run_turn(
                 session,
                 prompt,
                 issue,
                 on_message: codex_message_handler(codex_update_recipient, issue)
               ) do
            {:ok, _result} ->
              :ok

            {:error, reason} ->
              {:error, reason}
          end
        after
          AppServer.stop_session(session)
          Workspace.run_after_run_hook(workspace, issue)
        end
      end
    else
      {:error, reason} ->
        Logger.error("Auditor run failed issue_id=#{issue.id} issue_identifier=#{issue.identifier}: #{inspect(reason)}")
        raise RuntimeError, "Auditor run failed issue_id=#{issue.id} issue_identifier=#{issue.identifier}: #{inspect(reason)}"
    end
  end

  defp codex_message_handler(recipient, %{id: issue_id}) when is_pid(recipient) and is_binary(issue_id) do
    fn message ->
      send(recipient, {:codex_worker_update, issue_id, message})
      :ok
    end
  end

  defp codex_message_handler(_recipient, _issue), do: fn _message -> :ok end

  defp auditor_mode(verdict) when is_binary(verdict) do
    if String.trim(verdict) == "", do: "audit", else: "reaudit"
  end

  defp auditor_mode(nil), do: "audit"
  defp auditor_mode(_verdict), do: "reaudit"

  defp maybe_put_attempt(ticket, attempt) when is_integer(attempt), do: Map.put(ticket, :attempt, attempt)
  defp maybe_put_attempt(ticket, _attempt), do: ticket
end
