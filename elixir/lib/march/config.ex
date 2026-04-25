defmodule March.Config do
  @moduledoc """
  Runtime configuration loaded from `MARCH.yml`.
  """

  alias NimbleOptions
  alias March.Workflow

  @default_active_states ["Building", "Merging"]
  @default_builder_states ["Building", "Merging"]
  @default_planner_states ["Planning"]
  @default_auditor_states ["Auditing"]
  @default_terminal_states ["Done", "Cancelled", "Canceled", "Closed", "Duplicate"]
  @default_tracker_kind "feishu_task"
  @default_tracker_identity "user"
  @default_tracker_stage "Backlog"
  @default_task_key_prefix nil
  @default_lark_cli_command "lark-cli"
  @default_lark_cli_timeout_ms 20_000
  @default_comments_cache_ttl_ms 60_000
  @default_task_fetch_max_concurrency 6
  @default_prompt_template """
  You are working on a Feishu task.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}
  Stage: {{ issue.state }}
  Task Kind: {{ issue.task_kind | default: "unspecified" }}

  Body:
  {% if issue.body %}
  {{ issue.body }}
  {% else %}
  No description provided.
  {% endif %}
  """
  @default_poll_interval_ms 30_000
  @default_full_scan_interval_ms 60_000
  @default_idle_full_scan_interval_ms 300_000
  @default_idle_after_empty_full_scans 3
  @default_workspace_root Path.join(System.tmp_dir!(), "march_workspaces")
  @default_hook_timeout_ms 60_000
  @default_max_concurrent_agents 10
  @default_agent_max_turns 20
  @default_max_retry_backoff_ms 300_000
  @default_codex_command "codex app-server"
  @default_codex_turn_timeout_ms 3_600_000
  @default_codex_read_timeout_ms 5_000
  @default_codex_stall_timeout_ms 300_000
  @default_codex_approval_policy %{
    "reject" => %{
      "sandbox_approval" => true,
      "rules" => true,
      "mcp_elicitations" => true
    }
  }
  @default_codex_thread_sandbox "workspace-write"
  @default_observability_enabled true
  @default_observability_refresh_ms 1_000
  @default_observability_render_interval_ms 16
  @default_canonical_branch "testing"
  @workflow_options_schema NimbleOptions.new!(
                             repo: [
                               type: :map,
                               default: %{},
                               keys: [
                                 canonical_branch: [type: :string, default: @default_canonical_branch]
                               ]
                             ],
                             tracker: [
                               type: :map,
                               default: %{},
                               keys: [
                                 kind: [type: {:or, [:string, nil]}, default: nil],
                                 tasklist_guid: [type: {:or, [:string, nil]}, default: nil],
                                 identity: [type: :string, default: @default_tracker_identity],
                                 task_key_prefix: [type: {:or, [:string, nil]}, default: @default_task_key_prefix],
                                 lark_cli_command: [type: :string, default: @default_lark_cli_command],
                                 lark_cli_timeout_ms: [
                                   type: :pos_integer,
                                   default: @default_lark_cli_timeout_ms
                                 ],
                                 comments_cache_ttl_ms: [
                                   type: :pos_integer,
                                   default: @default_comments_cache_ttl_ms
                                 ],
                                 task_fetch_max_concurrency: [
                                   type: :pos_integer,
                                   default: @default_task_fetch_max_concurrency
                                 ],
                                 default_stage: [type: :string, default: @default_tracker_stage],
                                 active_states: [
                                   type: {:list, :string},
                                   default: @default_active_states
                                 ],
                                 builder_states: [
                                   type: {:list, :string},
                                   default: @default_builder_states
                                 ],
                                 planner_states: [
                                   type: {:list, :string},
                                   default: @default_planner_states
                                 ],
                                 auditor_states: [
                                   type: {:list, :string},
                                   default: @default_auditor_states
                                 ],
                                 terminal_states: [
                                   type: {:list, :string},
                                   default: @default_terminal_states
                                 ]
                               ]
                             ],
                             polling: [
                               type: :map,
                               default: %{},
                               keys: [
                                 hot_poll_interval_ms: [type: {:or, [:integer, nil]}, default: nil],
                                 full_scan_interval_ms: [
                                   type: {:or, [:integer, nil]},
                                   default: @default_full_scan_interval_ms
                                 ],
                                 idle_full_scan_interval_ms: [
                                   type: {:or, [:integer, nil]},
                                   default: @default_idle_full_scan_interval_ms
                                 ],
                                 idle_after_empty_full_scans: [
                                   type: {:or, [:integer, nil]},
                                   default: @default_idle_after_empty_full_scans
                                 ]
                               ]
                             ],
                             workspace: [
                               type: :map,
                               default: %{},
                               keys: [
                                 root: [type: {:or, [:string, nil]}, default: @default_workspace_root]
                               ]
                             ],
                             agent: [
                               type: :map,
                               default: %{},
                               keys: [
                                 max_concurrent_agents: [
                                   type: :integer,
                                   default: @default_max_concurrent_agents
                                 ],
                                 max_turns: [
                                   type: :pos_integer,
                                   default: @default_agent_max_turns
                                 ],
                                 max_retry_backoff_ms: [
                                   type: :pos_integer,
                                   default: @default_max_retry_backoff_ms
                                 ],
                                 max_concurrent_agents_by_state: [
                                   type: {:map, :string, :pos_integer},
                                   default: %{}
                                 ]
                               ]
                             ],
                             codex: [
                               type: :map,
                               default: %{},
                               keys: [
                                 command: [type: :string, default: @default_codex_command],
                                 turn_timeout_ms: [
                                   type: :integer,
                                   default: @default_codex_turn_timeout_ms
                                 ],
                                 read_timeout_ms: [
                                   type: :integer,
                                   default: @default_codex_read_timeout_ms
                                 ],
                                 stall_timeout_ms: [
                                   type: :integer,
                                   default: @default_codex_stall_timeout_ms
                                 ]
                               ]
                             ],
                             hooks: [
                               type: :map,
                               default: %{},
                               keys: [
                                 after_create: [type: {:or, [:string, nil]}, default: nil],
                                 before_run: [type: {:or, [:string, nil]}, default: nil],
                                 after_run: [type: {:or, [:string, nil]}, default: nil],
                                 before_remove: [type: {:or, [:string, nil]}, default: nil],
                                 timeout_ms: [type: :pos_integer, default: @default_hook_timeout_ms]
                               ]
                             ],
                             observability: [
                               type: :map,
                               default: %{},
                               keys: [
                                 enabled: [
                                   type: :boolean,
                                   default: @default_observability_enabled
                                 ],
                                 refresh_ms: [
                                   type: :integer,
                                   default: @default_observability_refresh_ms
                                 ],
                                 render_interval_ms: [
                                   type: :integer,
                                   default: @default_observability_render_interval_ms
                                 ]
                               ]
                             ]
                           )

  @type workflow_payload :: Workflow.loaded_workflow()
  @type tracker_kind :: String.t() | nil
  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }
  @type workspace_hooks :: %{
          after_create: String.t() | nil,
          before_run: String.t() | nil,
          after_run: String.t() | nil,
          before_remove: String.t() | nil,
          timeout_ms: pos_integer()
        }

  @spec current_workflow() :: {:ok, workflow_payload()} | {:error, term()}
  def current_workflow do
    Workflow.current()
  end

  @spec canonical_branch() :: String.t()
  def canonical_branch do
    validated_workflow_options()
    |> get_in([:repo, :canonical_branch])
    |> scalar_or_default(@default_canonical_branch)
  end

  @spec tracker_kind() :: tracker_kind()
  def tracker_kind do
    get_in(validated_workflow_options(), [:tracker, :kind])
  end

  @spec feishu_tasklist_guid() :: String.t() | nil
  def feishu_tasklist_guid do
    validated_workflow_options()
    |> get_in([:tracker, :tasklist_guid])
    |> resolve_env_value(System.get_env("FEISHU_TASKLIST_GUID"))
    |> normalize_secret_value()
  end

  @spec feishu_identity() :: String.t()
  def feishu_identity do
    validated_workflow_options()
    |> get_in([:tracker, :identity])
    |> scalar_or_default(@default_tracker_identity)
  end

  @spec lark_cli_command() :: String.t()
  def lark_cli_command do
    validated_workflow_options()
    |> get_in([:tracker, :lark_cli_command])
    |> scalar_or_default(@default_lark_cli_command)
  end

  @spec lark_cli_timeout_ms() :: pos_integer()
  def lark_cli_timeout_ms do
    validated_workflow_options()
    |> get_in([:tracker, :lark_cli_timeout_ms])
    |> case do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> @default_lark_cli_timeout_ms
    end
  end

  @spec feishu_task_key_prefix() :: String.t() | nil
  def feishu_task_key_prefix do
    validated_workflow_options()
    |> get_in([:tracker, :task_key_prefix])
    |> normalize_secret_value()
  end

  @spec default_tracker_stage() :: String.t()
  def default_tracker_stage do
    validated_workflow_options()
    |> get_in([:tracker, :default_stage])
    |> scalar_or_default(@default_tracker_stage)
  end

  @spec feishu_comments_cache_ttl_ms() :: pos_integer()
  def feishu_comments_cache_ttl_ms do
    validated_workflow_options()
    |> get_in([:tracker, :comments_cache_ttl_ms])
    |> case do
      ttl when is_integer(ttl) and ttl > 0 -> ttl
      _ -> @default_comments_cache_ttl_ms
    end
  end

  @spec feishu_task_fetch_max_concurrency() :: pos_integer()
  def feishu_task_fetch_max_concurrency do
    validated_workflow_options()
    |> get_in([:tracker, :task_fetch_max_concurrency])
    |> case do
      value when is_integer(value) and value > 0 -> value
      _ -> @default_task_fetch_max_concurrency
    end
  end

  @spec active_states() :: [String.t()]
  def active_states do
    builder_states()
  end

  @spec builder_states() :: [String.t()]
  def builder_states do
    builder_states = get_in(validated_workflow_options(), [:tracker, :builder_states])

    if builder_states == [] do
      get_in(validated_workflow_options(), [:tracker, :active_states])
    else
      builder_states
    end
  end

  @spec planner_states() :: [String.t()]
  def planner_states do
    get_in(validated_workflow_options(), [:tracker, :planner_states])
  end

  @spec auditor_states() :: [String.t()]
  def auditor_states do
    get_in(validated_workflow_options(), [:tracker, :auditor_states])
  end

  @spec automation_states() :: [String.t()]
  def automation_states do
    [
      builder_states(),
      planner_states(),
      auditor_states()
    ]
    |> List.flatten()
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  @spec issue_role(term()) :: :builder | :planner | :auditor | nil
  def issue_role(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    cond do
      normalized_state in Enum.map(builder_states(), &normalize_issue_state/1) -> :builder
      normalized_state in Enum.map(planner_states(), &normalize_issue_state/1) -> :planner
      normalized_state in Enum.map(auditor_states(), &normalize_issue_state/1) -> :auditor
      true -> nil
    end
  end

  def issue_role(_state_name), do: nil

  @spec automation_issue_state?(term()) :: boolean()
  def automation_issue_state?(state_name) when is_binary(state_name) do
    issue_role(state_name) != nil
  end

  def automation_issue_state?(_state_name), do: false

  @spec role_workflow(term()) :: {:ok, workflow_payload()} | {:error, term()}
  def role_workflow(:builder), do: Workflow.current()
  def role_workflow(:planner), do: Workflow.planner_current()
  def role_workflow(:auditor), do: Workflow.auditor_current()
  def role_workflow(_role), do: Workflow.current()

  @spec role_states(:builder | :planner | :auditor) :: [String.t()]
  def role_states(:builder), do: builder_states()
  def role_states(:planner), do: planner_states()
  def role_states(:auditor), do: auditor_states()

  def role_states(_role), do: []

  @spec terminal_states() :: [String.t()]
  def terminal_states do
    get_in(validated_workflow_options(), [:tracker, :terminal_states])
  end

  @spec poll_interval_ms() :: pos_integer()
  def poll_interval_ms do
    hot_poll_interval_ms()
  end

  @spec hot_poll_interval_ms() :: pos_integer()
  def hot_poll_interval_ms do
    polling = get_in(validated_workflow_options(), [:polling])

    case Map.get(polling, :hot_poll_interval_ms) do
      interval when is_integer(interval) and interval > 0 -> interval
      _ -> @default_poll_interval_ms
    end
  end

  @spec full_scan_interval_ms() :: pos_integer()
  def full_scan_interval_ms do
    validated_workflow_options()
    |> get_in([:polling, :full_scan_interval_ms])
    |> case do
      interval when is_integer(interval) and interval > 0 -> interval
      _ -> @default_full_scan_interval_ms
    end
  end

  @spec idle_full_scan_interval_ms() :: pos_integer()
  def idle_full_scan_interval_ms do
    validated_workflow_options()
    |> get_in([:polling, :idle_full_scan_interval_ms])
    |> case do
      interval when is_integer(interval) and interval > 0 -> interval
      _ -> @default_idle_full_scan_interval_ms
    end
  end

  @spec idle_after_empty_full_scans() :: pos_integer()
  def idle_after_empty_full_scans do
    validated_workflow_options()
    |> get_in([:polling, :idle_after_empty_full_scans])
    |> case do
      value when is_integer(value) and value > 0 -> value
      _ -> @default_idle_after_empty_full_scans
    end
  end

  @spec workspace_root() :: Path.t()
  def workspace_root do
    validated_workflow_options()
    |> get_in([:workspace, :root])
    |> resolve_path_value(@default_workspace_root)
  end

  @spec workspace_hooks() :: workspace_hooks()
  def workspace_hooks do
    hooks = get_in(validated_workflow_options(), [:hooks])

    %{
      after_create: Map.get(hooks, :after_create),
      before_run: Map.get(hooks, :before_run),
      after_run: Map.get(hooks, :after_run),
      before_remove: Map.get(hooks, :before_remove),
      timeout_ms: Map.get(hooks, :timeout_ms)
    }
  end

  @spec hook_timeout_ms() :: pos_integer()
  def hook_timeout_ms do
    get_in(validated_workflow_options(), [:hooks, :timeout_ms])
  end

  @spec max_concurrent_agents() :: pos_integer()
  def max_concurrent_agents do
    get_in(validated_workflow_options(), [:agent, :max_concurrent_agents])
  end

  @spec max_retry_backoff_ms() :: pos_integer()
  def max_retry_backoff_ms do
    get_in(validated_workflow_options(), [:agent, :max_retry_backoff_ms])
  end

  @spec agent_max_turns() :: pos_integer()
  def agent_max_turns do
    get_in(validated_workflow_options(), [:agent, :max_turns])
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    state_limits = get_in(validated_workflow_options(), [:agent, :max_concurrent_agents_by_state])
    global_limit = max_concurrent_agents()
    Map.get(state_limits, normalize_issue_state(state_name), global_limit)
  end

  def max_concurrent_agents_for_state(_state_name), do: max_concurrent_agents()

  @spec codex_command() :: String.t()
  def codex_command do
    get_in(validated_workflow_options(), [:codex, :command])
  end

  @spec codex_turn_timeout_ms() :: pos_integer()
  def codex_turn_timeout_ms do
    get_in(validated_workflow_options(), [:codex, :turn_timeout_ms])
  end

  @spec codex_approval_policy() :: String.t() | map()
  def codex_approval_policy do
    case resolve_codex_approval_policy() do
      {:ok, approval_policy} -> approval_policy
      {:error, _reason} -> @default_codex_approval_policy
    end
  end

  @spec codex_thread_sandbox() :: String.t()
  def codex_thread_sandbox do
    case resolve_codex_thread_sandbox() do
      {:ok, thread_sandbox} -> thread_sandbox
      {:error, _reason} -> @default_codex_thread_sandbox
    end
  end

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case resolve_codex_turn_sandbox_policy(workspace) do
      {:ok, turn_sandbox_policy} -> turn_sandbox_policy
      {:error, _reason} -> default_codex_turn_sandbox_policy(workspace)
    end
  end

  @spec codex_read_timeout_ms() :: pos_integer()
  def codex_read_timeout_ms do
    get_in(validated_workflow_options(), [:codex, :read_timeout_ms])
  end

  @spec codex_stall_timeout_ms() :: non_neg_integer()
  def codex_stall_timeout_ms do
    validated_workflow_options()
    |> get_in([:codex, :stall_timeout_ms])
    |> max(0)
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case current_workflow() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec observability_enabled?() :: boolean()
  def observability_enabled? do
    get_in(validated_workflow_options(), [:observability, :enabled])
  end

  @spec observability_refresh_ms() :: pos_integer()
  def observability_refresh_ms do
    get_in(validated_workflow_options(), [:observability, :refresh_ms])
  end

  @spec observability_render_interval_ms() :: pos_integer()
  def observability_render_interval_ms do
    get_in(validated_workflow_options(), [:observability, :render_interval_ms])
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, _workflow} <- current_workflow(),
         :ok <- require_tracker_kind(),
         :ok <- require_feishu_tasklist(),
         :ok <- require_valid_codex_runtime_settings() do
      require_codex_command()
    end
  end

  @spec codex_runtime_settings(Path.t() | nil) :: {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil) do
    with {:ok, approval_policy} <- resolve_codex_approval_policy(),
         {:ok, thread_sandbox} <- resolve_codex_thread_sandbox(),
         {:ok, turn_sandbox_policy} <- resolve_codex_turn_sandbox_policy(workspace) do
      {:ok,
       %{
         approval_policy: approval_policy,
         thread_sandbox: thread_sandbox,
         turn_sandbox_policy: turn_sandbox_policy
       }}
    end
  end

  defp require_tracker_kind do
    case tracker_kind() do
      "feishu_task" -> :ok
      "memory" -> :ok
      nil -> {:error, :missing_tracker_kind}
      other -> {:error, {:unsupported_tracker_kind, other}}
    end
  end

  defp require_feishu_tasklist do
    case tracker_kind() do
      "feishu_task" ->
        if is_binary(feishu_tasklist_guid()) do
          :ok
        else
          {:error, :missing_feishu_tasklist_guid}
        end

      _ ->
        :ok
    end
  end

  defp require_codex_command do
    if byte_size(String.trim(codex_command())) > 0 do
      :ok
    else
      {:error, :missing_codex_command}
    end
  end

  defp require_valid_codex_runtime_settings do
    case codex_runtime_settings() do
      {:ok, _settings} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validated_workflow_options do
    workflow_config()
    |> extract_workflow_options()
    |> NimbleOptions.validate!(@workflow_options_schema)
  end

  defp extract_workflow_options(config) do
    %{
      repo: extract_repo_options(section_map(config, "repo")),
      tracker: extract_tracker_options(section_map(config, "tracker")),
      polling: extract_polling_options(section_map(config, "polling")),
      workspace: extract_workspace_options(section_map(config, "workspace")),
      agent: extract_agent_options(section_map(config, "agent")),
      codex: extract_codex_options(section_map(config, "codex")),
      hooks: extract_hooks_options(section_map(config, "hooks")),
      observability: extract_observability_options(section_map(config, "observability"))
    }
  end

  defp extract_repo_options(section) do
    %{}
    |> put_if_present(:canonical_branch, scalar_string_value(Map.get(section, "canonical_branch")))
  end

  defp extract_tracker_options(section) do
    %{}
    |> put_if_present(:kind, normalize_tracker_kind(scalar_string_value(Map.get(section, "kind"))) || @default_tracker_kind)
    |> put_if_present(:tasklist_guid, scalar_string_value(Map.get(section, "tasklist_guid")))
    |> put_if_present(:identity, scalar_string_value(Map.get(section, "identity")))
    |> put_if_present(:task_key_prefix, scalar_string_value(Map.get(section, "task_key_prefix")))
    |> put_if_present(:lark_cli_command, scalar_string_value(Map.get(section, "lark_cli_command")))
    |> put_if_present(:lark_cli_timeout_ms, positive_integer_value(Map.get(section, "lark_cli_timeout_ms")))
    |> put_if_present(:comments_cache_ttl_ms, positive_integer_value(Map.get(section, "comments_cache_ttl_ms")))
    |> put_if_present(:task_fetch_max_concurrency, positive_integer_value(Map.get(section, "task_fetch_max_concurrency")))
    |> put_if_present(:default_stage, scalar_string_value(Map.get(section, "default_stage")))
    |> put_if_present(:active_states, csv_value(Map.get(section, "active_states")))
    |> put_if_present(:builder_states, csv_value(Map.get(section, "builder_states")))
    |> put_if_present(:planner_states, csv_value(Map.get(section, "planner_states")))
    |> put_if_present(:auditor_states, csv_value(Map.get(section, "auditor_states")))
    |> put_if_present(:terminal_states, csv_value(Map.get(section, "terminal_states")))
  end

  defp scalar_or_default(value, default) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: default, else: trimmed
  end

  defp scalar_or_default(_value, default), do: default

  defp extract_polling_options(section) do
    %{}
    |> put_if_present(:hot_poll_interval_ms, integer_value(Map.get(section, "hot_poll_interval_ms")))
    |> put_if_present(:full_scan_interval_ms, integer_value(Map.get(section, "full_scan_interval_ms")))
    |> put_if_present(
      :idle_full_scan_interval_ms,
      integer_value(Map.get(section, "idle_full_scan_interval_ms"))
    )
    |> put_if_present(
      :idle_after_empty_full_scans,
      integer_value(Map.get(section, "idle_after_empty_full_scans"))
    )
  end

  defp extract_workspace_options(section) do
    %{}
    |> put_if_present(:root, binary_value(Map.get(section, "root")))
  end

  defp extract_agent_options(section) do
    %{}
    |> put_if_present(:max_concurrent_agents, integer_value(Map.get(section, "max_concurrent_agents")))
    |> put_if_present(:max_turns, positive_integer_value(Map.get(section, "max_turns")))
    |> put_if_present(:max_retry_backoff_ms, positive_integer_value(Map.get(section, "max_retry_backoff_ms")))
    |> put_if_present(
      :max_concurrent_agents_by_state,
      state_limits_value(Map.get(section, "max_concurrent_agents_by_state"))
    )
  end

  defp extract_codex_options(section) do
    %{}
    |> put_if_present(:command, command_value(Map.get(section, "command")))
    |> put_if_present(:turn_timeout_ms, integer_value(Map.get(section, "turn_timeout_ms")))
    |> put_if_present(:read_timeout_ms, integer_value(Map.get(section, "read_timeout_ms")))
    |> put_if_present(:stall_timeout_ms, integer_value(Map.get(section, "stall_timeout_ms")))
  end

  defp extract_hooks_options(section) do
    %{}
    |> put_if_present(:after_create, hook_command_value(Map.get(section, "after_create")))
    |> put_if_present(:before_run, hook_command_value(Map.get(section, "before_run")))
    |> put_if_present(:after_run, hook_command_value(Map.get(section, "after_run")))
    |> put_if_present(:before_remove, hook_command_value(Map.get(section, "before_remove")))
    |> put_if_present(:timeout_ms, positive_integer_value(Map.get(section, "timeout_ms")))
  end

  defp extract_observability_options(section) do
    %{}
    |> put_if_present(:enabled, boolean_value(Map.get(section, "enabled")))
    |> put_if_present(:refresh_ms, integer_value(Map.get(section, "refresh_ms")))
    |> put_if_present(:render_interval_ms, integer_value(Map.get(section, "render_interval_ms")))
  end

  defp section_map(config, key) do
    case Map.get(config, key) do
      section when is_map(section) -> section
      _ -> %{}
    end
  end

  defp put_if_present(map, _key, :omit), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp scalar_string_value(nil), do: :omit
  defp scalar_string_value(value) when is_binary(value), do: String.trim(value)
  defp scalar_string_value(value) when is_boolean(value), do: to_string(value)
  defp scalar_string_value(value) when is_integer(value), do: to_string(value)
  defp scalar_string_value(value) when is_float(value), do: to_string(value)
  defp scalar_string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp scalar_string_value(_value), do: :omit

  defp binary_value(value, opts \\ [])

  defp binary_value(value, opts) when is_binary(value) do
    allow_empty = Keyword.get(opts, :allow_empty, false)

    if value == "" and not allow_empty do
      :omit
    else
      value
    end
  end

  defp binary_value(_value, _opts), do: :omit

  defp command_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :omit
      trimmed -> trimmed
    end
  end

  defp command_value(_value), do: :omit

  defp hook_command_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :omit
      _ -> String.trim_trailing(value)
    end
  end

  defp hook_command_value(_value), do: :omit

  defp csv_value(values) when is_list(values) do
    values
    |> Enum.reduce([], fn value, acc -> maybe_append_csv_value(acc, value) end)
    |> Enum.reverse()
    |> case do
      [] -> :omit
      normalized_values -> normalized_values
    end
  end

  defp csv_value(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> :omit
      normalized_values -> normalized_values
    end
  end

  defp csv_value(_value), do: :omit

  defp maybe_append_csv_value(acc, value) do
    case scalar_string_value(value) do
      :omit ->
        acc

      normalized ->
        append_csv_value_if_present(acc, normalized)
    end
  end

  defp append_csv_value_if_present(acc, value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      acc
    else
      [trimmed | acc]
    end
  end

  defp integer_value(value) do
    case parse_integer(value) do
      {:ok, parsed} -> parsed
      :error -> :omit
    end
  end

  defp positive_integer_value(value) do
    case parse_positive_integer(value) do
      {:ok, parsed} -> parsed
      :error -> :omit
    end
  end

  defp boolean_value(value) when is_boolean(value), do: value

  defp boolean_value(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> true
      "false" -> false
      _ -> :omit
    end
  end

  defp boolean_value(_value), do: :omit

  defp state_limits_value(value) when is_map(value) do
    value
    |> Enum.reduce(%{}, fn {state_name, limit}, acc ->
      case parse_positive_integer(limit) do
        {:ok, parsed} ->
          Map.put(acc, normalize_issue_state(to_string(state_name)), parsed)

        :error ->
          acc
      end
    end)
  end

  defp state_limits_value(_value), do: :omit

  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> {:ok, parsed}
      :error -> :error
    end
  end

  defp parse_integer(_value), do: :error

  defp parse_positive_integer(value) do
    case parse_integer(value) do
      {:ok, parsed} when parsed > 0 -> {:ok, parsed}
      _ -> :error
    end
  end

  defp fetch_value(paths, default) do
    config = workflow_config()

    case resolve_config_value(config, paths) do
      :missing -> default
      value -> value
    end
  end

  defp resolve_codex_approval_policy do
    case fetch_value([["codex", "approval_policy"]], :missing) do
      :missing ->
        {:ok, @default_codex_approval_policy}

      nil ->
        {:ok, @default_codex_approval_policy}

      value when is_binary(value) ->
        approval_policy = String.trim(value)

        if approval_policy == "" do
          {:error, {:invalid_codex_approval_policy, value}}
        else
          {:ok, approval_policy}
        end

      value when is_map(value) ->
        {:ok, value}

      value ->
        {:error, {:invalid_codex_approval_policy, value}}
    end
  end

  defp resolve_codex_thread_sandbox do
    case fetch_value([["codex", "thread_sandbox"]], :missing) do
      :missing ->
        {:ok, @default_codex_thread_sandbox}

      nil ->
        {:ok, @default_codex_thread_sandbox}

      value when is_binary(value) ->
        thread_sandbox = String.trim(value)

        if thread_sandbox == "" do
          {:error, {:invalid_codex_thread_sandbox, value}}
        else
          {:ok, thread_sandbox}
        end

      value ->
        {:error, {:invalid_codex_thread_sandbox, value}}
    end
  end

  defp resolve_codex_turn_sandbox_policy(workspace) do
    case fetch_value([["codex", "turn_sandbox_policy"]], :missing) do
      :missing ->
        {:ok, default_codex_turn_sandbox_policy(workspace)}

      nil ->
        {:ok, default_codex_turn_sandbox_policy(workspace)}

      value when is_map(value) ->
        {:ok, value}

      value ->
        {:error, {:invalid_codex_turn_sandbox_policy, {:unsupported_value, value}}}
    end
  end

  defp default_codex_turn_sandbox_policy(workspace) do
    writable_root =
      if is_binary(workspace) and String.trim(workspace) != "" do
        Path.expand(workspace)
      else
        Path.expand(workspace_root())
      end

    %{
      "type" => "workspaceWrite",
      "writableRoots" => [writable_root],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_tracker_kind(kind) when is_binary(kind) do
    kind
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_tracker_kind(_kind), do: nil

  defp workflow_config do
    case current_workflow() do
      {:ok, %{config: config}} when is_map(config) ->
        normalize_keys(config)

      _ ->
        %{}
    end
  end

  defp resolve_config_value(%{} = config, paths) do
    Enum.reduce_while(paths, :missing, fn path, _acc ->
      case get_in_path(config, path) do
        :missing -> {:cont, :missing}
        value -> {:halt, value}
      end
    end)
  end

  defp get_in_path(config, path) when is_list(path) and is_map(config) do
    get_in_path(config, path, 0)
  end

  defp get_in_path(_, _), do: :missing

  defp get_in_path(config, [], _depth), do: config

  defp get_in_path(%{} = current, [segment | rest], _depth) do
    case Map.fetch(current, normalize_key(segment)) do
      {:ok, value} -> get_in_path(value, rest, 0)
      :error -> :missing
    end
  end

  defp get_in_path(_, _, _depth), do: :missing

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp resolve_path_value(:missing, default), do: default
  defp resolve_path_value(nil, default), do: default

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      path ->
        path
        |> String.trim()
        |> preserve_command_name()
        |> then(fn
          "" -> default
          resolved -> resolved
        end)
    end
  end

  defp resolve_path_value(_value, default), do: default

  defp preserve_command_name(path) do
    cond do
      uri_path?(path) ->
        path

      String.contains?(path, "/") or String.contains?(path, "\\") ->
        Path.expand(path)

      true ->
        path
    end
  end

  defp uri_path?(path) do
    String.match?(to_string(path), ~r/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//)
  end

  defp resolve_env_value(:missing, fallback), do: fallback
  defp resolve_env_value(nil, fallback), do: fallback

  defp resolve_env_value(value, fallback) when is_binary(value) do
    trimmed = String.trim(value)

    case env_reference_name(trimmed) do
      {:ok, env_name} ->
        env_name
        |> System.get_env()
        |> then(fn
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end)

      :error ->
        trimmed
    end
  end

  defp resolve_env_value(_value, fallback), do: fallback

  defp normalize_path_token(value) when is_binary(value) do
    trimmed = String.trim(value)

    case env_reference_name(trimmed) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> trimmed
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(value) do
    case System.get_env(value) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_secret_value(_value), do: nil
end
