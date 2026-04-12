defmodule March.FeishuTaskStateTest do
  use ExUnit.Case, async: true

  alias March.Feishu.TaskState
  alias March.Tracker.Item, as: Issue

  test "planner pending tracks human comment changes during planning stage" do
    issue = %Issue{
      id: "task-1",
      identifier: "t100001",
      title: "Plan a task",
      description: "Initial body",
      state: "Planning",
      extra: nil,
      current_plan: nil,
      comments: [
        %{id: "c1", content: "Need a cleaner ownership split.", created_at: "1", updated_at: "1"}
      ]
    }

    assert TaskState.planner_pending?(issue)

    marked_issue = %Issue{
      issue
      | current_plan: "Plan is ready.",
        extra: TaskState.mark_role_processed(issue, :planner)
    }

    refute TaskState.planner_pending?(marked_issue)

    changed_issue = %Issue{
      marked_issue
      | comments: [
          %{id: "c1", content: "Need a cleaner ownership split.", created_at: "1", updated_at: "1"},
          %{id: "c2", content: "Also keep planner comments out of the canonical fields.", created_at: "2", updated_at: "2"}
        ]
    }

    assert TaskState.planner_pending?(changed_issue)
  end

  test "planner-owned task kind changes do not retrigger planning by themselves" do
    issue = %Issue{
      id: "task-kind-1",
      identifier: "t100099",
      title: "Bug: fix planner task kind sync",
      description: "Need planner to classify this task first.",
      state: "Planning",
      task_kind: nil,
      extra: nil,
      current_plan: "Plan is ready.",
      comments: []
    }

    marked_issue = %Issue{
      issue
      | extra: TaskState.mark_role_processed(issue, :planner)
    }

    refute TaskState.planner_pending?(marked_issue)

    planner_updated_kind = %Issue{marked_issue | task_kind: "bug"}
    refute TaskState.planner_pending?(planner_updated_kind)
  end

  test "auditor pending tracks builder workpad changes" do
    issue = %Issue{
      id: "task-2",
      identifier: "t100002",
      title: "Audit a task",
      description: "Initial body",
      state: "Auditing",
      task_kind: "bug",
      current_plan: "Plan",
      builder_workpad: "Workpad v1",
      auditor_verdict: nil,
      extra: nil
    }

    assert TaskState.auditor_pending?(issue)

    marked_issue = %Issue{
      issue
      | auditor_verdict: "Looks good.",
        extra: TaskState.mark_role_processed(issue, :auditor)
    }

    refute TaskState.auditor_pending?(marked_issue)

    changed_issue = %Issue{marked_issue | builder_workpad: "Workpad v2"}
    assert TaskState.auditor_pending?(changed_issue)
  end

  test "prompt context exposes human comments separately from agent comments" do
    issue = %Issue{
      id: "task-3",
      comments: [
        %{id: "c1", content: "Human: please tighten scope.", created_at: "1", updated_at: "1"},
        %{id: "c2", content: "Planner: updated current plan.", created_at: "2", updated_at: "2"},
        %{id: "c3", content: "Auditor: rework required due to missing roundtrip proof.", created_at: "3", updated_at: "3"}
      ],
      current_plan: "Plan",
      builder_workpad: "Workpad",
      auditor_verdict: "Verdict",
      task_kind: "improvement"
    }

    context = TaskState.prompt_context(issue)

    assert length(context.comments) == 3
    assert Enum.map(context.human_comments, & &1.id) == ["c1"]
    assert Enum.map(context.reviewer_comments, & &1.id) == ["c2", "c3"]
    assert context.task_kind == "improvement"
  end

  test "builder rework pending follows latest reviewer rework signal while building" do
    issue = %Issue{
      id: "task-4",
      state: "Building",
      comments: [
        %{id: "c1", content: "Builder: initial implementation ready.", created_at: "1", updated_at: "1"},
        %{id: "c2", content: "Planner: rework required for missing ownership cleanup.", created_at: "2", updated_at: "2"}
      ]
    }

    assert TaskState.builder_rework_requested?(issue)

    non_rework_issue = %Issue{
      issue
      | comments: [
          %{id: "c1", content: "Planner: approved for audit.", created_at: "1", updated_at: "1"}
        ]
    }

    refute TaskState.builder_rework_requested?(non_rework_issue)
  end

  test "role for building follows internal hook" do
    builder_issue = %Issue{id: "task-5", state: "Building", extra: nil, builder_workpad: nil}
    assert TaskState.role_for_issue(builder_issue) == :builder
    assert TaskState.builder_mode(builder_issue) == "pickup"

    review_issue = %Issue{
      id: "task-6",
      state: "Building",
      extra: TaskState.set_building_hook(nil, "planner_review", "review"),
      current_plan: "Plan",
      builder_workpad: "Workpad"
    }

    assert TaskState.role_for_issue(review_issue) == :planner
    assert TaskState.planner_mode(review_issue) == "review"
  end
end
