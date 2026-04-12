defmodule March.BuilderRunner do
  @moduledoc """
  Builder lane wrapper around the multi-turn AgentRunner.
  """

  alias March.{AgentRunner, Feishu.TaskState}

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(%{id: issue_id} = issue, codex_update_recipient \\ nil, opts \\ []) when is_binary(issue_id) do
    mode = Keyword.get(opts, :mode, TaskState.builder_mode(issue))

    opts =
      opts
      |> Keyword.put(:mode, mode)
      |> Keyword.put(:ticket, TaskState.prompt_context(issue))

    AgentRunner.run(issue, codex_update_recipient, opts)
  end
end
