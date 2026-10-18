defmodule Featurevisor.Conditions do
  @moduledoc false

  alias Featurevisor.{Bucketer, Semver}

  def parse_conditions(value, report, cache \\ nil)
  def parse_conditions("*", _report, _cache), do: "*"

  def parse_conditions(value, report, cache) when is_binary(value) do
    case decode(value, cache) do
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

  def parse_conditions(value, _report, _cache), do: value

  def parse_segments(value, cache \\ nil)

  def parse_segments(value, cache) when is_binary(value) do
    if String.starts_with?(value, "{") or String.starts_with?(value, "[") do
      case decode(value, cache) do
        {:ok, parsed} -> parsed
        {:error, error} -> raise error
      end
    else
      value
    end
  end

  def parse_segments(value, _cache), do: value

  defp decode(value, nil), do: Jason.decode(value)

  defp decode(value, cache) do
    key = {:expression, value}

    case :ets.lookup(cache, key) do
      [{^key, parsed}] ->
        {:ok, parsed}

      [] ->
        case Jason.decode(value) do
          {:ok, parsed} = result ->
            :ets.insert_new(cache, {key, parsed})
            result

          error ->
            error
        end
    end
  end

  def matches?(conditions, options) do
    match_expression(conditions, options)
  catch
    :invalid_conditions -> false
  end

  defp match_expression(:invalid_conditions, _options), do: throw(:invalid_conditions)
  defp match_expression("*", _options), do: true
  defp match_expression([], _options), do: false

  defp match_expression(values, options) when is_list(values),
    do: Enum.all?(values, &match_expression(&1, options))

  defp match_expression(key, options) when is_binary(key) do
    case read_segment(key, options) do
      nil ->
        false

      segment ->
        conditions = segment["conditions"]

        if attribute_only?(conditions),
          do: match_expression(conditions, options),
          else:
            Featurevisor.EvaluationSession.segment(options.session, key, fn ->
              match_expression(conditions, options)
            end)
    end
  end

  defp match_expression(%{"variable" => _} = condition, options),
    do: options.condition_leaf.(condition, options)

  defp match_expression(%{"feature" => _} = condition, options),
    do: options.condition_leaf.(condition, options)

  defp match_expression(%{"attribute" => _} = condition, options),
    do: all_conditions?(condition, options.context, options.regex_cache, options.report)

  defp match_expression(%{"and" => values}, options) when is_list(values),
    do: values != [] and Enum.all?(values, &match_expression(&1, options))

  defp match_expression(%{"or" => values}, options) when is_list(values),
    do: Enum.any?(values, &match_expression(&1, options))

  defp match_expression(%{"not" => values}, options) when is_list(values),
    do: values != [] and not Enum.all?(values, &match_expression(&1, options))

  defp match_expression(_, _), do: false

  defp read_segment(key, %{entity_source: read}), do: read.("segments", key)

  defp read_segment(key, options),
    do:
      Featurevisor.Normalize.get(
        options.datafile,
        "segments",
        key,
        options.regex_cache,
        options.report
      )

  defp attribute_only?("*"), do: false
  defp attribute_only?(%{"attribute" => _}), do: true
  defp attribute_only?(values) when is_list(values), do: Enum.all?(values, &attribute_only?/1)

  defp attribute_only?(value) when is_map(value) do
    Enum.any?(["and", "or", "not"], fn key ->
      is_list(value[key]) and attribute_only?(value[key])
    end)
  end

  defp attribute_only?(_), do: false

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
    case segments[key] do
      nil ->
        false

      segment ->
        all_conditions?(
          parse_conditions(segment["conditions"], report, cache),
          context,
          cache,
          report
        )
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

  defp condition?(
         %{"attribute" => attribute, "operator" => _operator} = condition,
         context,
         cache
       ) do
    context_value = Bucketer.context_value(context, attribute)
    has_context = context_value != :missing

    value_matches?(if(has_context, do: context_value, else: nil), condition, cache, has_context)
  end

  def value_matches?(context_value, %{"operator" => operator} = condition, cache, present \\ true) do
    value = Map.get(condition, "value")

    case operator do
      "equals" ->
        present and strict_equal?(context_value, value)

      "notEquals" ->
        not present or not strict_equal?(context_value, value)

      "exists" ->
        present

      "notExists" ->
        not present

      "isNull" ->
        present and is_nil(context_value)

      "notNull" ->
        present and not is_nil(context_value)

      "empty" ->
        present and empty_value?(context_value, true)

      "notEmpty" ->
        present and empty_value?(context_value, false)

      "before" ->
        compare_dates(context_value, value, :lt)

      "after" ->
        compare_dates(context_value, value, :gt)

      "in" ->
        present and is_list(value) and Enum.any?(value, &strict_equal?(&1, context_value)) and
          in_value?(context_value)

      "notIn" ->
        present and is_list(value) and in_value?(context_value) and
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

      operator when operator in ["includesAny", "notIncludesAny"] ->
        present and is_list(context_value) and is_list(value) and
          Enum.all?(value, &primitive?/1) and
          Enum.any?(value, fn candidate ->
            Enum.any?(context_value, &strict_equal?(&1, candidate))
          end) == (operator == "includesAny")

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

  defp in_value?(value), do: is_binary(value) or is_number(value) or is_nil(value)

  defp strings?(left, right), do: is_binary(left) and is_binary(right)
  defp numbers?(left, right), do: is_number(left) and is_number(right)

  defp empty_value?(value, expected) when is_binary(value), do: value == "" == expected
  defp empty_value?(value, expected) when is_list(value), do: value == [] == expected

  defp empty_value?(value, expected) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn {key, _value} -> is_binary(key) end) and
      map_size(value) == 0 == expected
  end

  defp empty_value?(_value, _expected), do: false

  defp compare_dates(left, right, direction) do
    with {:ok, left_date} <- date_time(left), {:ok, right_date} <- date_time(right) do
      DateTime.compare(left_date, right_date) == direction
    else
      _ -> false
    end
  end

  defp date_time(%DateTime{} = value), do: bounded_date(value)
  defp date_time(value) when is_binary(value), do: iso_date(value)
  defp date_time(_), do: :error

  defp iso_date(value) do
    pattern =
      ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,9})?(?:Z|([+-])([0-9]{2}):([0-9]{2}))\z/

    if Regex.match?(pattern, value) and not String.starts_with?(value, "0000-") and
         valid_date_offset?(value) do
      normalized =
        Regex.replace(~r/(\.[0-9]{3})[0-9]{1,6}(?=Z|[+-][0-9]{2}:[0-9]{2}\z)/, value, "\\1")

      case DateTime.from_iso8601(normalized) do
        {:ok, date, _offset} -> bounded_date(date)
        error -> error
      end
    else
      :error
    end
  end

  defp valid_date_offset?(value) do
    case Regex.run(~r/([+-])([0-9]{2}):([0-9]{2})\z/, value) do
      nil ->
        true

      [_, _, hour, minute] ->
        h = String.to_integer(hour)
        m = String.to_integer(minute)
        (h < 14 and m <= 59) or (h == 14 and m == 0)
    end
  end

  # The year is checked first. Before Elixir 1.17, converting a year beyond 9999 raises.
  defp bounded_date(%DateTime{year: year} = value) when year >= 1 and year <= 9999 do
    milliseconds = DateTime.to_unix(value, :millisecond)

    if abs(value.utc_offset + value.std_offset) <= 14 * 3600 and
         milliseconds >= -62_135_596_800_000 and milliseconds <= 253_402_300_799_999 do
      {:ok, DateTime.truncate(value, :millisecond)}
    else
      :error
    end
  end

  defp bounded_date(_value), do: :error

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

          {:ok, regex} =
            Regex.compile("(*UTF)" <> normalize_portable_regex(pattern), Enum.join(options))

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

  defp normalize_portable_regex(pattern) do
    pattern
    |> String.graphemes()
    |> normalize_regex_chars(false, [])
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp normalize_regex_chars([], _in_class, result), do: result

  defp normalize_regex_chars(["\\", code | rest], in_class, result) do
    replacement =
      case {in_class, code} do
        {true, "d"} -> "0-9"
        {true, "D"} -> "\\x{0}-\\x{2F}\\x{3A}-\\x{10FFFF}"
        {true, "w"} -> "A-Za-z0-9_"
        {true, "W"} -> "\\x{0}-\\x{2F}\\x{3A}-\\x{40}\\x{5B}-\\x{5E}\\x{60}\\x{7B}-\\x{10FFFF}"
        {false, "d"} -> "[0-9]"
        {false, "D"} -> "[^0-9]"
        {false, "w"} -> "(?-i:[A-Za-z0-9_])"
        {false, "W"} -> "(?-i:[^A-Za-z0-9_])"
        _ -> "\\" <> code
      end

    normalize_regex_chars(rest, in_class, [replacement | result])
  end

  defp normalize_regex_chars([char | rest], in_class, result) do
    next_class =
      cond do
        char == "[" and not in_class -> true
        char == "]" and in_class -> false
        true -> in_class
      end

    normalize_regex_chars(rest, next_class, [char | result])
  end
end
