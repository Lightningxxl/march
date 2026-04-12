defmodule March.Feishu.TaskState do
  @moduledoc """
  Durable machine-owned state stored in `task.extra`.

  Canonical planner/builder/auditor artifacts live in Feishu task custom fields.
  The task extra only stores March metadata such as processed fingerprints.
  """

  alias March.Tracker.Item

  @schema_version 1

  @type state_map :: %{
          optional(String.t()) => term()
        }

  @building_stage "building"
  @planning_stage "planning"
  @auditing_stage "auditing"
  @merging_stage "merging"
  @builder_role "builder"
  @planner_review_role "planner_review"
  @builder_pickup_phase "pickup"
  @builder_execute_phase "execute"
  @builder_rework_phase "rework"
  @planner_review_phase "review"

  @spec parse(String.t() | nil) :: state_map()
  def parse(nil), do: default_state()

  def parse(extra) when is_binary(extra) do
    case Jason.decode(extra) do
      {:ok, %{} = payload} ->
        payload
        |> Map.put_new("schema_version", @schema_version)
        |> Map.put_new("meta", %{})
        |> Map.put_new("workflow", %{})
        |> Map.take(["schema_version", "meta", "workflow"])

      _ ->
        default_state()
    end
  end

  @spec serialize(state_map()) :: String.t()
  def serialize(%{} = state) do
    state
    |> Map.put("schema_version", @schema_version)
    |> Map.put_new("meta", %{})
    |> Map.put_new("workflow", %{})
    |> Map.take(["schema_version", "meta", "workflow"])
    |> Jason.encode!(pretty: true)
  end

  @spec role_for_issue(Item.t()) :: :builder | :planner | :auditor | nil
  def role_for_issue(%Item{state: state_name} = issue) when is_binary(state_name) do
    case normalize_stage(state_name) do
      @planning_stage ->
        :planner

      @building_stage ->
        if building_active_role(issue) == @planner_review_role, do: :planner, else: :builder

      @auditing_stage ->
        :auditor

      @merging_stage ->
        :builder

      _ ->
        nil
    end
  end

  def role_for_issue(_issue), do: nil

  @spec builder_mode(Item.t()) :: String.t()
  def builder_mode(%Item{state: state_name} = issue) when is_binary(state_name) do
    case normalize_stage(state_name) do
      @merging_stage ->
        "merge"

      @building_stage ->
        case building_phase(issue) do
          @builder_pickup_phase -> "pickup"
          @builder_rework_phase -> "rework"
          @planner_review_phase -> "execute"
          _ -> default_builder_mode(issue)
        end

      _ ->
        default_builder_mode(issue)
    end
  end

  def builder_mode(_issue), do: "execute"

  @spec planner_mode(Item.t()) :: String.t()
  def planner_mode(%Item{state: state_name} = issue) when is_binary(state_name) do
    case normalize_stage(state_name) do
      @building_stage ->
        "review"

      _ ->
        if blank?(issue.current_plan), do: "planning", else: "replanning"
    end
  end

  def planner_mode(%Item{} = issue), do: if(blank?(issue.current_plan), do: "planning", else: "replanning")

  @spec building_active_role(Item.t()) :: String.t()
  def building_active_role(%Item{} = issue) do
    case workflow_value(issue, "active_role") do
      @planner_review_role -> @planner_review_role
      @builder_role -> @builder_role
      _ -> @builder_role
    end
  end

  @spec building_phase(Item.t()) :: String.t()
  def building_phase(%Item{} = issue) do
    case workflow_value(issue, "building_phase") do
      @builder_pickup_phase ->
        @builder_pickup_phase

      @builder_rework_phase ->
        @builder_rework_phase

      @planner_review_phase ->
        @planner_review_phase

      @builder_execute_phase ->
        @builder_execute_phase

      _ ->
        inferred_building_phase(issue)
    end
  end

  @spec set_building_hook(Item.t() | String.t() | nil, String.t(), String.t()) :: String.t()
  def set_building_hook(issue_or_extra, active_role, building_phase)
      when active_role in [@builder_role, @planner_review_role] and
             building_phase in [@builder_pickup_phase, @builder_execute_phase, @builder_rework_phase, @planner_review_phase] do
    issue_or_extra
    |> state_from_issue_or_extra()
    |> put_workflow("active_role", active_role)
    |> put_workflow("building_phase", building_phase)
    |> serialize()
  end

  @spec clear_building_hook(Item.t() | String.t() | nil) :: String.t()
  def clear_building_hook(issue_or_extra) do
    issue_or_extra
    |> state_from_issue_or_extra()
    |> Map.put("workflow", %{})
    |> serialize()
  end

  @spec planner_pending?(Item.t()) :: boolean()
  def planner_pending?(%Item{state: state_name} = issue) when is_binary(state_name) do
    case normalize_stage(state_name) do
      @planning_stage ->
        blank?(issue.current_plan) or
          meta_value(issue, "planner_planning_fingerprint") != planning_fingerprint(issue)

      @building_stage ->
        building_active_role(issue) == @planner_review_role and
          meta_value(issue, "planner_review_fingerprint") != review_fingerprint(issue)

      _ ->
        false
    end
  end

  def planner_pending?(_issue), do: false

  @spec auditor_pending?(Item.t()) :: boolean()
  def auditor_pending?(%Item{state: state_name} = issue) when is_binary(state_name) do
    normalize_stage(state_name) == @auditing_stage and
      (blank?(issue.auditor_verdict) or meta_value(issue, "auditor_fingerprint") != auditor_fingerprint(issue))
  end

  def auditor_pending?(_issue), do: false

  @spec builder_rework_requested?(Item.t()) :: boolean()
  def builder_rework_requested?(%Item{state: state_name} = issue) when is_binary(state_name) do
    normalize_stage(state_name) == @building_stage and
      (building_phase(issue) == @builder_rework_phase or latest_reviewer_signal(issue.comments || []) == :rework)
  end

  def builder_rework_requested?(_issue), do: false

  @spec prompt_context(Item.t()) :: map()
  def prompt_context(%Item{} = issue) do
    %{
      task_kind: issue.task_kind,
      current_plan: issue.current_plan,
      builder_workpad: issue.builder_workpad,
      auditor_verdict: issue.auditor_verdict,
      workflow_active_role: building_active_role(issue),
      workflow_building_phase: building_phase(issue),
      comments: issue.comments || [],
      human_comments: human_comments(issue.comments || []),
      reviewer_comments: reviewer_comments(issue.comments || [])
    }
  end

  @spec mark_role_processed(Item.t(), :planner | :auditor) :: String.t()
  def mark_role_processed(%Item{} = issue, :planner) do
    parsed =
      issue.extra
      |> parse()
      |> put_meta("planner_planning_fingerprint", planning_fingerprint(issue))
      |> put_meta("planner_review_fingerprint", review_fingerprint(issue))

    serialize(parsed)
  end

  def mark_role_processed(%Item{} = issue, :auditor) do
    issue.extra
    |> parse()
    |> put_meta("auditor_fingerprint", auditor_fingerprint(issue))
    |> serialize()
  end

  @spec planning_fingerprint(Item.t()) :: String.t()
  def planning_fingerprint(%Item{} = issue) do
    sha256(join_inputs([issue.description, comment_fingerprint(issue.comments || [])]))
  end

  @spec review_fingerprint(Item.t()) :: String.t()
  def review_fingerprint(%Item{} = issue) do
    sha256(
      join_inputs([
        issue.description,
        issue.task_kind,
        issue.current_plan,
        issue.builder_workpad,
        comment_fingerprint(issue.comments || [])
      ])
    )
  end

  @spec auditor_fingerprint(Item.t()) :: String.t()
  def auditor_fingerprint(%Item{} = issue) do
    sha256(join_inputs([issue.description, issue.task_kind, issue.current_plan, issue.builder_workpad]))
  end

  defp default_state do
    %{
      "schema_version" => @schema_version,
      "meta" => %{},
      "workflow" => %{}
    }
  end

  defp put_meta(%{} = state, key, value) do
    meta =
      state
      |> Map.get("meta", %{})
      |> Map.put(key, value)

    Map.put(state, "meta", meta)
  end

  defp put_workflow(%{} = state, key, value) do
    workflow =
      state
      |> Map.get("workflow", %{})
      |> Map.put(key, value)

    Map.put(state, "workflow", workflow)
  end

  defp workflow_value(%Item{extra: extra}, key) when is_binary(key) do
    extra
    |> parse()
    |> Map.get("workflow", %{})
    |> Map.get(key)
  end

  defp state_from_issue_or_extra(%Item{extra: extra}), do: parse(extra)
  defp state_from_issue_or_extra(extra) when is_binary(extra), do: parse(extra)
  defp state_from_issue_or_extra(_value), do: default_state()

  defp inferred_building_phase(%Item{} = issue) do
    cond do
      blank?(issue.builder_workpad) ->
        @builder_pickup_phase

      latest_reviewer_signal(issue.comments || []) == :rework ->
        @builder_rework_phase

      true ->
        @builder_execute_phase
    end
  end

  defp default_builder_mode(%Item{} = issue) do
    case inferred_building_phase(issue) do
      @builder_pickup_phase -> "pickup"
      @builder_rework_phase -> "rework"
      _ -> "execute"
    end
  end

  defp meta_value(%Item{extra: extra}, key) when is_binary(key) do
    extra
    |> parse()
    |> Map.get("meta", %{})
    |> Map.get(key)
  end

  defp join_inputs(values) do
    values
    |> Enum.map(&blank_to_nil/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n---\n\n")
  end

  defp sha256(input) when is_binary(input) do
    :crypto.hash(:sha256, input)
    |> Base.encode16(case: :lower)
  end

  defp blank?(value), do: is_nil(blank_to_nil(value))

  defp human_comments(comments) when is_list(comments) do
    Enum.reject(comments, &agent_comment?/1)
  end

  defp reviewer_comments(comments) when is_list(comments) do
    Enum.filter(comments, &reviewer_comment?/1)
  end

  defp comment_fingerprint(comments) when is_list(comments) do
    comments
    |> human_comments()
    |> Enum.map_join("\n\n---\n\n", fn comment ->
      [
        blank_to_nil(comment[:id] || comment["id"]),
        blank_to_nil(comment[:content] || comment["content"]),
        blank_to_nil(comment[:updated_at] || comment["updated_at"]),
        blank_to_nil(comment[:created_at] || comment["created_at"])
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")
    end)
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_stage(stage_name) when is_binary(stage_name) do
    stage_name
    |> String.trim()
    |> String.downcase()
  end

  defp agent_comment?(comment) when is_map(comment) do
    case normalized_comment_content(comment) do
      nil ->
        false

      trimmed ->
        String.starts_with?(trimmed, "planner:") or
          String.starts_with?(trimmed, "builder:") or
          String.starts_with?(trimmed, "auditor:")
    end
  end

  defp agent_comment?(_comment), do: false

  defp reviewer_comment?(comment) when is_map(comment) do
    case normalized_comment_content(comment) do
      nil ->
        false

      trimmed ->
        String.starts_with?(trimmed, "planner:") or String.starts_with?(trimmed, "auditor:")
    end
  end

  defp reviewer_comment?(_comment), do: false

  defp latest_reviewer_signal(comments) when is_list(comments) do
    Enum.reduce_while(Enum.reverse(comments), :none, fn comment, _acc ->
      case normalized_comment_content(comment) do
        nil ->
          {:cont, :none}

        trimmed ->
          cond do
            String.starts_with?(trimmed, "planner:") or String.starts_with?(trimmed, "auditor:") ->
              if String.contains?(trimmed, "rework required") do
                {:halt, :rework}
              else
                {:halt, :other}
              end

            true ->
              {:cont, :none}
          end
      end
    end)
  end

  defp normalized_comment_content(comment) when is_map(comment) do
    comment
    |> Map.get(:content, Map.get(comment, "content"))
    |> case do
      value when is_binary(value) ->
        value
        |> String.trim()
        |> String.downcase()
        |> case do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end
end
