defmodule March.WorkspaceTest do
  use March.TestSupport

  alias March.Workspace

  test "injects canonical branch into workspace hooks" do
    workspace_root =
      Path.join(System.tmp_dir!(), "symphony-elixir-workspace-root-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(workspace_root) end)

    workflow_root = March.Workflow.repo_root()
    marker_path = Path.join(workspace_root, "hook-marker.txt")

    write_workflow_file!(Path.join(workflow_root, "BUILDER.md"),
      repo_canonical_branch: "testing",
      workspace_root: workspace_root,
      hook_after_create: "printf '%s' \"$SYMPHONY_CANONICAL_BRANCH\" > #{marker_path}"
    )

    assert {:ok, workspace} = Workspace.create_for_issue("t100000")
    assert workspace == Path.join(workspace_root, "t100000")
    assert File.read!(marker_path) == "testing"
  end
end
