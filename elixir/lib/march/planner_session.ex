defmodule March.PlannerSession do
  @moduledoc """
  Long-lived planner Codex session bound to a single tracker item.
  """

  use GenServer

  alias March.Codex.AppServer

  defstruct [:issue_id, :workspace, :session, :app_server]

  @type t :: %__MODULE__{
          issue_id: String.t(),
          workspace: Path.t(),
          session: map()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    issue_id = Keyword.fetch!(opts, :issue_id)
    workspace = Keyword.fetch!(opts, :workspace)
    app_server = Keyword.get(opts, :app_server, default_app_server())
    GenServer.start_link(__MODULE__, {issue_id, workspace, app_server}, name: name)
  end

  @spec run_turn(GenServer.server(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(server, prompt, issue, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    GenServer.call(server, {:run_turn, prompt, issue, opts}, timeout)
  end

  @impl true
  def init({issue_id, workspace, app_server}) do
    case app_server.start_session.(workspace, allow_repo_root: true) do
      {:ok, session} ->
        {:ok, %__MODULE__{issue_id: issue_id, workspace: workspace, session: session, app_server: app_server}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(
        {:run_turn, prompt, issue, opts},
        _from,
        %__MODULE__{session: session, app_server: app_server} = state
      ) do
    run_opts = Keyword.drop(opts, [:timeout])

    case app_server.run_turn.(session, prompt, issue, run_opts) do
      {:ok, _result} = ok ->
        {:reply, ok, state}

      {:error, reason} = error ->
        {:stop, {:run_turn_failed, reason}, error, state}
    end
  end

  @impl true
  def handle_info({_port, {:data, _payload}}, state) do
    {:noreply, state}
  end

  def handle_info({_port, {:exit_status, status}}, state) do
    {:stop, {:codex_session_exited, status}, state}
  end

  @impl true
  def terminate(_reason, %__MODULE__{session: session, app_server: app_server}) do
    app_server.stop_session.(session)
    :ok
  end

  defp default_app_server do
    %{
      start_session: fn workspace, opts -> AppServer.start_session(workspace, opts) end,
      run_turn: fn session, prompt, issue, opts -> AppServer.run_turn(session, prompt, issue, opts) end,
      stop_session: fn session -> AppServer.stop_session(session) end
    }
  end
end
