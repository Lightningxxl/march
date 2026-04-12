defmodule March.FeishuTaskClientTimeoutTest do
  use ExUnit.Case, async: true

  alias March.Feishu.TaskClient

  test "run_command returns a timeout error when the command hangs" do
    assert {:error, {:lark_cli_timeout, 10, ["sh", "-c", "sleep 1"]}} =
             TaskClient.run_command("sh", ["-c", "sleep 1"], 10)
  end

  test "run_command returns command output when the command completes in time" do
    assert {:ok, {"ok\n", 0}} =
             TaskClient.run_command("sh", ["-c", "printf 'ok\\n'"], 1_000)
  end
end
