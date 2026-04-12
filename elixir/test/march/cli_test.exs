defmodule March.CLITest do
  use ExUnit.Case, async: true

  alias March.CLI

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  test "returns the guardrails acknowledgement banner when the flag is missing" do
    parent = self()

    deps = %{
      dir?: fn _path ->
        send(parent, :dir_checked)
        false
      end,
      file_regular?: fn _path ->
        send(parent, :file_checked)
        true
      end,
      set_repo_root: fn _path ->
        send(parent, :repo_root_set)
        :ok
      end,
      set_workflow_file_path: fn _path ->
        send(parent, :workflow_set)
        :ok
      end,
      set_logs_root: fn _path ->
        send(parent, :logs_root_set)
        :ok
      end,
      sync_repo: fn _path ->
        send(parent, :repo_synced)
        :ok
      end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:march]}
      end
    }

    assert {:error, banner} = CLI.evaluate(["BUILDER.md"], deps)
    assert banner =~ "March is a low key engineering preview."
    assert banner =~ "Codex will run without any guardrails."
    assert banner =~ "March is not a supported product and is presented as-is."
    assert banner =~ @ack_flag
    refute_received :dir_checked
    refute_received :file_checked
    refute_received :repo_root_set
    refute_received :workflow_set
    refute_received :logs_root_set
    refute_received :repo_synced
    refute_received :started
  end

  test "defaults to current repo dir when target path is missing" do
    deps = %{
      dir?: fn path -> path == File.cwd!() end,
      file_regular?: fn path -> Path.basename(path) in ["MARCH.yml", "BUILDER.md", "PLANNER.md", "AUDITOR.md"] end,
      set_repo_root: fn _path -> :ok end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      sync_repo: fn _path -> :ok end,
      ensure_all_started: fn -> {:ok, [:march]} end
    }

    assert :ok = CLI.evaluate([@ack_flag], deps)
  end

  test "uses an explicit workflow path override when provided" do
    parent = self()
    workflow_path = "tmp/custom/BUILDER.md"
    expanded_path = Path.expand(workflow_path)
    config_path = Path.join(Path.dirname(expanded_path), "MARCH.yml")
    planner_path = Path.join(Path.dirname(expanded_path), "PLANNER.md")
    auditor_path = Path.join(Path.dirname(expanded_path), "AUDITOR.md")

    deps = %{
      dir?: fn _path -> false end,
      file_regular?: fn path ->
        send(parent, {:workflow_checked, path})
        path in [expanded_path, config_path, planner_path, auditor_path]
      end,
      set_repo_root: fn _path -> :ok end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      sync_repo: fn _path -> :ok end,
      ensure_all_started: fn -> {:ok, [:march]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, workflow_path], deps)
    assert_received {:workflow_checked, ^expanded_path}
    assert_received {:workflow_set, ^expanded_path}
  end

  test "accepts --logs-root and passes an expanded root to runtime deps" do
    parent = self()

    deps = %{
      dir?: fn path -> path == Path.expand("tmp/repo") end,
      file_regular?: fn _path -> true end,
      set_repo_root: fn _path -> :ok end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn path ->
        send(parent, {:logs_root, path})
        :ok
      end,
      sync_repo: fn _path -> :ok end,
      ensure_all_started: fn -> {:ok, [:march]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "--logs-root", "tmp/custom-logs", "tmp/repo"], deps)
    assert_received {:logs_root, expanded_path}
    assert expanded_path == Path.expand("tmp/custom-logs")
  end

  test "returns not found when repo dir or builder file does not exist" do
    deps = %{
      dir?: fn _path -> false end,
      file_regular?: fn _path -> false end,
      set_repo_root: fn _path -> :ok end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      sync_repo: fn _path -> :ok end,
      ensure_all_started: fn -> {:ok, [:march]} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "BUILDER.md"], deps)
    assert message =~ "Repository or builder file not found:"
  end

  test "returns startup error when app cannot start" do
    deps = %{
      dir?: fn path -> path == Path.expand("tmp/repo") end,
      file_regular?: fn _path -> true end,
      set_repo_root: fn _path -> :ok end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      sync_repo: fn _path -> :ok end,
      ensure_all_started: fn -> {:error, :boom} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "tmp/repo"], deps)
    assert message =~ "Failed to start March with target"
    assert message =~ ":boom"
  end

  test "returns ok when repo dir exists and app starts" do
    parent = self()

    deps = %{
      dir?: fn path ->
        send(parent, {:dir_checked, path})
        path == Path.expand("tmp/repo")
      end,
      file_regular?: fn _path -> true end,
      set_repo_root: fn path ->
        send(parent, {:repo_root_set, path})
        :ok
      end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      sync_repo: fn path ->
        send(parent, {:repo_synced, path})
        :ok
      end,
      ensure_all_started: fn -> {:ok, [:march]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "tmp/repo"], deps)
    assert_received {:dir_checked, expanded_repo}
    assert_received {:repo_root_set, ^expanded_repo}
    assert_received {:repo_synced, ^expanded_repo}
    assert expanded_repo == Path.expand("tmp/repo")
  end

  test "returns startup check error when canonical repo sync fails" do
    deps = %{
      dir?: fn path -> path == Path.expand("tmp/repo") end,
      file_regular?: fn _path -> true end,
      set_repo_root: fn _path -> :ok end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      sync_repo: fn _path -> {:error, "repo is dirty"} end,
      ensure_all_started: fn -> {:ok, [:march]} end
    }

    assert {:error, "repo is dirty"} = CLI.evaluate([@ack_flag, "tmp/repo"], deps)
  end
end
