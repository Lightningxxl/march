defmodule March.FeishuTaskAdapterTest do
  use March.TestSupport

  alias March.Feishu.TaskAdapter

  defmodule FakeTaskClient do
    @table __MODULE__

    def reset(fixtures) when is_map(fixtures) do
      ensure_table!()
      :ets.delete_all_objects(@table)
      true = :ets.insert(@table, {:fixtures, fixtures})
      :ok
    end

    def calls(operation) when is_atom(operation) do
      ensure_table!()

      @table
      |> :ets.lookup({:calls, operation})
      |> Enum.map(fn {{:calls, ^operation}, payload} -> payload end)
    end

    def count(operation) when is_atom(operation), do: length(calls(operation))

    def list_tasklist_task_guids(tasklist_guid) do
      record(:list_tasklist_task_guids, tasklist_guid)

      fixtures()
      |> Map.fetch!(:task_guids)
      |> then(&{:ok, &1})
    end

    def get_task(task_guid) do
      record(:get_task, task_guid)

      case fixtures() |> Map.get(:task_errors, %{}) |> Map.get(task_guid) do
        nil ->
          fixtures()
          |> Map.fetch!(:tasks)
          |> Map.fetch(task_guid)
          |> case do
            {:ok, task} -> {:ok, task}
            :error -> {:error, {:missing_task, task_guid}}
          end

        reason ->
          {:error, reason}
      end
    end

    def list_comments(task_guid) do
      record(:list_comments, task_guid)

      fixtures()
      |> Map.get(:comments, %{})
      |> Map.get(task_guid, [])
      |> then(&{:ok, &1})
    end

    def list_sections(tasklist_guid) do
      record(:list_sections, tasklist_guid)

      fixtures()
      |> Map.fetch!(:sections)
      |> then(&{:ok, &1})
    end

    def list_custom_fields(tasklist_guid) do
      record(:list_custom_fields, tasklist_guid)

      fixtures()
      |> Map.fetch!(:custom_fields)
      |> then(&{:ok, &1})
    end

    def patch_task(task_guid, _update_fields, _task_payload) do
      record(:patch_task, task_guid)
      {:ok, fixtures() |> Map.fetch!(:tasks) |> Map.fetch!(task_guid)}
    end

    def move_task_to_section(task_guid, tasklist_guid, section_guid) do
      record(:move_task_to_section, {task_guid, tasklist_guid, section_guid})
      :ok
    end

    def create_comment(task_guid, content) do
      record(:create_comment, {task_guid, content})
      :ok
    end

    defp fixtures do
      ensure_table!()

      case :ets.lookup(@table, :fixtures) do
        [{:fixtures, fixtures}] -> fixtures
        _ -> %{}
      end
    end

    defp record(operation, payload) do
      ensure_table!()
      true = :ets.insert(@table, {{:calls, operation}, payload})
      :ok
    end

    defp ensure_table! do
      case :ets.whereis(@table) do
        :undefined ->
          try do
            :ets.new(@table, [:named_table, :public, :duplicate_bag])
          rescue
            ArgumentError -> @table
          end

        _table ->
          @table
      end
    end
  end

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "feishu_task",
      tracker_tasklist_guid: "tasklist-1"
    )

    previous_client = Application.get_env(:march, :feishu_task_client)
    Application.put_env(:march, :feishu_task_client, FakeTaskClient)
    TaskAdapter.clear_context_cache_for_test()

    on_exit(fn ->
      TaskAdapter.clear_context_cache_for_test()

      if is_nil(previous_client) do
        Application.delete_env(:march, :feishu_task_client)
      else
        Application.put_env(:march, :feishu_task_client, previous_client)
      end
    end)

    :ok
  end

  test "normalize_task_payload reads stage from section and canonical fields from task custom fields" do
    task = %{
      "guid" => "task-1",
      "task_id" => "t100001",
      "summary" => "Align March to Feishu task fields",
      "description" => "The task description is the human-authored body.",
      "status" => "todo",
      "url" => "https://example.test/task-1",
      "extra" => "{\"schema_version\":1,\"meta\":{}}",
      "tasklists" => [
        %{
          "tasklist_guid" => "tasklist-1",
          "section_guid" => "default-section"
        }
      ],
      "custom_fields" => [
        %{"name" => "Task Key", "type" => "text", "text_value" => "claworld/t100001"},
        %{"name" => "Current Plan", "type" => "text", "text_value" => "### Current Plan\nUse task comments for discussion."},
        %{"name" => "Builder Workpad", "type" => "text", "text_value" => "`host:path@sha`\n\n### Plan\n- [ ] Implement"},
        %{"name" => "Auditor Verdict", "type" => "text", "text_value" => "### Verdict\nPending"},
        %{"name" => "Task Kind", "type" => "single_select", "single_select_value" => "opt-improvement"}
      ]
    }

    comments = [
      %{"id" => "c1", "content" => "Human: comments should drive planner replanning.", "created_at" => "1", "updated_at" => "1"}
    ]

    context = %{
      section_names_by_guid: %{"default-section" => "Backlog"},
      section_guids_by_name: %{"Backlog" => "default-section"},
      default_section_guids: MapSet.new(["default-section"]),
      custom_field_guids_by_name: %{
        "Task Key" => "field-task-key",
        "Current Plan" => "field-plan",
        "Builder Workpad" => "field-workpad",
        "Auditor Verdict" => "field-audit",
        "Task Kind" => "field-kind"
      },
      task_kind_options_by_guid: %{"opt-improvement" => "improvement"}
    }

    issue = TaskAdapter.normalize_task_payload(task, comments, context)

    assert issue.state == "Backlog"
    assert issue.identifier == "claworld/t100001"
    assert issue.task_key == "claworld/t100001"
    assert issue.body == "The task description is the human-authored body."
    assert issue.current_plan =~ "Current Plan"
    assert issue.builder_workpad =~ "### Plan"
    assert issue.auditor_verdict =~ "### Verdict"
    assert issue.task_kind == "improvement"
    assert issue.task_custom_field_guids["Current Plan"] == "field-plan"
    assert issue.task_custom_field_guids["Task Key"] == "field-task-key"
    assert issue.task_section_guids_by_name["Backlog"] == "default-section"
    assert Enum.map(issue.comments, & &1.id) == ["c1"]
  end

  test "normalize_task_payload uses named non-default sections directly" do
    task = %{
      "guid" => "task-2",
      "summary" => "Review implementation",
      "description" => "Review body",
      "tasklists" => [
        %{
          "tasklist_guid" => "tasklist-1",
          "section_guid" => "in-review-section"
        }
      ],
      "custom_fields" => []
    }

    context = %{
      section_names_by_guid: %{"in-review-section" => "Building"},
      section_guids_by_name: %{"Building" => "in-review-section"},
      default_section_guids: MapSet.new(),
      custom_field_guids_by_name: %{},
      task_kind_options_by_guid: %{}
    }

    issue = TaskAdapter.normalize_task_payload(task, [], context)

    assert issue.state == "Building"
    assert issue.identifier == "task-2"
  end

  test "fetch_candidate_issues only fetches comments for planning and building tasks and skips failed tasks" do
    FakeTaskClient.reset(fixtures_with_mixed_stages())

    assert {:ok, issues} = TaskAdapter.fetch_candidate_issues()
    assert Enum.map(issues, & &1.id) == ["planning-1", "merging-1", "building-1"]
    assert Enum.map(issues, & &1.state) == ["Planning", "Merging", "Building"]
    assert MapSet.new(FakeTaskClient.calls(:list_comments)) == MapSet.new(["planning-1", "building-1"])
    refute "merging-1" in FakeTaskClient.calls(:list_comments)
    refute "broken-1" in Enum.map(issues, & &1.id)
  end

  test "fetch_candidate_issues reuses cached tasklist context across polls" do
    FakeTaskClient.reset(fixtures_with_mixed_stages())

    assert {:ok, _issues} = TaskAdapter.fetch_candidate_issues()
    assert {:ok, _issues} = TaskAdapter.fetch_candidate_issues()

    assert FakeTaskClient.count(:list_sections) == 1
    assert FakeTaskClient.count(:list_custom_fields) == 1
  end

  test "fetch_issue_states_by_ids also applies selective comment fetching" do
    FakeTaskClient.reset(fixtures_with_mixed_stages())

    assert {:ok, issues} = TaskAdapter.fetch_issue_states_by_ids(["merging-1", "planning-1"])
    assert Enum.map(issues, & &1.id) == ["merging-1", "planning-1"]
    assert FakeTaskClient.calls(:list_comments) == ["planning-1"]
  end

  test "planning comments use the short-lived issue cache to avoid duplicate reads within the same window" do
    FakeTaskClient.reset(fixtures_with_mixed_stages())

    assert {:ok, [_issue]} = TaskAdapter.fetch_issue_states_by_ids(["planning-1"])
    assert %{task_updated_at: "1700000000000"} = TaskAdapter.issue_cache_entry_for_test("planning-1")
    assert {:ok, [_issue]} = TaskAdapter.fetch_issue_states_by_ids(["planning-1"])

    assert FakeTaskClient.calls(:list_comments) == ["planning-1"]
    assert FakeTaskClient.count(:get_task) == 2
  end

  test "comments are only required for planning and building stages" do
    assert TaskAdapter.comments_required_for_stage_for_test("Planning")
    assert TaskAdapter.comments_required_for_stage_for_test("Building")
    refute TaskAdapter.comments_required_for_stage_for_test("Merging")
    refute TaskAdapter.comments_required_for_stage_for_test("Auditing")
    refute TaskAdapter.comments_required_for_stage_for_test("Backlog")
  end

  defp fixtures_with_mixed_stages do
    %{
      task_guids: ["planning-1", "merging-1", "building-1", "broken-1"],
      task_errors: %{"broken-1" => :boom},
      sections: [
        %{"guid" => "planning-section", "name" => "Planning", "is_default" => false},
        %{"guid" => "building-section", "name" => "Building", "is_default" => false},
        %{"guid" => "merging-section", "name" => "Merging", "is_default" => false}
      ],
      custom_fields: [
        %{"guid" => "field-task-key", "name" => "Task Key", "type" => "text"},
        %{"guid" => "field-plan", "name" => "Current Plan", "type" => "text"},
        %{"guid" => "field-workpad", "name" => "Builder Workpad", "type" => "text"},
        %{"guid" => "field-auditor", "name" => "Auditor Verdict", "type" => "text"},
        %{
          "guid" => "field-kind",
          "name" => "Task Kind",
          "type" => "single_select",
          "single_select_setting" => %{"options" => [%{"guid" => "opt-improvement", "name" => "improvement"}]}
        }
      ],
      tasks: %{
        "planning-1" => fake_task("planning-1", "Planning", "planning-section"),
        "merging-1" => fake_task("merging-1", "Merging", "merging-section"),
        "building-1" => fake_task("building-1", "Building", "building-section")
      },
      comments: %{
        "planning-1" => [%{"id" => "cp", "content" => "Human: clarify plan", "created_at" => "1", "updated_at" => "1"}],
        "building-1" => [%{"id" => "cb", "content" => "Planner: rework required", "created_at" => "2", "updated_at" => "2"}],
        "merging-1" => [%{"id" => "cm", "content" => "Should not be fetched", "created_at" => "3", "updated_at" => "3"}]
      }
    }
  end

  defp fake_task(task_guid, summary, section_guid) do
    %{
      "guid" => task_guid,
      "summary" => summary,
      "description" => "#{summary} description",
      "status" => "todo",
      "updated_at" => "1700000000000",
      "url" => "https://example.test/#{task_guid}",
      "tasklists" => [%{"tasklist_guid" => "tasklist-1", "section_guid" => section_guid}],
      "custom_fields" => [
        %{"name" => "Task Key", "type" => "text", "text_value" => "claworld/#{task_guid}"},
        %{"name" => "Current Plan", "type" => "text", "text_value" => "Plan for #{summary}"},
        %{"name" => "Builder Workpad", "type" => "text", "text_value" => "Workpad for #{summary}"},
        %{"name" => "Auditor Verdict", "type" => "text", "text_value" => "Verdict for #{summary}"},
        %{"name" => "Task Kind", "type" => "single_select", "single_select_value" => "opt-improvement"}
      ]
    }
  end
end
