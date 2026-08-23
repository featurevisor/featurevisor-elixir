defmodule Featurevisor.Semver do
  @moduledoc false

  @pattern ~r/^[v^~<>=]*?(\d+)(?:\.([x*]|\d+)(?:\.([x*]|\d+)(?:\.([x*]|\d+))?(?:-([\da-z-]+(?:\.[\da-z-]+)*))?(?:\+[\da-z-]+(?:\.[\da-z-]+)*)?)?)?$/i

  def compare(left, right) when is_binary(left) and is_binary(right) do
    with {:ok, left_parts} <- parse(left), {:ok, right_parts} <- parse(right) do
      [left_major, left_minor, left_patch, left_fourth, left_pre] = left_parts
      [right_major, right_minor, right_patch, right_fourth, right_pre] = right_parts

      case compare_segments([left_major, left_minor, left_patch, left_fourth], [
             right_major,
             right_minor,
             right_patch,
             right_fourth
           ]) do
        0 -> compare_pre(left_pre, right_pre)
        result -> result
      end
    end
  end

  def compare(_, _), do: {:error, "Invalid argument expected string"}

  defp parse(version) do
    case Regex.run(@pattern, version) do
      nil ->
        {:error, "Invalid argument not valid semver ('#{version}' received)"}

      [_full | captures] ->
        captures = captures ++ List.duplicate("", 5 - length(captures))
        {:ok, Enum.map(captures, fn value -> if value == "", do: nil, else: value end)}
    end
  end

  defp compare_pre(nil, nil), do: 0
  defp compare_pre(nil, _), do: 1
  defp compare_pre(_, nil), do: -1

  defp compare_pre(left, right),
    do: compare_segments(String.split(left, "."), String.split(right, "."))

  defp compare_segments(left, right) do
    0..(max(length(left), length(right)) - 1)
    |> Enum.reduce_while(0, fn index, _ ->
      result = compare_segment(Enum.at(left, index) || "0", Enum.at(right, index) || "0")
      if result == 0, do: {:cont, 0}, else: {:halt, result}
    end)
  end

  defp compare_segment(left, right) do
    if wildcard?(left) or wildcard?(right) do
      0
    else
      {left, right} = force_same_type(try_parse_integer(left), try_parse_integer(right))
      compare_value(left, right)
    end
  end

  defp wildcard?(value), do: value in ["*", "x", "X"]

  defp try_parse_integer(value) do
    case Integer.parse(value) do
      {integer, _rest} -> integer
      :error -> value
    end
  end

  defp force_same_type(left, right) when is_integer(left) != is_integer(right),
    do: {to_string(left), to_string(right)}

  defp force_same_type(left, right), do: {left, right}

  defp compare_value(left, right) when left > right, do: 1
  defp compare_value(left, right) when left < right, do: -1
  defp compare_value(_, _), do: 0
end
