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

      [^version | captures] ->
        captures = captures ++ List.duplicate("", 5 - length(captures))
        {:ok, Enum.map(captures, fn value -> if value == "", do: nil, else: value end)}

      _ ->
        {:error, "Invalid argument not valid semver ('#{version}' received)"}
    end
  end

  defp compare_pre(nil, nil), do: 0
  defp compare_pre(nil, _), do: 1
  defp compare_pre(_, nil), do: -1

  defp compare_pre(left, right),
    do: compare_segments(String.split(left, "."), String.split(right, "."), true)

  defp compare_segments(left, right, prerelease \\ false) do
    0..(max(length(left), length(right)) - 1)
    |> Enum.reduce_while(0, fn index, _ ->
      result =
        if prerelease and (index == length(left) or index == length(right)) do
          compare_value(length(left), length(right))
        else
          compare_segment(Enum.at(left, index) || "0", Enum.at(right, index) || "0", prerelease)
        end

      if result == 0, do: {:cont, 0}, else: {:halt, result}
    end)
  end

  defp compare_segment(left, right, prerelease) do
    if not prerelease and (wildcard?(left) or wildcard?(right)) do
      0
    else
      an = Regex.match?(~r/\A[0-9]+\z/, left)
      bn = Regex.match?(~r/\A[0-9]+\z/, right)

      cond do
        an and bn ->
          left = String.trim_leading(left, "0")
          right = String.trim_leading(right, "0")

          case compare_value(byte_size(left), byte_size(right)) do
            0 -> compare_value(left, right)
            result -> result
          end

        prerelease and an != bn ->
          if an, do: -1, else: 1

        true ->
          compare_value(left, right)
      end
    end
  end

  defp wildcard?(value), do: value in ["*", "x", "X"]

  defp compare_value(left, right) when left > right, do: 1
  defp compare_value(left, right) when left < right, do: -1
  defp compare_value(_, _), do: 0
end
