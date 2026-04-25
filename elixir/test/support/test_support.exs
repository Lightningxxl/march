defmodule March.TestSupport do
  @workflow_prompt "You are an agent for this repository."
  @planner_prompt "You are the planner agent for this repository."
  @auditor_prompt "You are the auditor agent for this repository."

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case
      import ExUnit.CaptureLog

      alias March.AgentRunner
      alias March.CLI
      alias March.Codex.AppServer
      alias March.Config
      alias March.Orchestrator
      alias March.PromptBuilder
      alias March.StatusDashboard
      alias March.Tracker
      alias March.Tracker.Item, as: Issue
      alias March.Workflow
      alias March.WorkflowStore
      alias March.Workspace

      import March.TestSupport,
        only: [write_workflow_file!: 1, write_workflow_file!: 2, restore_env: 2]

      setup do
        workflow_root =
          Path.join(
            System.tmp_dir!(),
            "march-workflow-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(workflow_root)
        workflow_file = Path.join(workflow_root, "BUILDER.md")
        write_workflow_file!(workflow_file)
        Workflow.set_repo_root(workflow_root)
        if Process.whereis(March.WorkflowStore), do: March.WorkflowStore.force_reload()

        on_exit(fn ->
          Application.delete_env(:march, :config_file_path)
          Application.delete_env(:march, :workflow_file_path)
          Application.delete_env(:march, :planner_file_path)
          Application.delete_env(:march, :auditor_file_path)
          Application.delete_env(:march, :repo_root)
          Application.delete_env(:march, :memory_tracker_issues)
          Application.delete_env(:march, :memory_tracker_recipient)
          File.rm_rf(workflow_root)
        end)

        :ok
      end
    end
  end

  def write_workflow_file!(path, overrides \\ []) do
    File.write!(Path.join(Path.dirname(path), "MARCH.yml"), workflow_config_content(overrides))
    File.write!(path, workflow_prompt_content(overrides))
    write_planner_file!(Path.join(Path.dirname(path), "PLANNER.md"), overrides)
    write_auditor_file!(Path.join(Path.dirname(path), "AUDITOR.md"), overrides)

    if Process.whereis(March.WorkflowStore) do
      try do
        March.WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  defp write_planner_file!(path, overrides) do
    planner_prompt = Keyword.get(overrides, :planner_prompt, @planner_prompt)
    File.write!(path, planner_prompt <> "\n")
  end

  defp write_auditor_file!(path, overrides) do
    auditor_prompt = Keyword.get(overrides, :auditor_prompt, @auditor_prompt)
    File.write!(path, auditor_prompt <> "\n")
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  defp workflow_config_content(overrides) do
    config =
      Keyword.merge(
        [
          repo_canonical_branch: "testing",
          tracker_kind: "memory",
          tracker_tasklist_guid: nil,
          tracker_identity: "user",
          tracker_lark_cli_command: "lark-cli",
          tracker_comments_cache_ttl_ms: 60_000,
          tracker_task_fetch_max_concurrency: 6,
          tracker_default_stage: "Backlog",
          tracker_active_states: ["Building", "Merging"],
          tracker_builder_states: ["Building", "Merging"],
          tracker_planner_states: ["Planning"],
          tracker_auditor_states: ["Auditing"],
          tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
          hot_poll_interval_ms: 30_000,
          full_scan_interval_ms: 60_000,
          idle_full_scan_interval_ms: 300_000,
          idle_after_empty_full_scans: 3,
          workspace_root: Path.join(System.tmp_dir!(), "march_workspaces"),
          max_concurrent_agents: 10,
          max_turns: 20,
          max_retry_backoff_ms: 300_000,
          max_concurrent_agents_by_state: %{},
          codex_command: "codex app-server",
          codex_approval_policy: %{reject: %{sandbox_approval: true, rules: true, mcp_elicitations: true}},
          codex_thread_sandbox: "workspace-write",
          codex_turn_sandbox_policy: nil,
          codex_turn_timeout_ms: 3_600_000,
          codex_read_timeout_ms: 5_000,
          codex_stall_timeout_ms: 300_000,
          hook_after_create: nil,
          hook_before_run: nil,
          hook_after_run: nil,
          hook_before_remove: nil,
          hook_timeout_ms: 60_000,
          observability_enabled: false,
          observability_refresh_ms: 1_000,
          observability_render_interval_ms: 16
        ],
        overrides
      )

    repo_canonical_branch = Keyword.get(config, :repo_canonical_branch)
    tracker_kind = Keyword.get(config, :tracker_kind)
    tracker_tasklist_guid = Keyword.get(config, :tracker_tasklist_guid)
    tracker_identity = Keyword.get(config, :tracker_identity)
    tracker_lark_cli_command = Keyword.get(config, :tracker_lark_cli_command)
    tracker_comments_cache_ttl_ms = Keyword.get(config, :tracker_comments_cache_ttl_ms)
    tracker_task_fetch_max_concurrency = Keyword.get(config, :tracker_task_fetch_max_concurrency)
    tracker_default_stage = Keyword.get(config, :tracker_default_stage)
    tracker_active_states = Keyword.get(config, :tracker_active_states)
    tracker_builder_states = Keyword.get(config, :tracker_builder_states)
    tracker_planner_states = Keyword.get(config, :tracker_planner_states)
    tracker_auditor_states = Keyword.get(config, :tracker_auditor_states)
    tracker_terminal_states = Keyword.get(config, :tracker_terminal_states)
    hot_poll_interval_ms = Keyword.get(config, :hot_poll_interval_ms)
    full_scan_interval_ms = Keyword.get(config, :full_scan_interval_ms)
    idle_full_scan_interval_ms = Keyword.get(config, :idle_full_scan_interval_ms)
    idle_after_empty_full_scans = Keyword.get(config, :idle_after_empty_full_scans)
    workspace_root = Keyword.get(config, :workspace_root)
    max_concurrent_agents = Keyword.get(config, :max_concurrent_agents)
    max_turns = Keyword.get(config, :max_turns)
    max_retry_backoff_ms = Keyword.get(config, :max_retry_backoff_ms)
    max_concurrent_agents_by_state = Keyword.get(config, :max_concurrent_agents_by_state)
    codex_command = Keyword.get(config, :codex_command)
    codex_approval_policy = Keyword.get(config, :codex_approval_policy)
    codex_thread_sandbox = Keyword.get(config, :codex_thread_sandbox)
    codex_turn_sandbox_policy = Keyword.get(config, :codex_turn_sandbox_policy)
    codex_turn_timeout_ms = Keyword.get(config, :codex_turn_timeout_ms)
    codex_read_timeout_ms = Keyword.get(config, :codex_read_timeout_ms)
    codex_stall_timeout_ms = Keyword.get(config, :codex_stall_timeout_ms)
    hook_after_create = Keyword.get(config, :hook_after_create)
    hook_before_run = Keyword.get(config, :hook_before_run)
    hook_after_run = Keyword.get(config, :hook_after_run)
    hook_before_remove = Keyword.get(config, :hook_before_remove)
    hook_timeout_ms = Keyword.get(config, :hook_timeout_ms)
    observability_enabled = Keyword.get(config, :observability_enabled)
    observability_refresh_ms = Keyword.get(config, :observability_refresh_ms)
    observability_render_interval_ms = Keyword.get(config, :observability_render_interval_ms)

    sections =
      [
        "repo:",
        "  canonical_branch: #{yaml_value(repo_canonical_branch)}",
        "tracker:",
        "  kind: #{yaml_value(tracker_kind)}",
        "  tasklist_guid: #{yaml_value(tracker_tasklist_guid)}",
        "  identity: #{yaml_value(tracker_identity)}",
        "  lark_cli_command: #{yaml_value(tracker_lark_cli_command)}",
        "  comments_cache_ttl_ms: #{yaml_value(tracker_comments_cache_ttl_ms)}",
        "  task_fetch_max_concurrency: #{yaml_value(tracker_task_fetch_max_concurrency)}",
        "  default_stage: #{yaml_value(tracker_default_stage)}",
        "  active_states: #{yaml_value(tracker_active_states)}",
        "  builder_states: #{yaml_value(tracker_builder_states)}",
        "  planner_states: #{yaml_value(tracker_planner_states)}",
        "  auditor_states: #{yaml_value(tracker_auditor_states)}",
        "  terminal_states: #{yaml_value(tracker_terminal_states)}",
        "polling:",
        "  hot_poll_interval_ms: #{yaml_value(hot_poll_interval_ms)}",
        "  full_scan_interval_ms: #{yaml_value(full_scan_interval_ms)}",
        "  idle_full_scan_interval_ms: #{yaml_value(idle_full_scan_interval_ms)}",
        "  idle_after_empty_full_scans: #{yaml_value(idle_after_empty_full_scans)}",
        "workspace:",
        "  root: #{yaml_value(workspace_root)}",
        "agent:",
        "  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
        "  max_turns: #{yaml_value(max_turns)}",
        "  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
        "  max_concurrent_agents_by_state: #{yaml_value(max_concurrent_agents_by_state)}",
        "codex:",
        "  command: #{yaml_value(codex_command)}",
        "  approval_policy: #{yaml_value(codex_approval_policy)}",
        "  thread_sandbox: #{yaml_value(codex_thread_sandbox)}",
        "  turn_sandbox_policy: #{yaml_value(codex_turn_sandbox_policy)}",
        "  turn_timeout_ms: #{yaml_value(codex_turn_timeout_ms)}",
        "  read_timeout_ms: #{yaml_value(codex_read_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(codex_stall_timeout_ms)}",
        hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, hook_timeout_ms),
        observability_yaml(observability_enabled, observability_refresh_ms, observability_render_interval_ms)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(sections, "\n") <> "\n"
  end

  defp workflow_prompt_content(overrides) do
    Keyword.get(overrides, :prompt, @workflow_prompt) <> "\n"
  end

  defp yaml_value(value) when is_binary(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end

  defp yaml_value(value) when is_integer(value), do: to_string(value)
  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(nil), do: "null"

  defp yaml_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"
  end

  defp yaml_value(values) when is_map(values) do
    "{" <>
      Enum.map_join(values, ", ", fn {key, value} ->
        "#{yaml_value(to_string(key))}: #{yaml_value(value)}"
      end) <> "}"
  end

  defp yaml_value(value), do: yaml_value(to_string(value))

  defp hooks_yaml(nil, nil, nil, nil, timeout_ms), do: "hooks:\n  timeout_ms: #{yaml_value(timeout_ms)}"

  defp hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, timeout_ms) do
    [
      "hooks:",
      "  timeout_ms: #{yaml_value(timeout_ms)}",
      hook_entry("after_create", hook_after_create),
      hook_entry("before_run", hook_before_run),
      hook_entry("after_run", hook_after_run),
      hook_entry("before_remove", hook_before_remove)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp observability_yaml(enabled, refresh_ms, render_interval_ms) do
    [
      "observability:",
      "  enabled: #{yaml_value(enabled)}",
      "  refresh_ms: #{yaml_value(refresh_ms)}",
      "  render_interval_ms: #{yaml_value(render_interval_ms)}"
    ]
    |> Enum.join("\n")
  end

  defp hook_entry(_name, nil), do: nil

  defp hook_entry(name, command) when is_binary(command) do
    indented =
      command
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    "  #{name}: |\n#{indented}"
  end
end
