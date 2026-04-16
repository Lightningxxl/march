defmodule March.PromptBuilder do
  @moduledoc """
  Builds agent prompts from tracker item data.
  """

  alias March.{Config, Feishu.TaskState}

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(map(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    build_role_prompt(:builder, issue, opts)
  end

  @spec build_planner_prompt(map(), keyword()) :: String.t()
  def build_planner_prompt(issue, opts \\ []) do
    build_role_prompt(:planner, issue, opts)
  end

  @spec build_auditor_prompt(map(), keyword()) :: String.t()
  def build_auditor_prompt(issue, opts \\ []) do
    build_role_prompt(:auditor, issue, opts)
  end

  defp build_role_prompt(role, issue, opts) do
    template =
      Config.role_workflow(role)
      |> prompt_template!()
      |> parse_template!()

    assigns = %{
      "attempt" => Keyword.get(opts, :attempt),
      "issue" => issue |> Map.from_struct() |> to_solid_map(),
      "max_turns" => Keyword.get(opts, :max_turns),
      "role" => Atom.to_string(role),
      "mode" => Keyword.get(opts, :mode),
      "turn_number" => Keyword.get(opts, :turn_number),
      "turn_phase" => Keyword.get(opts, :turn_phase),
      "ticket" => opts |> Keyword.get(:ticket, %{}) |> to_solid_value()
    }

    rendered =
      template
      |> Solid.render!(assigns, @render_opts)
      |> IO.iodata_to_binary()

    rendered <> ticket_snapshot_suffix(issue, Keyword.get(opts, :ticket), role)
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end

  defp ticket_snapshot_suffix(issue, nil, role),
    do: runtime_contract_suffix(role, nil) <> task_operations_suffix(issue, role, nil)

  defp ticket_snapshot_suffix(issue, ticket, role) when is_map(ticket) do
    sections =
      [
        "",
        runtime_contract_suffix(role, ticket),
        "## Feishu Task Snapshot",
        "- active_role: #{role}",
        render_scalar_line("mode", Map.get(ticket, :mode) || Map.get(ticket, "mode")),
        render_scalar_line("turn_phase", Map.get(ticket, :turn_phase) || Map.get(ticket, "turn_phase")),
        render_scalar_line("turn_number", Map.get(ticket, :turn_number) || Map.get(ticket, "turn_number")),
        render_scalar_line("max_turns", Map.get(ticket, :max_turns) || Map.get(ticket, "max_turns")),
        render_scalar_line("attempt", Map.get(ticket, :attempt) || Map.get(ticket, "attempt")),
        render_scalar_line("task_kind", Map.get(ticket, :task_kind) || Map.get(ticket, "task_kind")),
        render_scalar_line("workflow_active_role", Map.get(ticket, :workflow_active_role) || Map.get(ticket, "workflow_active_role")),
        render_scalar_line("workflow_building_phase", Map.get(ticket, :workflow_building_phase) || Map.get(ticket, "workflow_building_phase")),
        render_scalar_line("current_pr", Map.get(ticket, :pr_url) || Map.get(ticket, "pr_url")),
        render_named_block("Current Implementation Plan", Map.get(ticket, :current_plan) || Map.get(ticket, "current_plan")),
        render_named_block("Current Builder Workpad", Map.get(ticket, :builder_workpad) || Map.get(ticket, "builder_workpad")),
        render_named_block("Current Auditor Verdict", Map.get(ticket, :auditor_verdict) || Map.get(ticket, "auditor_verdict")),
        render_comments_block("Recent Reviewer Discussion", Map.get(ticket, :reviewer_comments) || Map.get(ticket, "reviewer_comments")),
        render_comments_block("Recent Task Discussion", Map.get(ticket, :comments) || Map.get(ticket, "comments")),
        render_comments_block("Recent Human Discussion", Map.get(ticket, :human_comments) || Map.get(ticket, "human_comments"))
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    "\n" <> Enum.join(sections, "\n") <> task_operations_suffix(issue, role, ticket)
  end

  defp runtime_contract_suffix(role, ticket) do
    base_contract = """
    ## Runtime Contract
    - The runtime already fetched the current task description, current custom-field values, and the current task comment thread for this turn.
    - Treat the appended task snapshot as the authoritative live task state for this turn.
    - If `Recent Task Discussion` is absent, treat the current discussion thread as empty.
    - Do not run CLI discovery commands such as `lark-cli --help`, `lark-cli api --help`, `lark-cli schema`, or shell completion probes.
    - Use the exact commands in `## Feishu Task Operations` only when you need a required task mutation or a required re-read.
    """
    |> String.trim()

    case builder_workpad_contract(role, ticket) do
      nil -> base_contract
      contract -> base_contract <> "\n" <> contract
    end
  end

  defp builder_workpad_contract(:builder, ticket) when is_map(ticket) do
    attempt = Map.get(ticket, :attempt) || Map.get(ticket, "attempt")
    builder_workpad = Map.get(ticket, :builder_workpad) || Map.get(ticket, "builder_workpad")
    turn_phase = Map.get(ticket, :turn_phase) || Map.get(ticket, "turn_phase")
    mode = Map.get(ticket, :mode) || Map.get(ticket, "mode")

    recovery_notice =
      if builder_retry_or_continuation?(attempt, turn_phase, mode) and present_text?(builder_workpad) do
        """
        ## Builder Restart Recovery
        - This builder turn is a retry/restart or continuation with an existing workpad snapshot.
        - Resume from the current workpad. Do not replace it wholesale unless it is clearly empty or corrupted.
        - If you normalize the format, preserve completed and already-verified progress; rewrite only the minimal sections that changed.
        """
        |> String.trim()
      end

    [recovery_notice,
     """
     ## Builder Workpad Contract
     - Treat `Current Builder Workpad` as the canonical durable builder state for this task.
     - If `Current Builder Workpad` is non-empty, continue from it instead of regenerating it from scratch.
     - Preserve completed items and prior notes. Prefer appending deltas or updating only the changed status and next-step lines.
     - Before patching `Builder Workpad` after a long run, a retry, or right before a stage transition, use `Read Task Custom Fields` to re-read the latest remote value and merge with it if it changed.
     - Do not wipe the workpad just to restate the same plan in different words.
     """
     |> String.trim()]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp builder_workpad_contract(_role, _ticket), do: nil

  defp task_operations_suffix(issue, role, ticket) when is_map(issue) do
    task_guid = Map.get(issue, :id) || Map.get(issue, "id")
    tasklist_guid = Map.get(issue, :tasklist_guid) || Map.get(issue, "tasklist_guid")
    field_guids = Map.get(issue, :task_custom_field_guids) || Map.get(issue, "task_custom_field_guids") || %{}
    task_kind_option_guids = Map.get(issue, :task_kind_option_guids) || Map.get(issue, "task_kind_option_guids") || %{}
    section_guids = Map.get(issue, :task_section_guids_by_name) || Map.get(issue, "task_section_guids_by_name") || %{}
    extra = Map.get(issue, :extra) || Map.get(issue, "extra")

    blocks =
      [
        "",
        "## Feishu Task Operations",
        render_scalar_line("task_guid", task_guid),
        render_scalar_line("tasklist_guid", tasklist_guid),
        render_scalar_line("current_stage", Map.get(issue, :state) || Map.get(issue, "state")),
        render_scalar_line("current_plan_field_guid", Map.get(field_guids, "Current Plan")),
        render_scalar_line("builder_workpad_field_guid", Map.get(field_guids, "Builder Workpad")),
        render_scalar_line("auditor_verdict_field_guid", Map.get(field_guids, "Auditor Verdict")),
        render_scalar_line("pr_field_guid", Map.get(field_guids, "PR")),
        render_scalar_line("task_kind_field_guid", Map.get(field_guids, "Task Kind")),
        render_named_block("Current Internal Hook", render_internal_hook_summary(extra)),
        render_named_block(
          "Read Task Comments",
          render_shell_command("""
          lark-cli api GET /task/v2/comments --as user --params '{"resource_type":"task","resource_id":"#{task_guid}"}'
          """)
        ),
        render_named_block(
          "Read Task Custom Fields",
          render_shell_command("""
          lark-cli api GET /task/v2/custom_fields --as user --params '{"resource_type":"tasklist","resource_id":"#{tasklist_guid}"}'
          """)
        ),
        render_named_block("Builder Workpad Update Guidance", render_builder_workpad_update_guidance(role, ticket)),
        render_named_block(
          "Patch Task Custom Fields",
          render_shell_command("""
          lark-cli task tasks patch --as user --params '{"task_guid":"#{task_guid}"}' --data '{"update_fields":["custom_fields"],"task":{"custom_fields":[{"guid":"<field-guid>","text_value":"<new text value>"}]}}'
          """)
        ),
        render_named_block(
          "Set Task Kind (single-select)",
          render_task_kind_commands(task_guid, Map.get(field_guids, "Task Kind"), task_kind_option_guids)
        ),
        render_named_block(
          "Add Task Comment",
          render_shell_command("""
          lark-cli task +comment --as user --task-id '#{task_guid}' --content 'Planner: ...'
          """)
        ),
        render_named_block(
          "Set Internal Hook To Builder Pickup",
          render_shell_command(render_extra_patch_command(task_guid, TaskState.set_building_hook(extra, "builder", "pickup")))
        ),
        render_named_block(
          "Set Internal Hook To Builder Execute",
          render_shell_command(render_extra_patch_command(task_guid, TaskState.set_building_hook(extra, "builder", "execute")))
        ),
        render_named_block(
          "Set Internal Hook To Builder Rework",
          render_shell_command(render_extra_patch_command(task_guid, TaskState.set_building_hook(extra, "builder", "rework")))
        ),
        render_named_block(
          "Set Internal Hook To Planner Review",
          render_shell_command(render_extra_patch_command(task_guid, TaskState.set_building_hook(extra, "planner_review", "review")))
        ),
        render_named_block(
          "Clear Internal Hook",
          render_shell_command(render_extra_patch_command(task_guid, TaskState.clear_building_hook(extra)))
        ),
        render_named_block(
          "Move Task Between Stages",
          render_stage_routing_examples(task_guid, tasklist_guid, section_guids)
        ),
        "Use these exact Feishu task endpoints and field GUIDs. Do not invent alternate task comment endpoints."
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    "\n" <> Enum.join(blocks, "\n")
  end

  defp task_operations_suffix(_issue, _role, _ticket), do: ""

  defp render_builder_workpad_update_guidance(:builder, ticket) when is_map(ticket) do
    attempt = Map.get(ticket, :attempt) || Map.get(ticket, "attempt")
    turn_phase = Map.get(ticket, :turn_phase) || Map.get(ticket, "turn_phase")
    mode = Map.get(ticket, :mode) || Map.get(ticket, "mode")

    [
      "Use `Patch Task Custom Fields` for `Builder Workpad` only after you have compared against the latest remote field value.",
      "Prefer small in-place updates: mark completed checklist items, append a short milestone note, or refresh only `Current Status` / `Next Step`.",
      if(builder_retry_or_continuation?(attempt, turn_phase, mode),
        do: "This turn is not a fresh pickup. Preserve the existing workpad and continue it instead of rewriting the whole field."
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp render_builder_workpad_update_guidance(_role, _ticket), do: nil

  defp render_named_block(_title, nil), do: nil

  defp render_named_block(title, body) when is_binary(body) do
    trimmed = String.trim(body)

    if trimmed == "" do
      nil
    else
      "### #{title}\n#{trimmed}"
    end
  end

  defp render_comments_block(_title, comments) when comments in [nil, []], do: nil

  defp render_comments_block(title, comments) when is_list(comments) do
    rendered_comments =
      comments
      |> Enum.take(-8)
      |> Enum.map(&render_comment_line/1)
      |> Enum.reject(&is_nil/1)

    if rendered_comments == [] do
      nil
    else
      "### #{title}\n" <> Enum.join(rendered_comments, "\n")
    end
  end

  defp render_comment_line(comment) when is_map(comment) do
    content =
      comment
      |> Map.get(:content, Map.get(comment, "content"))
      |> case do
        value when is_binary(value) ->
          value
          |> String.trim()
          |> String.replace(~r/\s+/, " ")

        _ ->
          nil
      end

    if is_nil(content) or content == "" do
      nil
    else
      created_at = Map.get(comment, :created_at, Map.get(comment, "created_at"))
      comment_id = Map.get(comment, :id, Map.get(comment, "id"))

      "- [#{created_at || "unknown"}][#{comment_id || "no-id"}] #{content}"
    end
  end

  defp render_scalar_line(_label, nil), do: nil

  defp render_scalar_line(label, value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: "- #{label}: #{trimmed}"
  end

  defp render_scalar_line(label, value) when is_integer(value), do: "- #{label}: #{value}"

  defp builder_retry_or_continuation?(attempt, turn_phase, mode) do
    (is_integer(attempt) and attempt > 1) or turn_phase == "continuation" or mode in ["rework", "merge"]
  end

  defp present_text?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_text?(_value), do: false

  defp render_task_kind_commands(_task_guid, nil, _task_kind_option_guids), do: nil

  defp render_task_kind_commands(task_guid, task_kind_field_guid, task_kind_option_guids)
       when is_binary(task_guid) and is_binary(task_kind_field_guid) and is_map(task_kind_option_guids) do
    lines =
      task_kind_option_guids
      |> Enum.sort_by(fn {name, _guid} -> String.downcase(to_string(name)) end)
      |> Enum.map(fn {name, option_guid} ->
        render_task_kind_command(task_guid, task_kind_field_guid, name, option_guid)
      end)
      |> Enum.reject(&is_nil/1)

    case lines do
      [] -> nil
      _ -> Enum.join(lines, "\n\n")
    end
  end

  defp render_task_kind_command(_task_guid, _field_guid, _name, nil), do: nil

  defp render_task_kind_command(task_guid, field_guid, name, option_guid) do
    """
    Set `Task Kind` to `#{name}`:
    #{render_shell_command("""
    lark-cli task tasks patch --as user --params '{"task_guid":"#{task_guid}"}' --data '{"update_fields":["custom_fields"],"task":{"custom_fields":[{"guid":"#{field_guid}","single_select_value":"#{option_guid}"}]}}'
    """)}
    """
    |> String.trim()
  end

  defp render_shell_command(command) when is_binary(command) do
    trimmed = String.trim(command)
    if trimmed == "", do: nil, else: "```bash\n#{trimmed}\n```"
  end

  defp render_stage_routing_examples(task_guid, tasklist_guid, section_guids)
       when is_binary(task_guid) and is_binary(tasklist_guid) and is_map(section_guids) do
    stage_lines =
      section_guids
      |> Enum.sort_by(fn {stage, _guid} -> stage end)
      |> Enum.map(fn {stage, section_guid} ->
        "- #{stage}: `lark-cli api POST /task/v2/tasks/#{task_guid}/add_tasklist --as user --data '{\"tasklist_guid\":\"#{tasklist_guid}\",\"section_guid\":\"#{section_guid}\"}'`"
      end)

    if stage_lines == [] do
      nil
    else
      Enum.join(stage_lines, "\n")
    end
  end

  defp render_stage_routing_examples(_task_guid, _tasklist_guid, _section_guids), do: nil

  defp render_internal_hook_summary(extra) do
    case TaskState.parse(extra) do
      %{"workflow" => %{} = workflow} ->
        workflow
        |> Enum.sort_by(fn {key, _value} -> key end)
        |> Enum.map_join("\n", fn {key, value} -> "- #{key}: #{value}" end)
        |> case do
          "" -> nil
          rendered -> rendered
        end

      _ ->
        nil
    end
  end

  defp render_extra_patch_command(task_guid, extra_json)
       when is_binary(task_guid) and is_binary(extra_json) do
    params = Jason.encode!(%{"task_guid" => task_guid, "user_id_type" => "open_id"})
    data = Jason.encode!(%{"update_fields" => ["extra"], "task" => %{"extra" => extra_json}})

    """
    lark-cli task tasks patch --as user --params '#{escape_shell_single_quotes(params)}' --data '#{escape_shell_single_quotes(data)}'
    """
    |> String.trim()
  end

  defp escape_shell_single_quotes(value) when is_binary(value) do
    String.replace(value, "'", ~s('"'"'))
  end
end
