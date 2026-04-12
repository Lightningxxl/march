defmodule March.PromptBuilderTest do
  use March.TestSupport

  test "builder prompt exposes mode and turn variables to the template" do
    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: """
      mode={{ mode }}
      phase={{ turn_phase }}
      turn={{ turn_number }}/{{ max_turns }}
      attempt={{ attempt }}
      """
    )

    prompt =
      PromptBuilder.build_prompt(
        %Issue{id: "task-1", identifier: "TASK-1"},
        mode: "merge",
        turn_phase: "continuation",
        turn_number: 3,
        max_turns: 6,
        attempt: 2
      )

    assert prompt =~ "mode=merge"
    assert prompt =~ "phase=continuation"
    assert prompt =~ "turn=3/6"
    assert prompt =~ "attempt=2"
  end

  test "planner prompt exposes replanning mode to the template" do
    write_workflow_file!(Workflow.workflow_file_path(),
      planner_prompt: """
      planner-mode={{ mode }}
      planner-phase={{ turn_phase }}
      """
    )

    prompt =
      PromptBuilder.build_planner_prompt(
        %Issue{id: "task-2", identifier: "TASK-2"},
        mode: "replanning",
        turn_phase: "single_turn",
        turn_number: 1,
        max_turns: 1
      )

    assert prompt =~ "planner-mode=replanning"
    assert prompt =~ "planner-phase=single_turn"
  end

  test "prompt snapshot includes exact Feishu task operation hints" do
    write_workflow_file!(Workflow.workflow_file_path(), planner_prompt: "planner-mode={{ mode }}")

    prompt =
      PromptBuilder.build_planner_prompt(
        %Issue{
          id: "task-123",
          identifier: "TASK-123",
          state: "Planning",
          tasklist_guid: "tasklist-456",
          extra: nil,
          task_custom_field_guids: %{
            "Current Plan" => "field-plan",
            "Builder Workpad" => "field-workpad",
            "Auditor Verdict" => "field-audit"
          },
          task_section_guids_by_name: %{
            "Planning" => "section-planning",
            "Building" => "section-building",
            "Auditing" => "section-auditing"
          }
        },
        mode: "planning",
        turn_phase: "single_turn",
        turn_number: 1,
        max_turns: 1
      )

    assert prompt =~ "## Feishu Task Operations"
    assert prompt =~ "## Runtime Contract"
    assert prompt =~ "Do not run CLI discovery commands"
    assert prompt =~ "task_guid: task-123"
    assert prompt =~ "current_plan_field_guid: field-plan"
    assert prompt =~ "/task/v2/comments"
    assert prompt =~ "/task/v2/tasks/task-123/add_tasklist"
    assert prompt =~ "Set Internal Hook To Planner Review"
    assert prompt =~ "\"active_role\\\": \\\"planner_review\\\""
    assert prompt =~ "Do not invent alternate task comment endpoints."
  end

  test "auditor prompt exposes re-audit mode to the template" do
    write_workflow_file!(Workflow.workflow_file_path(),
      auditor_prompt: """
      auditor-mode={{ mode }}
      auditor-turn={{ turn_number }}
      """
    )

    prompt =
      PromptBuilder.build_auditor_prompt(
        %Issue{id: "task-3", identifier: "TASK-3"},
        mode: "reaudit",
        turn_phase: "single_turn",
        turn_number: 1,
        max_turns: 1
      )

    assert prompt =~ "auditor-mode=reaudit"
    assert prompt =~ "auditor-turn=1"
  end
end
