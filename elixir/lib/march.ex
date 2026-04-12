defmodule March do
  @moduledoc """
  Entry point for the March orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    March.Orchestrator.start_link(opts)
  end
end

defmodule March.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  @impl true
  def start(_type, _args) do
    :ok = March.LogFile.configure()

    children = [
      {Registry, keys: :unique, name: March.PlannerSessionRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: March.PlannerSessionSupervisor},
      {Task.Supervisor, name: March.TaskSupervisor},
      March.WorkflowStore,
      March.Orchestrator,
      March.StatusDashboard
    ]

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: March.Supervisor
    )
  end

  @impl true
  def stop(_state) do
    March.StatusDashboard.render_offline_status()
    :ok
  end
end
