defmodule March.FeishuTaskDescriptionTest do
  use ExUnit.Case, async: true

  alias March.Feishu.TaskDescription

  test "parse treats the task description as the human-owned body" do
    description = "Investigate the failing upload flow.\nKeep the relay boundary intact."

    parsed = TaskDescription.parse(description)

    assert parsed.raw == description
    assert parsed.body == description
  end

  test "parse returns nil body for blank descriptions" do
    parsed = TaskDescription.parse("   \n ")

    assert parsed.raw == "   \n "
    assert parsed.body == nil
  end
end
