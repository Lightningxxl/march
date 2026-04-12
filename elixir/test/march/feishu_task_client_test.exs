defmodule March.FeishuTaskClientTest do
  use ExUnit.Case, async: true

  alias March.Feishu.TaskClient

  test "decode_cli_output tolerates lark-cli paging prelude lines" do
    output = """
    [page 1] fetching...
    {
      "code": 0,
      "data": {
        "items": [
          {"guid": "task-1"}
        ]
      },
      "msg": "success"
    }
    """

    assert {:ok, %{"data" => %{"items" => [%{"guid" => "task-1"}]}}} =
             TaskClient.decode_cli_output(output)
  end
end
