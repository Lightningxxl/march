defmodule March.Workflow do
  @moduledoc """
  Loads shared March config plus builder/planner/auditor documents from a
  repository root.
  """

  alias March.WorkflowStore

  @config_file_name "MARCH.yml"
  @builder_file_name "BUILDER.md"
  @planner_file_name "PLANNER.md"
  @auditor_file_name "AUDITOR.md"

  @type loaded_workflow :: %{
          config: map(),
          prompt: String.t(),
          prompt_template: String.t()
        }

  @type loaded_documents :: %{
          builder: loaded_workflow(),
          planner: loaded_workflow(),
          auditor: loaded_workflow()
        }

  @spec repo_root() :: Path.t()
  def repo_root do
    Application.get_env(:march, :repo_root) ||
      File.cwd!()
  end

  @spec set_repo_root(Path.t()) :: :ok
  def set_repo_root(path) when is_binary(path) do
    expanded_path = Path.expand(path)
    Application.put_env(:march, :repo_root, expanded_path)
    Application.delete_env(:march, :config_file_path)
    Application.delete_env(:march, :workflow_file_path)
    Application.delete_env(:march, :planner_file_path)
    Application.delete_env(:march, :auditor_file_path)
    maybe_reload_store()
    :ok
  end

  @spec clear_repo_root() :: :ok
  def clear_repo_root do
    Application.delete_env(:march, :repo_root)
    Application.delete_env(:march, :config_file_path)
    Application.delete_env(:march, :workflow_file_path)
    Application.delete_env(:march, :planner_file_path)
    Application.delete_env(:march, :auditor_file_path)
    maybe_reload_store()
    :ok
  end

  @spec config_file_path() :: Path.t()
  def config_file_path do
    case Application.get_env(:march, :config_file_path) do
      path when is_binary(path) ->
        path

      _ ->
        Path.join(repo_root(), @config_file_name)
    end
  end

  @spec workflow_file_path() :: Path.t()
  def workflow_file_path do
    case Application.get_env(:march, :workflow_file_path) do
      path when is_binary(path) ->
        path

      _ ->
        Path.join(repo_root(), @builder_file_name)
    end
  end

  @spec planner_file_path() :: Path.t()
  def planner_file_path do
    case Application.get_env(:march, :planner_file_path) do
      path when is_binary(path) ->
        path

      _ ->
        Path.join(Path.dirname(workflow_file_path()), @planner_file_name)
    end
  end

  @spec auditor_file_path() :: Path.t()
  def auditor_file_path do
    case Application.get_env(:march, :auditor_file_path) do
      path when is_binary(path) ->
        path

      _ ->
        Path.join(Path.dirname(workflow_file_path()), @auditor_file_name)
    end
  end

  @spec set_workflow_file_path(Path.t()) :: :ok
  def set_workflow_file_path(path) when is_binary(path) do
    expanded_path = Path.expand(path)
    Application.put_env(:march, :workflow_file_path, expanded_path)
    Application.put_env(:march, :repo_root, Path.dirname(expanded_path))
    Application.delete_env(:march, :config_file_path)
    Application.delete_env(:march, :planner_file_path)
    Application.delete_env(:march, :auditor_file_path)
    maybe_reload_store()
    :ok
  end

  @spec clear_workflow_file_path() :: :ok
  def clear_workflow_file_path do
    Application.delete_env(:march, :config_file_path)
    Application.delete_env(:march, :workflow_file_path)
    Application.delete_env(:march, :planner_file_path)
    Application.delete_env(:march, :auditor_file_path)
    Application.delete_env(:march, :repo_root)
    maybe_reload_store()
    :ok
  end

  @spec current() :: {:ok, loaded_workflow()} | {:error, term()}
  def current do
    case Process.whereis(WorkflowStore) do
      pid when is_pid(pid) ->
        WorkflowStore.current()

      _ ->
        load_builder()
    end
  end

  @spec planner_current() :: {:ok, loaded_workflow()} | {:error, term()}
  def planner_current do
    case Process.whereis(WorkflowStore) do
      pid when is_pid(pid) ->
        WorkflowStore.planner_current()

      _ ->
        load_planner()
    end
  end

  @spec current_documents() :: {:ok, loaded_documents()} | {:error, term()}
  def current_documents do
    case Process.whereis(WorkflowStore) do
      pid when is_pid(pid) ->
        WorkflowStore.current_documents()

      _ ->
        load_documents()
    end
  end

  @spec auditor_current() :: {:ok, loaded_workflow()} | {:error, term()}
  def auditor_current do
    case Process.whereis(WorkflowStore) do
      pid when is_pid(pid) ->
        WorkflowStore.auditor_current()

      _ ->
        load_auditor()
    end
  end

  @spec load() :: {:ok, loaded_workflow()} | {:error, term()}
  def load do
    load_builder()
  end

  @spec load(Path.t()) :: {:ok, loaded_workflow()} | {:error, term()}
  def load(path) when is_binary(path) do
    load_builder(path)
  end

  @spec load_builder() :: {:ok, loaded_workflow()} | {:error, term()}
  def load_builder do
    load_builder(workflow_file_path(), config_file_path())
  end

  @spec load_builder(Path.t()) :: {:ok, loaded_workflow()} | {:error, term()}
  def load_builder(path) when is_binary(path) do
    load_builder(path, sibling_config_file_path(path))
  end

  @spec load_builder(Path.t(), Path.t()) :: {:ok, loaded_workflow()} | {:error, term()}
  def load_builder(path, config_path) when is_binary(path) and is_binary(config_path) do
    load_role_document(path, config_path, :builder)
  end

  @spec load_planner() :: {:ok, loaded_workflow()} | {:error, term()}
  def load_planner do
    load_planner(planner_file_path(), config_file_path())
  end

  @spec load_planner(Path.t()) :: {:ok, loaded_workflow()} | {:error, term()}
  def load_planner(path) when is_binary(path) do
    load_planner(path, sibling_config_file_path(path))
  end

  @spec load_planner(Path.t(), Path.t()) :: {:ok, loaded_workflow()} | {:error, term()}
  def load_planner(path, config_path) when is_binary(path) and is_binary(config_path) do
    load_role_document(path, config_path, :planner)
  end

  @spec load_auditor() :: {:ok, loaded_workflow()} | {:error, term()}
  def load_auditor do
    load_auditor(auditor_file_path(), config_file_path())
  end

  @spec load_auditor(Path.t()) :: {:ok, loaded_workflow()} | {:error, term()}
  def load_auditor(path) when is_binary(path) do
    load_auditor(path, sibling_config_file_path(path))
  end

  @spec load_auditor(Path.t(), Path.t()) :: {:ok, loaded_workflow()} | {:error, term()}
  def load_auditor(path, config_path) when is_binary(path) and is_binary(config_path) do
    load_role_document(path, config_path, :auditor)
  end

  @spec load_config() :: {:ok, map()} | {:error, term()}
  def load_config do
    load_config(config_file_path())
  end

  @spec load_config(Path.t()) :: {:ok, map()} | {:error, term()}
  def load_config(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        parse_config(content)

      {:error, reason} ->
        {:error, {:missing_config_file, path, reason}}
    end
  end

  @spec load_documents() :: {:ok, loaded_documents()} | {:error, term()}
  def load_documents do
    load_documents(config_file_path(), workflow_file_path(), planner_file_path(), auditor_file_path())
  end

  @spec load_documents(Path.t(), Path.t(), Path.t(), Path.t()) :: {:ok, loaded_documents()} | {:error, term()}
  def load_documents(config_path, builder_path, planner_path, auditor_path)
      when is_binary(config_path) and is_binary(builder_path) and is_binary(planner_path) and
             is_binary(auditor_path) do
    with {:ok, config} <- load_config(config_path),
         {:ok, builder} <- load_role_prompt(builder_path, :builder, config),
         {:ok, planner} <- load_role_prompt(planner_path, :planner, config),
         {:ok, auditor} <- load_role_prompt(auditor_path, :auditor, config) do
      {:ok, %{builder: builder, planner: planner, auditor: auditor}}
    end
  end

  defp load_role_document(path, config_path, role) do
    with {:ok, config} <- load_config(config_path),
         {:ok, document} <- load_role_prompt(path, role, config) do
      {:ok, document}
    end
  end

  defp load_role_prompt(path, role, config) when is_binary(path) and is_map(config) do
    case File.read(path) do
      {:ok, content} ->
        prompt = String.trim(content)

        {:ok,
         %{
           config: config,
           prompt: prompt,
           prompt_template: prompt
         }}

      {:error, reason} ->
        {:error, {missing_role_error_tag(role), path, reason}}
    end
  end

  defp parse_config(content) when is_binary(content) do
    yaml = String.trim(content)

    if yaml == "" do
      {:ok, %{}}
    else
      case YamlElixir.read_from_string(content) do
        {:ok, decoded} when is_map(decoded) ->
          {:ok, decoded}

        {:ok, _} ->
          {:error, :workflow_config_not_a_map}

        {:error, reason} ->
          {:error, {:workflow_config_parse_error, reason}}
      end
    end
  end

  defp sibling_config_file_path(path) when is_binary(path) do
    Path.join(Path.dirname(path), @config_file_name)
  end

  defp missing_role_error_tag(:builder), do: :missing_workflow_file
  defp missing_role_error_tag(:planner), do: :missing_planner_file
  defp missing_role_error_tag(:auditor), do: :missing_auditor_file

  defp maybe_reload_store do
    if Process.whereis(WorkflowStore) do
      _ = WorkflowStore.force_reload()
    end

    :ok
  end
end
