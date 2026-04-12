defmodule March.LogFileTest do
  use ExUnit.Case, async: true

  alias March.LogFile

  test "default_log_file/0 uses the current working directory" do
    assert LogFile.default_log_file() == Path.join(File.cwd!(), "log/march.log")
  end

  test "default_log_file/1 builds the log path under a custom root" do
    assert LogFile.default_log_file("/tmp/march-logs") == "/tmp/march-logs/log/march.log"
  end
end
