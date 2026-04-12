defmodule March.Feishu.TaskDescription do
  @moduledoc """
  Parses the human-owned task description surface.

  In the Feishu task protocol, the description is just the human-authored body.
  """

  @type parsed_description :: %{
          raw: String.t(),
          body: String.t() | nil
        }

  @spec parse(String.t() | nil) :: parsed_description()
  def parse(nil), do: %{raw: "", body: nil}

  def parse(description) when is_binary(description) do
    %{
      raw: description,
      body: description |> String.trim() |> blank_to_nil()
    }
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
