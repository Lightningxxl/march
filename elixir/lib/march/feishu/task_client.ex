defmodule March.Feishu.TaskClient do
  @moduledoc """
  Thin wrapper around the official `lark-cli` task commands.

  March uses the CLI as the auth and transport boundary instead of managing
  Feishu OAuth tokens itself.
  """

  alias March.Config

  @page_size 100

  @spec list_tasklist_task_guids(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_tasklist_task_guids(tasklist_guid) when is_binary(tasklist_guid) do
    params = %{
      "tasklist_guid" => tasklist_guid,
      "user_id_type" => "open_id",
      "page_size" => @page_size,
      "completed" => false
    }

    with {:ok, %{"data" => %{"items" => items}}} <-
           run_cli(["task", "tasklists", "tasks", "--page-all", "--params", Jason.encode!(params)]) do
      {:ok,
       items
       |> Enum.map(&Map.get(&1, "guid"))
       |> Enum.filter(&is_binary/1)}
    end
  end

  def list_tasklist_task_guids(_tasklist_guid), do: {:error, :missing_feishu_tasklist_guid}

  @spec get_task(String.t()) :: {:ok, map()} | {:error, term()}
  def get_task(task_guid) when is_binary(task_guid) do
    params = %{"task_guid" => task_guid, "user_id_type" => "open_id"}

    with {:ok, %{"data" => %{"task" => task}}} <-
           run_cli(["task", "tasks", "get", "--params", Jason.encode!(params)]) do
      {:ok, task}
    end
  end

  @spec list_comments(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_comments(task_guid) when is_binary(task_guid) do
    params = %{
      "resource_type" => "task",
      "resource_id" => task_guid
    }

    with {:ok, %{"data" => %{"items" => items}}} <-
           run_cli(["api", "GET", "/task/v2/comments", "--params", Jason.encode!(params)]) do
      {:ok, items}
    end
  end

  @spec list_custom_fields(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_custom_fields(tasklist_guid) when is_binary(tasklist_guid) do
    params = %{
      "resource_type" => "tasklist",
      "resource_id" => tasklist_guid
    }

    with {:ok, %{"data" => %{"items" => items}}} <-
           run_cli(["api", "GET", "/task/v2/custom_fields", "--params", Jason.encode!(params)]) do
      {:ok, items}
    end
  end

  @spec list_sections(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_sections(tasklist_guid) when is_binary(tasklist_guid) do
    params = %{
      "resource_type" => "tasklist",
      "resource_id" => tasklist_guid
    }

    with {:ok, %{"data" => %{"items" => items}}} <-
           run_cli(["api", "GET", "/task/v2/sections", "--params", Jason.encode!(params)]) do
      {:ok, items}
    end
  end

  @spec move_task_to_section(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def move_task_to_section(task_guid, tasklist_guid, section_guid)
      when is_binary(task_guid) and is_binary(tasklist_guid) and is_binary(section_guid) do
    data = %{
      "tasklist_guid" => tasklist_guid,
      "section_guid" => section_guid
    }

    with {:ok, _payload} <-
           run_cli([
             "api",
             "POST",
             "/task/v2/tasks/#{task_guid}/add_tasklist",
             "--data",
             Jason.encode!(data)
           ]) do
      :ok
    end
  end

  @spec patch_task(String.t(), [String.t()], map()) :: {:ok, map()} | {:error, term()}
  def patch_task(task_guid, update_fields, task_payload)
      when is_binary(task_guid) and is_list(update_fields) and is_map(task_payload) do
    params = %{"task_guid" => task_guid, "user_id_type" => "open_id"}
    data = %{"update_fields" => update_fields, "task" => task_payload}

    with {:ok, %{"data" => %{"task" => task}}} <-
           run_cli([
             "task",
             "tasks",
             "patch",
             "--params",
             Jason.encode!(params),
             "--data",
             Jason.encode!(data)
           ]) do
      {:ok, task}
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(task_guid, content) when is_binary(task_guid) and is_binary(content) do
    with {:ok, _response} <-
           run_cli(["task", "+comment", "--task-id", task_guid, "--content", content]) do
      :ok
    end
  end

  defp run_cli(args) when is_list(args) do
    executable = Config.lark_cli_command()
    full_args = args ++ identity_args()
    timeout_ms = Config.lark_cli_timeout_ms()

    case run_command(executable, full_args, timeout_ms) do
      {:ok, {output, 0}} ->
        decode_cli_output(output)

      {:ok, {output, status}} ->
        {:error, {:lark_cli_failed, status, output}}

      {:error, _reason} = error ->
        error
    end
  rescue
    error in ErlangError ->
      {:error, {:lark_cli_spawn_failed, error.original}}
  end

  @doc false
  def run_command(executable, full_args, timeout_ms)
      when is_binary(executable) and is_list(full_args) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        System.cmd(executable, full_args, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        {:ok, result}

      {:exit, reason} ->
        {:error, {:lark_cli_task_exit, reason}}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:lark_cli_timeout, timeout_ms, [executable | full_args]}}
    end
  end

  defp identity_args do
    identity =
      Config.feishu_identity()
      |> to_string()
      |> String.trim()

    if identity in ["", "auto"] do
      []
    else
      ["--as", identity]
    end
  end

  @doc false
  def decode_cli_output(output) when is_binary(output) do
    output = extract_json_payload(output)

    case Jason.decode(output) do
      {:ok, %{"code" => 0} = payload} ->
        {:ok, payload}

      {:ok, %{"code" => code, "msg" => message} = payload} ->
        {:error, {:lark_api_error, code, message, payload}}

      {:ok, payload} ->
        {:ok, payload}

      {:error, reason} ->
        {:error, {:invalid_lark_cli_json, reason, output}}
    end
  end

  defp extract_json_payload(output) when is_binary(output) do
    trimmed = String.trim(output)

    case :binary.match(trimmed, "{") do
      {index, _length} when index > 0 ->
        binary_part(trimmed, index, byte_size(trimmed) - index)

      _ ->
        trimmed
    end
  end
end
