defmodule March.CLI do
  @moduledoc """
  Escript entrypoint for running March against a repository root.
  """

  alias March.LogFile

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @switches [{@acknowledgement_switch, :boolean}, logs_root: :string]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          dir?: (String.t() -> boolean()),
          file_regular?: (String.t() -> boolean()),
          set_repo_root: (String.t() -> :ok | {:error, term()}),
          set_workflow_file_path: (String.t() -> :ok | {:error, term()}),
          set_logs_root: (String.t() -> :ok | {:error, term()}),
          sync_repo: (String.t() -> :ok | {:error, term()}),
          ensure_all_started: (-> ensure_started_result())
        }

  @spec main([String.t()]) :: no_return()
  def main(args) do
    case evaluate(args) do
      :ok ->
        wait_for_shutdown()

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @spec evaluate([String.t()], deps()) :: :ok | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps()) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps) do
          run(File.cwd!(), deps)
        end

      {opts, [target_path], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps) do
          run(target_path, deps)
        end

      _ ->
        {:error, usage_message()}
    end
  end

  @spec run(String.t(), deps()) :: :ok | {:error, String.t()}
  def run(target_path, deps) do
    expanded_path = Path.expand(target_path)

    cond do
      deps.dir?.(expanded_path) ->
        config_path = Path.join(expanded_path, "MARCH.yml")
        builder_path = Path.join(expanded_path, "BUILDER.md")
        planner_path = Path.join(expanded_path, "PLANNER.md")
        auditor_path = Path.join(expanded_path, "AUDITOR.md")

        cond do
          !deps.file_regular?.(config_path) ->
            {:error, "Config file not found: #{config_path}"}

          !deps.file_regular?.(builder_path) ->
            {:error, "Builder file not found: #{builder_path}"}

          !deps.file_regular?.(planner_path) ->
            {:error, "Planner file not found: #{planner_path}"}

          !deps.file_regular?.(auditor_path) ->
            {:error, "Auditor file not found: #{auditor_path}"}

          true ->
            :ok = deps.set_repo_root.(expanded_path)

            with :ok <- deps.sync_repo.(expanded_path) do
              ensure_started(expanded_path, deps)
            end
        end

      deps.file_regular?.(expanded_path) ->
        config_path = Path.join(Path.dirname(expanded_path), "MARCH.yml")
        planner_path = Path.join(Path.dirname(expanded_path), "PLANNER.md")
        auditor_path = Path.join(Path.dirname(expanded_path), "AUDITOR.md")

        if deps.file_regular?.(config_path) do
          if deps.file_regular?.(planner_path) do
            if deps.file_regular?.(auditor_path) do
              :ok = deps.set_workflow_file_path.(expanded_path)
              ensure_started(expanded_path, deps)
            else
              {:error, "Auditor file not found: #{auditor_path}"}
            end
          else
            {:error, "Planner file not found: #{planner_path}"}
          end
        else
          {:error, "Config file not found: #{config_path}"}
        end

      true ->
        {:error, "Repository or builder file not found: #{expanded_path}"}
    end
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    "Usage: march [--logs-root <path>] [repo-dir-or-path-to-BUILDER.md]"
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      dir?: &File.dir?/1,
      file_regular?: &File.regular?/1,
      set_repo_root: &March.Workflow.set_repo_root/1,
      set_workflow_file_path: &March.Workflow.set_workflow_file_path/1,
      set_logs_root: &set_logs_root/1,
      sync_repo: &sync_repo/1,
      ensure_all_started: fn -> Application.ensure_all_started(:march) end
    }
  end

  defp ensure_started(target, deps) do
    IO.puts("Starting March application...")

    case deps.ensure_all_started.() do
      {:ok, _started_apps} ->
        IO.puts("March application started.")
        :ok

      {:error, reason} ->
        {:error, "Failed to start March with target #{target}: #{inspect(reason)}"}
    end
  end

  defp sync_repo(repo_root) when is_binary(repo_root) do
    canonical_branch = March.Config.canonical_branch()

    sync_status = %{
      phase: :startup,
      status: :checking,
      repo_root: repo_root,
      at: DateTime.utc_now()
    }

    Application.put_env(:march, :last_repo_sync_status, sync_status)
    IO.puts("Checking planner source repo: #{repo_root}")

    case March.CanonicalRepo.ensure_ready(repo_root, branch: canonical_branch) do
      {:ok, :up_to_date} ->
        Application.put_env(:march, :last_repo_sync_status, %{
          phase: :startup,
          status: :up_to_date,
          repo_root: repo_root,
          at: DateTime.utc_now()
        })

        IO.puts("Planner source repo already up to date on #{canonical_branch}.")
        :ok

      {:ok, :pulled} ->
        Application.put_env(:march, :last_repo_sync_status, %{
          phase: :startup,
          status: :pulled,
          repo_root: repo_root,
          at: DateTime.utc_now()
        })

        IO.puts("Fast-forwarded planner source repo to latest origin/#{canonical_branch}.")
        :ok

      {:error, reason} ->
        Application.put_env(:march, :last_repo_sync_status, %{
          phase: :startup,
          status: :error,
          repo_root: repo_root,
          detail: reason,
          at: DateTime.utc_now()
        })

        {:error, reason}
    end
  end

  defp maybe_set_logs_root(opts, deps) do
    case Keyword.get_values(opts, :logs_root) do
      [] ->
        :ok

      values ->
        logs_root = values |> List.last() |> String.trim()

        if logs_root == "" do
          {:error, usage_message()}
        else
          :ok = deps.set_logs_root.(Path.expand(logs_root))
        end
    end
  end

  defp require_guardrails_acknowledgement(opts) do
    if Keyword.get(opts, @acknowledgement_switch, false) do
      :ok
    else
      {:error, acknowledgement_banner()}
    end
  end

  @spec acknowledgement_banner() :: String.t()
  defp acknowledgement_banner do
    lines = [
      "March is a low key engineering preview.",
      "Codex will run without any guardrails.",
      "March is not a supported product and is presented as-is.",
      "To proceed, start with `--i-understand-that-this-will-be-running-without-the-usual-guardrails` CLI argument"
    ]

    width = Enum.max(Enum.map(lines, &String.length/1))
    border = String.duplicate("─", width + 2)
    top = "╭" <> border <> "╮"
    bottom = "╰" <> border <> "╯"
    spacer = "│ " <> String.duplicate(" ", width) <> " │"

    content =
      [
        top,
        spacer
        | Enum.map(lines, fn line ->
            "│ " <> String.pad_trailing(line, width) <> " │"
          end)
      ] ++ [spacer, bottom]

    [
      IO.ANSI.red(),
      IO.ANSI.bright(),
      Enum.join(content, "\n"),
      IO.ANSI.reset()
    ]
    |> IO.iodata_to_binary()
  end

  defp set_logs_root(logs_root) do
    Application.put_env(:march, :log_file, LogFile.default_log_file(logs_root))
    :ok
  end

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case Process.whereis(March.Supervisor) do
      nil ->
        IO.puts(:stderr, "March supervisor is not running")
        System.halt(1)

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case reason do
              :normal -> System.halt(0)
              _ -> System.halt(1)
            end
        end
    end
  end
end
