defmodule March.CanonicalRepo do
  @moduledoc """
  Keeps the local planner-facing canonical repo aligned with the configured
  canonical branch when it is safe to do so.
  """

  @default_remote "origin"
  @default_branch "testing"

  @type sync_result :: {:ok, :up_to_date | :pulled} | {:error, String.t()}
  @type runner :: (String.t(), [String.t()] -> {String.t(), non_neg_integer()})

  @spec ensure_ready(String.t(), keyword()) :: sync_result()
  def ensure_ready(repo_root, opts \\ []) when is_binary(repo_root) do
    runner = Keyword.get(opts, :runner, &default_runner/2)
    remote = Keyword.get(opts, :remote, @default_remote)
    branch = Keyword.get(opts, :branch, @default_branch)

    with :ok <- ensure_git_repo(repo_root, runner),
         {:ok, current_branch} <- current_branch(repo_root, runner),
         :ok <- ensure_expected_branch(repo_root, current_branch, branch),
         :ok <- ensure_clean_worktree(repo_root, runner),
         :ok <- fetch_remote_branch(repo_root, runner, remote, branch),
         {:ok, remote_only_count, local_only_count} <-
           ahead_behind_counts(repo_root, runner, remote, branch),
         {:ok, action} <-
           sync_if_needed(repo_root, runner, remote, branch, remote_only_count, local_only_count) do
      {:ok, action}
    end
  end

  defp ensure_git_repo(repo_root, runner) do
    case run_git(repo_root, runner, ["rev-parse", "--is-inside-work-tree"]) do
      {:ok, "true"} ->
        :ok

      {:ok, _other} ->
        {:error, "Planner source repo at #{repo_root} is not a git worktree."}

      {:error, reason} ->
        {:error, "Failed to inspect planner source repo at #{repo_root}: #{reason}"}
    end
  end

  defp current_branch(repo_root, runner) do
    case run_git(repo_root, runner, ["rev-parse", "--abbrev-ref", "HEAD"]) do
      {:ok, branch} when branch != "" -> {:ok, branch}
      {:ok, _} -> {:error, "Could not determine the current branch for #{repo_root}."}
      {:error, reason} -> {:error, "Failed to read current branch for #{repo_root}: #{reason}"}
    end
  end

  defp ensure_expected_branch(repo_root, current_branch, expected_branch) do
    if current_branch == expected_branch do
      :ok
    else
      {:error, "Planner source repo at #{repo_root} must be on #{expected_branch} before March starts or after merge syncs; current branch is #{current_branch}."}
    end
  end

  defp ensure_clean_worktree(repo_root, runner) do
    case run_git(repo_root, runner, ["status", "--short"]) do
      {:ok, ""} ->
        :ok

      {:ok, output} ->
        {:error, "Planner source repo at #{repo_root} has uncommitted changes. Commit, stash, or discard them before March starts or auto-syncs after merge.\n#{output}"}

      {:error, reason} ->
        {:error, "Failed to inspect git status for #{repo_root}: #{reason}"}
    end
  end

  defp fetch_remote_branch(repo_root, runner, remote, branch) do
    case run_git(repo_root, runner, ["fetch", remote, branch, "--quiet"]) do
      {:ok, _output} ->
        :ok

      {:error, reason} ->
        {:error, "Failed to fetch #{remote}/#{branch} for #{repo_root}: #{reason}"}
    end
  end

  defp ahead_behind_counts(repo_root, runner, remote, branch) do
    case run_git(repo_root, runner, ["rev-list", "--left-right", "--count", "#{remote}/#{branch}...HEAD"]) do
      {:ok, counts} ->
        case String.split(counts) do
          [remote_only, local_only] ->
            with {remote_only_count, ""} <- Integer.parse(remote_only),
                 {local_only_count, ""} <- Integer.parse(local_only) do
              {:ok, remote_only_count, local_only_count}
            else
              _ ->
                {:error, "Failed to parse ahead/behind counts for #{repo_root}: #{inspect(counts)}"}
            end

          _ ->
            {:error, "Unexpected ahead/behind output for #{repo_root}: #{inspect(counts)}"}
        end

      {:error, reason} ->
        {:error, "Failed to compare HEAD with #{remote}/#{branch} for #{repo_root}: #{reason}"}
    end
  end

  defp sync_if_needed(_repo_root, _runner, _remote, _branch, 0, 0), do: {:ok, :up_to_date}

  defp sync_if_needed(repo_root, runner, remote, branch, remote_only_count, 0)
       when remote_only_count > 0 do
    case run_git(repo_root, runner, ["pull", "--ff-only", remote, branch]) do
      {:ok, _output} ->
        {:ok, :pulled}

      {:error, reason} ->
        {:error, "Failed to fast-forward #{repo_root} to #{remote}/#{branch}: #{reason}"}
    end
  end

  defp sync_if_needed(repo_root, _runner, remote, branch, 0, local_only_count)
       when local_only_count > 0 do
    {:error, "Planner source repo at #{repo_root} is ahead of #{remote}/#{branch}. Push or reset it before March starts or auto-syncs after merge."}
  end

  defp sync_if_needed(repo_root, _runner, remote, branch, remote_only_count, local_only_count)
       when remote_only_count > 0 and local_only_count > 0 do
    {:error, "Planner source repo at #{repo_root} has diverged from #{remote}/#{branch}. Reconcile it manually before March starts or auto-syncs after merge."}
  end

  defp run_git(repo_root, runner, args) when is_function(runner, 2) do
    case runner.(repo_root, args) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, status} ->
        rendered_output = String.trim(output)

        {:error,
         "git #{Enum.join(args, " ")} exited #{status}" <>
           if(rendered_output == "", do: "", else: ": #{rendered_output}")}
    end
  end

  defp default_runner(repo_root, args) do
    System.cmd("git", ["-C", repo_root | args], stderr_to_stdout: true)
  end
end
