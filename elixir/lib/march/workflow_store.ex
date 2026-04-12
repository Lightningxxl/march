defmodule March.WorkflowStore do
  @moduledoc """
  Caches the last known good March config plus builder/planner/auditor
  documents and reloads them when any of those files change.
  """

  use GenServer
  require Logger

  alias March.Workflow

  @poll_interval_ms 1_000

  defmodule State do
    @moduledoc false

    defstruct [
      :path,
      :stamp,
      :config_path,
      :config_stamp,
      :builder_path,
      :builder_stamp,
      :planner_path,
      :planner_stamp,
      :auditor_path,
      :auditor_stamp,
      :workflow,
      :planner,
      :auditor
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec current() :: {:ok, Workflow.loaded_workflow()} | {:error, term()}
  def current do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(__MODULE__, :current)

      _ ->
        Workflow.load_builder()
    end
  end

  @spec planner_current() :: {:ok, Workflow.loaded_workflow()} | {:error, term()}
  def planner_current do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(__MODULE__, :planner_current)

      _ ->
        Workflow.load_planner()
    end
  end

  @spec current_documents() :: {:ok, Workflow.loaded_documents()} | {:error, term()}
  def current_documents do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(__MODULE__, :current_documents)

      _ ->
        Workflow.load_documents()
    end
  end

  @spec auditor_current() :: {:ok, Workflow.loaded_workflow()} | {:error, term()}
  def auditor_current do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(__MODULE__, :auditor_current)

      _ ->
        Workflow.load_auditor()
    end
  end

  @spec force_reload() :: :ok | {:error, term()}
  def force_reload do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(__MODULE__, :force_reload)

      _ ->
        case Workflow.load_documents() do
          {:ok, _documents} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @impl true
  def init(_opts) do
    case load_state(
           Workflow.config_file_path(),
           Workflow.workflow_file_path(),
           Workflow.planner_file_path(),
           Workflow.auditor_file_path()
         ) do
      {:ok, state} ->
        schedule_poll()
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:current, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        {:reply, {:ok, new_state.workflow}, new_state}

      {:error, _reason, new_state} ->
        {:reply, {:ok, new_state.workflow}, new_state}
    end
  end

  def handle_call(:planner_current, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        {:reply, {:ok, new_state.planner}, new_state}

      {:error, _reason, new_state} ->
        {:reply, {:ok, new_state.planner}, new_state}
    end
  end

  def handle_call(:current_documents, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        {:reply, {:ok, %{builder: new_state.workflow, planner: new_state.planner, auditor: new_state.auditor}}, new_state}

      {:error, _reason, new_state} ->
        {:reply, {:ok, %{builder: new_state.workflow, planner: new_state.planner, auditor: new_state.auditor}}, new_state}
    end
  end

  def handle_call(:auditor_current, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        {:reply, {:ok, new_state.auditor}, new_state}

      {:error, _reason, new_state} ->
        {:reply, {:ok, new_state.auditor}, new_state}
    end
  end

  def handle_call(:force_reload, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  @impl true
  def handle_info(:poll, %State{} = state) do
    schedule_poll()

    case reload_state(state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, _reason, new_state} -> {:noreply, new_state}
    end
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end

  defp reload_state(%State{} = state) do
    config_path = Workflow.config_file_path()
    builder_path = Workflow.workflow_file_path()
    planner_path = Workflow.planner_file_path()
    auditor_path = Workflow.auditor_file_path()

    if config_path != state.config_path or builder_path != state.builder_path or
         planner_path != state.planner_path or
         auditor_path != state.auditor_path do
      reload_paths(config_path, builder_path, planner_path, auditor_path, state)
    else
      reload_current_paths(config_path, builder_path, planner_path, auditor_path, state)
    end
  end

  defp reload_paths(config_path, builder_path, planner_path, auditor_path, state) do
    case load_state(config_path, builder_path, planner_path, auditor_path) do
      {:ok, new_state} ->
        {:ok, new_state}

      {:error, reason} ->
        log_reload_error(config_path, builder_path, planner_path, auditor_path, reason)
        {:error, reason, state}
    end
  end

  defp reload_current_paths(config_path, builder_path, planner_path, auditor_path, state) do
    with {:ok, config_stamp} <- current_stamp(config_path),
         {:ok, builder_stamp} <- current_stamp(builder_path),
         {:ok, planner_stamp} <- current_stamp(planner_path),
         {:ok, auditor_stamp} <- current_stamp(auditor_path) do
      if config_stamp == state.config_stamp and builder_stamp == state.builder_stamp and
           planner_stamp == state.planner_stamp and
           auditor_stamp == state.auditor_stamp do
        {:ok, state}
      else
        reload_paths(config_path, builder_path, planner_path, auditor_path, state)
      end
    else
      {:error, reason} ->
        log_reload_error(config_path, builder_path, planner_path, auditor_path, reason)
        {:error, reason, state}
    end
  end

  defp load_state(config_path, builder_path, planner_path, auditor_path) do
    with {:ok, %{builder: workflow, planner: planner, auditor: auditor}} <-
           Workflow.load_documents(config_path, builder_path, planner_path, auditor_path),
         {:ok, config_stamp} <- current_stamp(config_path),
         {:ok, builder_stamp} <- current_stamp(builder_path),
         {:ok, planner_stamp} <- current_stamp(planner_path),
         {:ok, auditor_stamp} <- current_stamp(auditor_path) do
      {:ok,
       %State{
         path: builder_path,
         stamp: builder_stamp,
         config_path: config_path,
         config_stamp: config_stamp,
         builder_path: builder_path,
         builder_stamp: builder_stamp,
         planner_path: planner_path,
         planner_stamp: planner_stamp,
         auditor_path: auditor_path,
         auditor_stamp: auditor_stamp,
         workflow: workflow,
         planner: planner,
         auditor: auditor
       }}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp current_stamp(path) when is_binary(path) do
    with {:ok, stat} <- File.stat(path, time: :posix),
         {:ok, content} <- File.read(path) do
      {:ok, {stat.mtime, stat.size, :erlang.phash2(content)}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp log_reload_error(config_path, builder_path, planner_path, auditor_path, reason) do
    Logger.error(
      "Failed to reload workflow config_path=#{config_path} builder_path=#{builder_path} planner_path=#{planner_path} auditor_path=#{auditor_path} " <>
        "reason=#{inspect(reason)}; keeping last known good configuration"
    )
  end
end
