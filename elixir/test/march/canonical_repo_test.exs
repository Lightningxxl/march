defmodule March.CanonicalRepoTest do
  use ExUnit.Case, async: true

  alias March.CanonicalRepo

  test "returns up_to_date when clean canonical branch already matches origin/testing by default" do
    runner =
      fake_runner(%{
        ["rev-parse", "--is-inside-work-tree"] => {"true\n", 0},
        ["rev-parse", "--abbrev-ref", "HEAD"] => {"testing\n", 0},
        ["status", "--short"] => {"", 0},
        ["fetch", "origin", "testing", "--quiet"] => {"", 0},
        ["rev-list", "--left-right", "--count", "origin/testing...HEAD"] => {"0\t0\n", 0}
      })

    assert {:ok, :up_to_date} = CanonicalRepo.ensure_ready("/tmp/repo", runner: runner)
  end

  test "fast-forwards when local canonical branch is safely behind origin/testing by default" do
    runner =
      fake_runner(%{
        ["rev-parse", "--is-inside-work-tree"] => {"true\n", 0},
        ["rev-parse", "--abbrev-ref", "HEAD"] => {"testing\n", 0},
        ["status", "--short"] => {"", 0},
        ["fetch", "origin", "testing", "--quiet"] => {"", 0},
        ["rev-list", "--left-right", "--count", "origin/testing...HEAD"] => {"2\t0\n", 0},
        ["pull", "--ff-only", "origin", "testing"] => {"Updating abc..def\n", 0}
      })

    assert {:ok, :pulled} = CanonicalRepo.ensure_ready("/tmp/repo", runner: runner)
  end

  test "fails when repo is not on the expected canonical branch" do
    runner =
      fake_runner(%{
        ["rev-parse", "--is-inside-work-tree"] => {"true\n", 0},
        ["rev-parse", "--abbrev-ref", "HEAD"] => {"feature/harness\n", 0}
      })

    assert {:error, message} = CanonicalRepo.ensure_ready("/tmp/repo", runner: runner)
    assert message =~ "must be on testing"
    assert message =~ "feature/harness"
  end

  test "fails when repo has local changes" do
    runner =
      fake_runner(%{
        ["rev-parse", "--is-inside-work-tree"] => {"true\n", 0},
        ["rev-parse", "--abbrev-ref", "HEAD"] => {"testing\n", 0},
        ["status", "--short"] => {" M PLANNER.md\n", 0}
      })

    assert {:error, message} = CanonicalRepo.ensure_ready("/tmp/repo", runner: runner)
    assert message =~ "has uncommitted changes"
    assert message =~ "PLANNER.md"
  end

  test "fails when repo is ahead of origin/testing" do
    runner =
      fake_runner(%{
        ["rev-parse", "--is-inside-work-tree"] => {"true\n", 0},
        ["rev-parse", "--abbrev-ref", "HEAD"] => {"testing\n", 0},
        ["status", "--short"] => {"", 0},
        ["fetch", "origin", "testing", "--quiet"] => {"", 0},
        ["rev-list", "--left-right", "--count", "origin/testing...HEAD"] => {"0\t3\n", 0}
      })

    assert {:error, message} = CanonicalRepo.ensure_ready("/tmp/repo", runner: runner)
    assert message =~ "is ahead of origin/testing"
  end

  test "fails when repo has diverged from origin/testing" do
    runner =
      fake_runner(%{
        ["rev-parse", "--is-inside-work-tree"] => {"true\n", 0},
        ["rev-parse", "--abbrev-ref", "HEAD"] => {"testing\n", 0},
        ["status", "--short"] => {"", 0},
        ["fetch", "origin", "testing", "--quiet"] => {"", 0},
        ["rev-list", "--left-right", "--count", "origin/testing...HEAD"] => {"1\t2\n", 0}
      })

    assert {:error, message} = CanonicalRepo.ensure_ready("/tmp/repo", runner: runner)
    assert message =~ "has diverged from origin/testing"
  end

  test "supports a configured canonical branch other than the default" do
    runner =
      fake_runner(%{
        ["rev-parse", "--is-inside-work-tree"] => {"true\n", 0},
        ["rev-parse", "--abbrev-ref", "HEAD"] => {"release\n", 0},
        ["status", "--short"] => {"", 0},
        ["fetch", "origin", "release", "--quiet"] => {"", 0},
        ["rev-list", "--left-right", "--count", "origin/release...HEAD"] => {"1\t0\n", 0},
        ["pull", "--ff-only", "origin", "release"] => {"Updating abc..def\n", 0}
      })

    assert {:ok, :pulled} =
             CanonicalRepo.ensure_ready("/tmp/repo", runner: runner, branch: "release")
  end

  defp fake_runner(responses) do
    fn _repo_root, args ->
      Map.fetch!(responses, args)
    end
  end
end
