defmodule Featurevisor.Conditions do
  @moduledoc false

  alias Featurevisor.{Bucketer, Semver}

  def parse_conditions("*", _report), do: "*"

  def parse_conditions(value, report) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, parsed} ->
        parsed

      {:error, error} ->
        report.(%{
          level: :error,
          code: "conditions_parse_error",
          message: "Error parsing conditions",
          originalError: error,
          details: %{conditions: value}
        })

        value
    end
  end

  def parse_conditions(value, _report), do: value

  def parse_segments(value) when is_binary(value) do
    if String.starts_with?(value, "{") or String.starts_with?(value, "[") do
      Jason.decode!(value)
    else
      value
    end
  end

  def parse_segments(value), do: value

  def all_conditions?("*", _context, _regex_cache, _report), do: true

  def all_conditions?(conditions, context, regex_cache, report) when is_list(conditions) do
    Enum.all?(conditions, &all_conditions?(&1, context, regex_cache, report))
  end

  def all_conditions?(%{"attribute" => _} = condition, context, regex_cache, report) do
    condition?(condition, context, regex_cache)
  rescue
    error ->
      report.(%{
        level: :warn,
        code: "condition_match_error",
        message: Exception.message(error),
        originalError: error,
        details: %{condition: condition, context: context}
      })

      false
  end

  def all_conditions?(%{"and" => values}, context, cache, report) when is_list(values),
    do: Enum.all?(values, &all_conditions?(&1, context, cache, report))

  def all_conditions?(%{"or" => values}, context, cache, report) when is_list(values),
    do: Enum.any?(values, &all_conditions?(&1, context, cache, report))

  def all_conditions?(%{"not" => []}, _context, _cache, _report), do: false

  def all_conditions?(%{"not" => values}, context, cache, report) when is_list(values),
    do: not Enum.all?(values, &all_conditions?(&1, context, cache, report))

  def all_conditions?(_, _, _, _), do: false

  def all_segments?("*", _context, _segments, _cache, _report), do: true

  def all_segments?(key, context, segments, cache, report) when is_binary(key) do
    case Map.get(segments, key) do
      nil ->
        false

      segment ->
        all_conditions?(parse_conditions(segment["conditions"], report), context, cache, report)
    end
  end

  def all_segments?(values, context, segments, cache, report) when is_list(values),
    do: Enum.all?(values, &all_segments?(&1, context, segments, cache, report))

  def all_segments?(%{"and" => values}, context, segments, cache, report) when is_list(values),
    do: Enum.all?(values, &all_segments?(&1, context, segments, cache, report))

  def all_segments?(%{"or" => values}, context, segments, cache, report) when is_list(values),
    do: Enum.any?(values, &all_segments?(&1, context, segments, cache, report))

  def all_segments?(%{"not" => []}, _, _, _, _), do: false

  def all_segments?(%{"not" => values}, context, segments, cache, report) when is_list(values),
    do: not Enum.all?(values, &all_segments?(&1, context, segments, cache, report))

  def all_segments?(_, _, _, _, _), do: false

  defp condition?(%{"attribute" => attribute, "operator" => operator} = condition, context, cache) do
    context_value = Bucketer.context_value(context, attribute)
    has_context = context_value != :missing
    value = Map.get(condition, "value")

    case operator do
      "equals" ->
        strict_equal?(context_value, value)

      "notEquals" ->
        not strict_equal?(context_value, value)

      "exists" ->
        has_context

      "notExists" ->
        not has_context

      "before" ->
        compare_dates(context_value, value, :lt)

      "after" ->
        compare_dates(context_value, value, :gt)

      "in" ->
        is_list(value) and Enum.any?(value, &strict_equal?(&1, context_value)) and
          primitive?(context_value)

      "notIn" ->
        is_list(value) and primitive?(context_value) and
          not Enum.any?(value, &strict_equal?(&1, context_value))

      "contains" ->
        strings?(context_value, value) and String.contains?(context_value, value)

      "notContains" ->
        strings?(context_value, value) and not String.contains?(context_value, value)

      "startsWith" ->
        strings?(context_value, value) and String.starts_with?(context_value, value)

      "endsWith" ->
        strings?(context_value, value) and String.ends_with?(context_value, value)

      "matches" ->
        strings?(context_value, value) and
          regex_match?(cache, value, Map.get(condition, "regexFlags", ""), context_value)

      "notMatches" ->
        strings?(context_value, value) and
          not regex_match?(cache, value, Map.get(condition, "regexFlags", ""), context_value)

      "greaterThan" ->
        numbers?(context_value, value) and context_value > value

      "greaterThanOrEquals" ->
        numbers?(context_value, value) and context_value >= value

      "lessThan" ->
        numbers?(context_value, value) and context_value < value

      "lessThanOrEquals" ->
        numbers?(context_value, value) and context_value <= value

      "includes" ->
        is_list(context_value) and primitive?(value) and
          Enum.any?(context_value, &strict_equal?(&1, value))

      "notIncludes" ->
        is_list(context_value) and primitive?(value) and
          not Enum.any?(context_value, &strict_equal?(&1, value))

      "semverEquals" ->
        semver(context_value, value, &(&1 == 0))

      "semverNotEquals" ->
        semver(context_value, value, &(&1 != 0))

      "semverGreaterThan" ->
        semver(context_value, value, &(&1 == 1))

      "semverGreaterThanOrEquals" ->
        semver(context_value, value, &(&1 >= 0))

      "semverLessThan" ->
        semver(context_value, value, &(&1 == -1))

      "semverLessThanOrEquals" ->
        semver(context_value, value, &(&1 <= 0))

      _ ->
        false
    end
  end

  defp strict_equal?(left, right) when is_integer(left) and is_float(right), do: left == right
  defp strict_equal?(left, right) when is_float(left) and is_integer(right), do: left == right
  defp strict_equal?(left, right), do: left === right

  defp primitive?(value),
    do: is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value)

  defp strings?(left, right), do: is_binary(left) and is_binary(right)
  defp numbers?(left, right), do: is_number(left) and is_number(right)

  defp compare_dates(left, right, direction) do
    with {:ok, left_date} <- date_time(left), {:ok, right_date} <- date_time(right) do
      DateTime.compare(left_date, right_date) == direction
    else
      _ -> false
    end
  end

  defp date_time(%DateTime{} = value), do: {:ok, value}
  defp date_time(value) when is_binary(value), do: iso_date(value)
  defp date_time(_), do: :error

  defp iso_date(value) do
    if Regex.match?(~r/T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/, value) do
      case DateTime.from_iso8601(value) do
        {:ok, date, _offset} -> {:ok, date}
        error -> error
      end
    else
      :error
    end
  end

  defp semver(left, right, predicate) when is_binary(left) and is_binary(right) do
    case Semver.compare(left, right) do
      value when is_integer(value) -> predicate.(value)
      {:error, message} -> raise ArgumentError, message
    end
  end

  defp semver(_, _, _), do: false

  defp regex_match?(cache, pattern, flags, value) do
    key = {pattern, flags}

    regex =
      case :ets.lookup(cache, key) do
        [{^key, regex}] ->
          regex

        [] ->
          options =
            flags |> String.graphemes() |> Enum.reject(&(&1 == "g")) |> Enum.map(&regex_option!/1)

          {:ok, regex} = Regex.compile(pattern, Enum.join(options))
          :ets.insert_new(cache, {key, regex})
          regex
      end

    Regex.match?(regex, value)
  end

  defp regex_option!("i"), do: "i"
  defp regex_option!("m"), do: "m"
  defp regex_option!("s"), do: "s"

  defp regex_option!(flag),
    do: raise(ArgumentError, "unsupported regular expression flag #{flag}")
end
