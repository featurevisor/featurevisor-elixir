defmodule Featurevisor.CLI.TestChecks do
  @moduledoc false

  alias Featurevisor.CLI.Segments

  @missing {:featurevisor_cli, :missing}
  @max_safe_integer 9_007_199_254_740_991
  @unsafe ["__proto__", "prototype", "constructor"]
  @valueless ["exists", "notExists", "isNull", "notNull", "empty", "notEmpty"]
  @operators @valueless ++ ~w(
    equals notEquals greaterThan greaterThanOrEquals lessThan lessThanOrEquals
    contains notContains startsWith endsWith matches notMatches semverEquals
    semverNotEquals semverGreaterThan semverGreaterThanOrEquals semverLessThan
    semverLessThanOrEquals before after in notIn includes notIncludes includesAny notIncludesAny
  )
  @timestamp_regex ~r/^(?<year>\d{4})-(?<month>\d{2})-(?<day>\d{2})T(?<hour>\d{2}):(?<minute>\d{2}):(?<second>\d{2})(?<fraction>\.\d{1,9})?(?<zone>Z|[+-]\d{2}:\d{2})$/

  def evaluate(evaluator, datafile, checks, owner, diagnostic_ref, prefix \\ "checks") do
    evaluate_result(evaluator, datafile, checks, owner, diagnostic_ref, prefix).failures
  end

  @doc false
  def preflight(datafile, checks, owner, prefix \\ "checks", segment_checks \\ %{})

  def preflight(_datafile, checks, _owner, prefix, _segment_checks)
      when not is_list(checks) or checks == [] do
    message = "#{prefix}: checks must be a nonempty array"

    %{
      passed: false,
      error: true,
      failures: [message],
      report_failures: [validation_report_failure(message, checks, nil)]
    }
  end

  def preflight(datafile, checks, owner, prefix, segment_checks) do
    validation_failures =
      case validate_sibling_keys(checks, prefix) do
        :ok ->
          checks
          |> Enum.with_index()
          |> Enum.reduce([], fn {check, index}, failures ->
            path = "#{prefix}[#{index}]"

            with :ok <- validate_node(check, owner, path),
                 :ok <- validate_references(check, owner, datafile, segment_checks, path) do
              failures
            else
              {:error, message} -> failures ++ [{with_path(path, message), check, index}]
            end
          end)

        {:error, message} ->
          [{message, checks, nil}]
      end

    %{
      passed: validation_failures == [],
      error: validation_failures != [],
      failures: Enum.map(validation_failures, &elem(&1, 0)),
      report_failures:
        Enum.map(validation_failures, fn {message, actual, index} ->
          validation_report_failure(message, actual, index)
        end)
    }
  end

  def evaluate_result(
        evaluator,
        datafile,
        checks,
        owner,
        diagnostic_ref,
        prefix \\ "checks",
        segment_checks \\ %{}
      ) do
    preflight = preflight(datafile, checks, owner, prefix, segment_checks)

    if preflight.error do
      preflight
    else
      {failures, report_failures, error?} =
        checks
        |> Enum.with_index()
        |> Enum.reduce({[], [], false}, fn {check, index}, {failures, report_failures, error?} ->
          path = "#{prefix}[#{index}]"

          evaluation = %{
            evaluator: evaluator,
            datafile: datafile,
            owner: owner,
            ref: diagnostic_ref,
            segment_checks: segment_checks
          }

          case evaluate_node(check, evaluation, path, [index]) do
            {:ok, true, _detail, _evaluated} ->
              {failures, report_failures, error?}

            {:ok, false, detail, evaluated} ->
              message = with_metadata(check, detail)

              {failures ++ [message],
               report_failures ++
                 [report_failure(check, index, message, true, false, evaluated)], error?}

            {:error, message, evaluated} ->
              message = with_metadata(check, with_path(path, message))

              {failures ++ [message],
               report_failures ++
                 [
                   report_failure(
                     check,
                     index,
                     message,
                     "successful comparison",
                     message,
                     evaluated
                   )
                 ], true}
          end
        end)

      %{
        passed: failures == [],
        error: error?,
        failures: failures,
        report_failures: report_failures
      }
    end
  end

  defp validate_references(node, owner, datafile, segment_checks, path) do
    group = Enum.find(["and", "or", "not"], &Map.has_key?(node, &1))

    cond do
      group ->
        node[group]
        |> Enum.with_index()
        |> Enum.reduce_while(:ok, fn {child, index}, :ok ->
          case validate_references(
                 child,
                 owner,
                 datafile,
                 segment_checks,
                 "#{path}.#{group}[#{index}]"
               ) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)

      is_binary(node["segment"]) ->
        validate_segment_definitions(node, segment_checks, path, datafile)

      feature_check?(node) ->
        if Map.has_key?(datafile["features"] || %{}, node["feature"]),
          do: :ok,
          else:
            {:error,
             "#{path}: feature #{inspect(node["feature"])} is absent from the selected datafile"}

      true ->
        with :ok <-
               with_reference_path(validate_reference_membership(node, owner, datafile), path) do
          if Map.has_key?(node, "compareTo") do
            with_reference_path(
              validate_reference_membership(node["compareTo"], owner, datafile),
              "#{path}.compareTo"
            )
          else
            :ok
          end
        end
    end
  end

  defp validate_reference_membership(reference, owner, datafile) do
    variable = reference["variable"] || owner
    feature = reference["feature"]

    cond do
      feature && not Map.has_key?(datafile["features"] || %{}, feature) ->
        {:error, "feature #{inspect(feature)} is absent from the selected datafile"}

      feature &&
          not Map.has_key?(
            get_in(datafile, ["features", feature, "variablesSchema"]) || %{},
            variable
          ) ->
        {:error,
         "variable #{inspect(variable)} is absent from feature #{inspect(feature)} in the selected datafile"}

      is_nil(feature) && not Map.has_key?(datafile["variables"] || %{}, variable) ->
        {:error, "global variable #{inspect(variable)} is absent from the selected datafile"}

      true ->
        :ok
    end
  end

  defp with_reference_path(:ok, _path), do: :ok
  defp with_reference_path({:error, message}, path), do: {:error, "#{path}: #{message}"}

  defp validation_report_failure(message, actual, index) do
    %{
      message: message,
      expected: "valid checks",
      actual: actual,
      check_index: index,
      check_key: nil,
      check_description: nil,
      evaluated: []
    }
  end

  defp report_failure(check, index, message, expected, actual, evaluated) do
    %{
      message: message,
      expected: expected,
      actual: actual,
      check_index: index,
      check_key: check["key"],
      check_description: check["description"],
      evaluated: evaluated
    }
  end

  def diagnostic_handler(target, ref) do
    fn diagnostic -> send(target, {:featurevisor_cli_check_diagnostic, ref, diagnostic}) end
  end

  def diagnostic_module(target, ref) do
    %Featurevisor.Module{
      name: "tester-check-diagnostics",
      after_evaluation: fn evaluation, _options ->
        definition = evaluation.variable_schema || evaluation.variable || %{}

        if not Map.has_key?(definition, "compose") and definition["type"] == "json" and
             is_binary(evaluation.variable_value) and
             match?({:error, _}, Jason.decode(evaluation.variable_value)) do
          send(target, {
            :featurevisor_cli_check_diagnostic,
            ref,
            %{
              level: :error,
              code: "evaluation_error",
              message: "getVariable failed to decode JSON"
            }
          })
        end

        evaluation
      end
    }
  end

  defp validate_node(node, _owner, path) when not is_map(node),
    do: {:error, "#{path}: check must be an object"}

  defp validate_node(node, owner, path) do
    groups = Enum.filter(["and", "or", "not"], &Map.has_key?(node, &1))

    with :ok <- validate_metadata(node, path) do
      validate_node_shape(node, owner, path, groups)
    end
  end

  defp validate_node_shape(node, owner, path, groups) when groups != [] do
    group = hd(groups)
    children = node[group]

    cond do
      length(groups) != 1 or
          Enum.any?(Map.keys(node), &(&1 not in [group, "key", "description"])) ->
        {:error, "#{path}: group must contain exactly one of and, or or not"}

      not is_list(children) or children == [] ->
        {:error, "#{path}.#{group}: group must be a nonempty array"}

      true ->
        with :ok <- validate_sibling_keys(children, "#{path}.#{group}") do
          children
          |> Enum.with_index()
          |> Enum.reduce_while(:ok, fn {child, index}, :ok ->
            case validate_node(child, owner, "#{path}.#{group}[#{index}]") do
              :ok -> {:cont, :ok}
              error -> {:halt, error}
            end
          end)
        end
    end
  end

  defp validate_node_shape(node, owner, path, _groups) do
    cond do
      segment_check?(node) -> validate_segment_check(node, path)
      feature_check?(node) -> validate_feature_check(node, path)
      true -> validate_leaf(node, owner, path)
    end
  end

  defp validate_metadata(node, path) do
    cond do
      Map.has_key?(node, "key") and (not is_binary(node["key"]) or node["key"] == "") ->
        {:error, "#{path}.key: expected a nonempty string"}

      Map.has_key?(node, "description") and not is_binary(node["description"]) ->
        {:error, "#{path}.description: expected a string"}

      true ->
        :ok
    end
  end

  defp validate_sibling_keys(checks, path) do
    checks
    |> Enum.with_index()
    |> Enum.reduce_while(MapSet.new(), fn {check, index}, keys ->
      key = if is_map(check), do: check["key"], else: nil

      if is_binary(key) and MapSet.member?(keys, key),
        do:
          {:halt, {:error, "#{path}[#{index}].key: duplicate sibling check key #{inspect(key)}"}},
        else: {:cont, if(is_binary(key), do: MapSet.put(keys, key), else: keys)}
    end)
    |> case do
      %MapSet{} -> :ok
      error -> error
    end
  end

  defp feature_check?(node) do
    Map.has_key?(node, "enabled") or Map.has_key?(node, "variation") or
      (map_size(node) == 1 and Map.has_key?(node, "feature"))
  end

  defp segment_check?(node),
    do: Map.has_key?(node, "segment") or Map.has_key?(node, "matches")

  defp validate_segment_check(node, path) do
    unknown = Enum.find(Map.keys(node), &(&1 not in ~w(segment matches key description)))

    cond do
      unknown ->
        {:error, "#{path}: segment check cannot contain property #{inspect(unknown)}"}

      not is_binary(node["segment"]) or node["segment"] == "" ->
        {:error, "#{path}: segment must be a nonempty string"}

      not is_boolean(node["matches"]) ->
        {:error, "#{path}: matches must be a boolean"}

      true ->
        :ok
    end
  end

  defp validate_segment_definitions(node, segment_checks, path, datafile) do
    case Segments.preflight(
           node["segment"],
           datafile,
           segment_checks[:definitions] || %{}
         ) do
      :ok -> :ok
      {:error, message} -> {:error, "#{path}: #{message}"}
    end
  end

  defp validate_feature_check(node, path) do
    unknown =
      Enum.find(Map.keys(node), &(&1 not in ~w(feature enabled variation key description)))

    cond do
      unknown ->
        {:error, "#{path}: feature check cannot contain property #{inspect(unknown)}"}

      not is_binary(node["feature"]) or node["feature"] == "" ->
        {:error, "#{path}: feature must be a nonempty string"}

      not Map.has_key?(node, "enabled") and not Map.has_key?(node, "variation") ->
        {:error, "#{path}: feature check requires enabled or variation"}

      Map.has_key?(node, "enabled") and not is_boolean(node["enabled"]) ->
        {:error, "#{path}: enabled must be a boolean"}

      Map.has_key?(node, "variation") and not is_nil(node["variation"]) and
          not is_binary(node["variation"]) ->
        {:error, "#{path}: variation must be a string or null"}

      true ->
        :ok
    end
  end

  defp validate_leaf(node, owner, path) do
    operator = node["operator"]
    allowed = ~w(variable feature path operator value compareTo regexFlags key description)
    unknown = Enum.find(Map.keys(node), &(&1 not in allowed))
    supplied = count_key(node, "value") + count_key(node, "compareTo")

    cond do
      unknown ->
        {:error, "#{path}: unknown check property #{inspect(unknown)}"}

      operator not in @operators ->
        {:error, "#{path}: unknown check operator #{inspect(operator)}"}

      operator in @valueless and supplied != 0 ->
        {:error, "#{path}: operator #{inspect(operator)} accepts neither value nor compareTo"}

      operator not in @valueless and supplied != 1 ->
        {:error, "#{path}: exactly one of value or compareTo is required"}

      Map.has_key?(node, "regexFlags") and operator not in ["matches", "notMatches"] ->
        {:error, "#{path}: regexFlags are only allowed with matches or notMatches"}

      true ->
        with :ok <- validate_reference(node, owner, path),
             :ok <- validate_regex_flags(node, operator, path),
             :ok <- validate_compare_to(node, owner, path) do
          validate_literal(node, operator, path)
        end
    end
  end

  defp validate_compare_to(node, _owner, _path) when not is_map_key(node, "compareTo"), do: :ok

  defp validate_compare_to(node, owner, path) do
    other = node["compareTo"]

    cond do
      not is_map(other) ->
        {:error, "#{path}.compareTo: reference must be an object"}

      Enum.any?(Map.keys(other), &(&1 not in ~w(variable feature path))) ->
        {:error, "#{path}.compareTo: unknown reference property"}

      true ->
        validate_reference(other, owner, "#{path}.compareTo")
    end
  end

  defp validate_reference(reference, owner, path) do
    cond do
      Map.has_key?(reference, "variable") and
          (not is_binary(reference["variable"]) or reference["variable"] == "") ->
        {:error, "#{path}: variable must be a nonempty string"}

      Map.has_key?(reference, "feature") and
          (not is_binary(reference["feature"]) or reference["feature"] == "") ->
        {:error, "#{path}: feature must be a nonempty string"}

      Map.has_key?(reference, "feature") and not Map.has_key?(reference, "variable") ->
        {:error, "#{path}: a feature reference requires an explicit variable"}

      not Map.has_key?(reference, "variable") and is_nil(owner) ->
        {:error, "#{path}: variable reference requires an explicit variable"}

      Map.has_key?(reference, "path") and is_nil(reference["path"]) ->
        {:error, "#{path}: path must not be null"}

      true ->
        case path_parts(reference["path"]) do
          {:ok, _} -> :ok
          error -> error
        end
    end
  end

  defp validate_regex_flags(node, operator, path) do
    if Map.has_key?(node, "regexFlags") do
      if operator in ["matches", "notMatches"] do
        case portable_regex_flags(node["regexFlags"], false) do
          {:ok, _} -> :ok
          {:error, message} -> {:error, "#{path}: #{message}"}
        end
      else
        {:error, "#{path}: regexFlags are only allowed with matches or notMatches"}
      end
    else
      :ok
    end
  end

  defp validate_literal(node, _operator, _path) when not is_map_key(node, "value"), do: :ok

  defp validate_literal(node, operator, path) do
    value = node["value"]

    result =
      cond do
        operator in ["equals", "notEquals"] ->
          if primitive?(value), do: :ok, else: {:error, "requires a scalar literal"}

        operator in ["greaterThan", "greaterThanOrEquals", "lessThan", "lessThanOrEquals"] ->
          if is_number(value), do: :ok, else: {:error, "requires a numeric literal"}

        operator in ["contains", "notContains", "startsWith", "endsWith"] ->
          if is_binary(value), do: :ok, else: {:error, "requires a string literal"}

        operator in ["matches", "notMatches"] ->
          if is_binary(value),
            do: portable_regex(value, node["regexFlags"]),
            else: {:error, "requires a string literal"}

        String.starts_with?(operator, "semver") ->
          if is_binary(value) do
            case Featurevisor.Semver.compare(value, value) do
              compared when is_integer(compared) -> :ok
              {:error, message} -> {:error, message}
            end
          else
            {:error, "requires a string literal"}
          end

        operator in ["before", "after"] ->
          case portable_datetime(value) do
            {:ok, _} -> :ok
            error -> error
          end

        operator in ["includesAny", "notIncludesAny"] ->
          if is_list(value) and Enum.all?(value, &primitive?/1),
            do: :ok,
            else: {:error, "requires a primitive array literal"}

        operator in ["in", "notIn"] ->
          if is_list(value) and Enum.all?(value, &membership_primitive?/1),
            do: :ok,
            else: {:error, "requires a scalar array literal"}

        operator in ["includes", "notIncludes"] ->
          if membership_primitive?(value),
            do: :ok,
            else: {:error, "requires a scalar literal"}

        true ->
          :ok
      end

    case result do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, message} -> {:error, "#{path}: operator #{inspect(operator)} #{message}"}
    end
  end

  defp count_key(map, key), do: if(Map.has_key?(map, key), do: 1, else: 0)

  defp path_parts(nil), do: {:ok, []}

  defp path_parts(path) when is_binary(path) do
    parts = String.split(path, ".")

    if Enum.any?(parts, &(&1 == "")) do
      {:error, "path must not contain empty dot components"}
    else
      parts
      |> Enum.map(fn part ->
        if Regex.match?(~r/^(0|[1-9]\d*)$/, part) do
          index = String.to_integer(part)
          if index <= @max_safe_integer, do: index, else: {:unsafe_index, index}
        else
          part
        end
      end)
      |> validate_path_parts()
    end
  end

  defp path_parts(path) when is_list(path), do: validate_path_parts(path)
  defp path_parts(_), do: {:error, "path must be a dot separated string or an array"}

  defp validate_path_parts(parts) do
    cond do
      Enum.any?(parts, fn part ->
        not is_binary(part) and
            not (is_integer(part) and part >= 0 and part <= @max_safe_integer)
      end) ->
        {:error, "path entries must be string keys or safe nonnegative integer indices"}

      Enum.any?(parts, &(&1 in @unsafe)) ->
        {:error, "unsafe path segment is not allowed"}

      Enum.any?(parts, &(&1 == "*")) ->
        {:error, "wildcards are not allowed in paths"}

      true ->
        {:ok, parts}
    end
  end

  defp evaluate_node(node, evaluation, path, trace_path) do
    case Enum.find(["and", "or", "not"], &Map.has_key?(node, &1)) do
      nil ->
        cond do
          segment_check?(node) -> evaluate_segment_check(node, evaluation, path, trace_path)
          feature_check?(node) -> evaluate_feature_check(node, evaluation, path, trace_path)
          true -> evaluate_leaf(node, evaluation, path, trace_path)
        end

      "or" ->
        evaluate_or(node["or"], evaluation, path, trace_path, 0, [], [])

      group ->
        evaluate_and_index(
          node[group],
          evaluation,
          path,
          trace_path,
          group,
          0,
          []
        )
    end
  end

  defp evaluate_segment_check(node, evaluation, path, trace_path) do
    segment = node["segment"]
    expected = node["matches"]
    segment_checks = evaluation.segment_checks

    key = segment_checks[:keys] && segment_checks.keys[segment]

    drain_diagnostics(evaluation.ref)

    result =
      case evaluation.evaluator do
        %Featurevisor{} = f -> Featurevisor.evaluate_flag(f, key)
        child -> Featurevisor.Child.evaluate_flag(child, key)
      end

    if result.reason == :error, do: raise(result.error)

    error = Enum.find(drain_diagnostics(evaluation.ref), &(to_string(&1.level) == "error"))
    if error, do: raise(ArgumentError, "#{error.code}: #{error.message}")

    actual = result.enabled == true

    evidence =
      %{
        "path" => trace_path,
        "key" => node["key"],
        "description" => node["description"],
        "reference" => %{"segment" => segment},
        "property" => "matches",
        "operator" => "equals",
        "expected" => expected,
        "actual" => actual
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    if actual == expected do
      {:ok, true, "segment #{inspect(segment)} matched", [evidence]}
    else
      {:ok, false,
       "#{path}: segment #{inspect(segment)} expected matches=#{expected}, actual matches=#{actual}",
       [evidence]}
    end
  rescue
    error -> {:error, "#{path}: segment getter failed: #{Exception.message(error)}", []}
  end

  defp evaluate_or(
         [],
         _evaluation,
         _path,
         _trace_path,
         _index,
         details,
         evaluated
       ),
       do: {:ok, false, Enum.join(details, "; "), evaluated}

  defp evaluate_or(
         [child | rest],
         evaluation,
         path,
         trace_path,
         index,
         details,
         evaluated
       ) do
    child_trace_path = trace_path ++ ["or", index]

    case evaluate_node(
           child,
           evaluation,
           "#{path}.or[#{index}]",
           child_trace_path
         ) do
      {:ok, true, detail, child_evaluated} ->
        {:ok, true, detail, evaluated ++ child_evaluated}

      {:ok, false, detail, child_evaluated} ->
        evaluate_or(
          rest,
          evaluation,
          path,
          trace_path,
          index + 1,
          details ++ [with_metadata(child, detail)],
          evaluated ++ child_evaluated
        )

      {:error, message, child_evaluated} ->
        {:error, with_metadata(child, message), evaluated ++ child_evaluated}
    end
  end

  defp evaluate_and_index(
         [],
         _evaluation,
         _path,
         _trace_path,
         "not",
         _index,
         evaluated
       ),
       do: {:ok, false, "NOT group matched all children", evaluated}

  defp evaluate_and_index(
         [],
         _evaluation,
         _path,
         _trace_path,
         _group,
         _index,
         evaluated
       ),
       do: {:ok, true, "AND group matched", evaluated}

  defp evaluate_and_index(
         [child | rest],
         evaluation,
         path,
         trace_path,
         group,
         index,
         evaluated
       ) do
    case evaluate_node(
           child,
           evaluation,
           "#{path}.#{group}[#{index}]",
           trace_path ++ [group, index]
         ) do
      {:ok, false, detail, child_evaluated} when group == "not" ->
        {:ok, true, detail, evaluated ++ child_evaluated}

      {:ok, false, detail, child_evaluated} ->
        {:ok, false, with_metadata(child, detail), evaluated ++ child_evaluated}

      {:ok, true, _detail, child_evaluated} ->
        evaluate_and_index(
          rest,
          evaluation,
          path,
          trace_path,
          group,
          index + 1,
          evaluated ++ child_evaluated
        )

      {:error, message, child_evaluated} ->
        {:error, with_metadata(child, message), evaluated ++ child_evaluated}
    end
  end

  defp evaluate_leaf(node, evaluation, path, trace_path) do
    %{evaluator: evaluator, datafile: datafile, owner: owner, ref: ref} = evaluation
    left_reference = Map.take(node, ["variable", "feature", "path"])
    trace = variable_trace(node, owner, trace_path)

    case resolve(evaluator, datafile, left_reference, owner, ref) do
      {:error, message} ->
        {:error, "#{path}.left(#{reference_label(left_reference, owner)}): #{message}", [trace]}

      {:ok, left} ->
        trace =
          trace
          |> Map.put("actual", report_value(left))
          |> Map.put("actualMissing", left == @missing)

        case right_operand(node, evaluator, datafile, owner, ref) do
          {:error, message} ->
            label = reference_label(node["compareTo"], owner)
            {:error, "#{path}.compareTo(#{label}): #{message}", [trace]}

          {:ok, right, right_label} ->
            trace =
              if Map.has_key?(node, "value") or Map.has_key?(node, "compareTo") do
                trace
                |> Map.put("expected", report_value(right))
                |> Map.put("expectedMissing", right == @missing)
              else
                trace
              end

            case compare(node["operator"], left, right, node["regexFlags"]) do
              {:error, message} ->
                {:error, message, [trace]}

              {:ok, matched} ->
                detail =
                  "#{path}: #{reference_label(left_reference, owner)} #{node["operator"]} #{right_label} failed " <>
                    "(left=#{json(left)}, right=#{json(right)})"

                {:ok, matched, detail, [trace]}
            end
        end
    end
  end

  defp evaluate_feature_check(node, evaluation, path, trace_path) do
    %{evaluator: evaluator, datafile: datafile, ref: ref} = evaluation
    feature = node["feature"]

    case get_in(datafile, ["features", feature]) do
      definition when is_map(definition) ->
        case feature_expectations(node, evaluator, feature, ref, trace_path) do
          {:ok, actual, evaluated} ->
            keys = Enum.filter(["enabled", "variation"], &Map.has_key?(node, &1))
            matched = Enum.all?(keys, &(actual[&1] === node[&1]))

            details =
              Enum.map_join(keys, ", ", fn key ->
                "expected #{key}=#{json(node[key])}, actual #{key}=#{json(actual[key])}"
              end)

            {:ok, matched,
             "#{path}: feature #{inspect(feature)} expectations failed (#{details})", evaluated}

          error ->
            error
        end

      _ ->
        {:error, "feature #{inspect(feature)} is absent from the selected datafile", []}
    end
  end

  defp feature_expectations(node, evaluator, feature, ref, trace_path) do
    Enum.reduce_while(["enabled", "variation"], {:ok, %{}, []}, fn key,
                                                                   {:ok, actual, evaluated} ->
      if Map.has_key?(node, key) do
        trace = feature_trace(node, feature, key, trace_path)

        case feature_getter(evaluator, feature, key, ref) do
          {:ok, value} ->
            {:cont,
             {:ok, Map.put(actual, key, value),
              evaluated ++ [Map.put(trace, "actual", report_value(value))]}}

          {:error, message} ->
            {:halt, {:error, message, evaluated ++ [trace]}}
        end
      else
        {:cont, {:ok, actual, evaluated}}
      end
    end)
  end

  defp feature_getter(evaluator, feature, getter, ref) do
    drain_diagnostics(ref)

    try do
      value = evaluator_feature_get(evaluator, getter, feature)

      case Enum.find(drain_diagnostics(ref, [], 10), &(to_string(&1.level) == "error")) do
        nil ->
          {:ok, value}

        diagnostic ->
          {:error,
           "feature #{inspect(feature)} #{getter} getter reported #{diagnostic.code}: #{diagnostic.message}"}
      end
    rescue
      error ->
        {:error,
         "feature #{inspect(feature)} #{getter} getter failed: #{Exception.message(error)}"}
    end
  end

  defp evaluator_feature_get(%Featurevisor{} = evaluator, "enabled", feature),
    do: Featurevisor.enabled?(evaluator, feature)

  defp evaluator_feature_get(%Featurevisor{} = evaluator, "variation", feature),
    do: Featurevisor.get_variation(evaluator, feature)

  defp evaluator_feature_get(evaluator, "enabled", feature),
    do: Featurevisor.Child.enabled?(evaluator, feature)

  defp evaluator_feature_get(evaluator, "variation", feature),
    do: Featurevisor.Child.get_variation(evaluator, feature)

  defp variable_trace(node, owner, path) do
    %{
      "path" => path,
      "key" => node["key"],
      "description" => node["description"],
      "reference" => report_reference(node, owner),
      "operator" => node["operator"],
      "expected" => if(Map.has_key?(node, "value"), do: node["value"], else: undefined_value()),
      "actual" => "<unresolved>",
      "actualMissing" => false,
      "expectedMissing" => false,
      "compareTo" =>
        if(Map.has_key?(node, "compareTo"),
          do: report_reference(node["compareTo"], owner),
          else: nil
        )
    }
    |> reject_nil_values()
  end

  defp feature_trace(node, feature, property, path) do
    %{
      "path" => path,
      "key" => node["key"],
      "description" => node["description"],
      "reference" => %{"feature" => feature},
      "property" => property,
      "operator" => "equals",
      "expected" => node[property],
      "actual" => "<unresolved>"
    }
    |> reject_nil_values(["expected"])
  end

  defp report_reference(reference, owner) do
    %{
      "variable" => reference["variable"] || owner,
      "feature" => reference["feature"],
      "path" => if(Map.has_key?(reference, "path"), do: reference["path"], else: nil)
    }
    |> reject_nil_values()
  end

  defp reject_nil_values(map, retained_nil_keys \\ []) do
    Map.reject(map, fn {key, value} -> is_nil(value) and key not in retained_nil_keys end)
  end

  defp undefined_value, do: %{"$type" => "undefined"}
  defp report_value(@missing), do: undefined_value()
  defp report_value(value), do: value

  defp right_operand(node, evaluator, datafile, owner, ref) do
    if Map.has_key?(node, "compareTo") do
      case resolve(evaluator, datafile, node["compareTo"], owner, ref) do
        {:ok, value} -> {:ok, value, reference_label(node["compareTo"], owner)}
        error -> error
      end
    else
      {:ok, Map.get(node, "value", @missing), "literal"}
    end
  end

  defp resolve(evaluator, datafile, reference, owner, ref) do
    variable = reference["variable"] || owner
    feature = reference["feature"]

    cond do
      feature && not is_map(get_in(datafile, ["features", feature])) ->
        {:error, "feature #{inspect(feature)} is absent from the selected datafile"}

      feature &&
          not Map.has_key?(
            get_in(datafile, ["features", feature, "variablesSchema"]) || %{},
            variable
          ) ->
        {:error,
         "variable #{inspect(variable)} is absent from feature #{inspect(feature)} in the selected datafile"}

      is_nil(feature) && not Map.has_key?(datafile["variables"] || %{}, variable) ->
        {:error, "global variable #{inspect(variable)} is absent from the selected datafile"}

      true ->
        drain_diagnostics(ref)

        try do
          value =
            if feature,
              do: evaluator_get(evaluator, :feature, feature, variable),
              else: evaluator_get(evaluator, :global, nil, variable)

          case Enum.find(drain_diagnostics(ref, [], 10), &(to_string(&1.level) == "error")) do
            nil ->
              with {:ok, parts} <- path_parts(reference["path"]), do: {:ok, at_path(value, parts)}

            diagnostic ->
              {:error, "variable getter reported #{diagnostic.code}: #{diagnostic.message}"}
          end
        rescue
          error -> {:error, "variable getter failed: #{Exception.message(error)}"}
        end
    end
  end

  defp evaluator_get(%Featurevisor{} = evaluator, :feature, feature, variable),
    do: Featurevisor.get_variable(evaluator, feature, variable)

  defp evaluator_get(%Featurevisor{} = evaluator, :global, _feature, variable),
    do: Featurevisor.get_global_variable(evaluator, variable)

  defp evaluator_get(evaluator, :feature, feature, variable),
    do: Featurevisor.Child.get_variable(evaluator, feature, variable)

  defp evaluator_get(evaluator, :global, _feature, variable),
    do: Featurevisor.Child.get_global_variable(evaluator, variable)

  defp drain_diagnostics(ref, values \\ [], wait \\ 0) do
    receive do
      {:featurevisor_cli_check_diagnostic, ^ref, diagnostic} ->
        drain_diagnostics(ref, values ++ [diagnostic], 0)
    after
      wait -> values
    end
  end

  defp at_path(value, []), do: value

  defp at_path(value, [part | rest]) when is_integer(part) and is_list(value),
    do: at_path(Enum.at(value, part, @missing), rest)

  defp at_path(value, ["length" | rest]) when is_list(value),
    do: at_path(length(value), rest)

  defp at_path(value, [part | rest]) when is_binary(part) and is_list(value) do
    if Regex.match?(~r/^(0|[1-9]\d*)$/, part),
      do: at_path(Enum.at(value, String.to_integer(part), @missing), rest),
      else: @missing
  end

  defp at_path(value, [part | rest]) when is_binary(part) and is_map(value),
    do: at_path(Map.get(value, part, @missing), rest)

  defp at_path(_value, _parts), do: @missing

  defp compare("exists", left, _right, _flags), do: {:ok, left != @missing}
  defp compare("notExists", left, _right, _flags), do: {:ok, left == @missing}
  defp compare("isNull", left, _right, _flags), do: {:ok, is_nil(left)}
  defp compare("notNull", left, _right, _flags), do: {:ok, left != @missing and not is_nil(left)}

  defp compare(operator, left, _right, _flags) when operator in ["empty", "notEmpty"] do
    compare_empty(operator, left)
  end

  defp compare(_operator, @missing, _right, _flags), do: {:ok, false}
  defp compare(_operator, _left, @missing, _flags), do: {:ok, false}

  defp compare(operator, left, right, _flags) when operator in ["equals", "notEquals"] do
    if primitive?(left) and primitive?(right) do
      matched = strict_equal?(left, right)
      {:ok, if(operator == "equals", do: matched, else: not matched)}
    else
      {:error, "operator #{inspect(operator)} only supports scalar values"}
    end
  end

  defp compare(operator, left, right, _flags)
       when operator in ["greaterThan", "greaterThanOrEquals", "lessThan", "lessThanOrEquals"] do
    if is_number(left) and is_number(right) do
      {:ok,
       %{
         "greaterThan" => left > right,
         "greaterThanOrEquals" => left >= right,
         "lessThan" => left < right,
         "lessThanOrEquals" => left <= right
       }[operator]}
    else
      {:error, "operator #{inspect(operator)} requires numeric operands"}
    end
  end

  defp compare(operator, left, right, flags)
       when operator in [
              "contains",
              "notContains",
              "startsWith",
              "endsWith",
              "matches",
              "notMatches"
            ] do
    if is_binary(left) and is_binary(right) do
      case operator do
        "contains" ->
          {:ok, String.contains?(left, right)}

        "notContains" ->
          {:ok, not String.contains?(left, right)}

        "startsWith" ->
          {:ok, String.starts_with?(left, right)}

        "endsWith" ->
          {:ok, String.ends_with?(left, right)}

        regex_operator ->
          with {:ok, regex} <- portable_regex(right, flags) do
            matched = Regex.match?(regex, left)
            {:ok, if(regex_operator == "matches", do: matched, else: not matched)}
          end
      end
    else
      {:error, "operator #{inspect(operator)} requires string operands"}
    end
  end

  defp compare(operator, left, right, _flags)
       when operator in ~w(semverEquals semverNotEquals semverGreaterThan semverGreaterThanOrEquals semverLessThan semverLessThanOrEquals) do
    if is_binary(left) and is_binary(right) do
      case Featurevisor.Semver.compare(left, right) do
        compared when is_integer(compared) ->
          {:ok,
           %{
             "semverEquals" => compared == 0,
             "semverNotEquals" => compared != 0,
             "semverGreaterThan" => compared == 1,
             "semverGreaterThanOrEquals" => compared >= 0,
             "semverLessThan" => compared == -1,
             "semverLessThanOrEquals" => compared <= 0
           }[operator]}

        {:error, message} ->
          {:error, message}
      end
    else
      {:error, "operator #{inspect(operator)} requires string operands"}
    end
  end

  defp compare(operator, left, right, _flags) when operator in ["before", "after"] do
    with {:ok, left_date} <- portable_datetime(left),
         {:ok, right_date} <- portable_datetime(right) do
      {:ok, if(operator == "before", do: left_date < right_date, else: left_date > right_date)}
    else
      _ -> {:error, "date comparisons require valid ISO 8601 strings with a timezone"}
    end
  end

  defp compare(operator, left, right, _flags) when operator in ["in", "notIn"] do
    if membership_primitive?(left) and is_list(right) and
         Enum.all?(right, &membership_primitive?/1) do
      matched = Enum.any?(right, &strict_equal?(left, &1))
      {:ok, if(operator == "in", do: matched, else: not matched)}
    else
      {:error,
       "operator #{inspect(operator)} requires a scalar left operand and scalar array right operand"}
    end
  end

  defp compare(operator, left, right, _flags)
       when operator in ["includesAny", "notIncludesAny"] do
    if is_list(left) and is_list(right) and Enum.all?(right, &primitive?/1) do
      matched =
        Enum.any?(right, fn candidate -> Enum.any?(left, &strict_equal?(&1, candidate)) end)

      {:ok, if(operator == "includesAny", do: matched, else: not matched)}
    else
      {:error,
       "operator #{inspect(operator)} requires an array left operand and primitive array right operand"}
    end
  end

  defp compare(operator, left, right, _flags) when operator in ["includes", "notIncludes"] do
    if is_list(left) and membership_primitive?(right) do
      matched = Enum.any?(left, &strict_equal?(&1, right))
      {:ok, if(operator == "includes", do: matched, else: not matched)}
    else
      {:error,
       "operator #{inspect(operator)} requires a scalar array left operand and scalar right operand"}
    end
  end

  defp compare_empty(_operator, value) when value in [@missing, nil], do: {:ok, false}

  defp compare_empty(operator, value) when is_binary(value) or is_list(value) do
    empty = value == "" or value == []
    {:ok, if(operator == "empty", do: empty, else: not empty)}
  end

  defp compare_empty(operator, value) when is_map(value) and not is_struct(value) do
    if Enum.all?(value, fn {key, _value} -> is_binary(key) end) do
      empty = map_size(value) == 0
      {:ok, if(operator == "empty", do: empty, else: not empty)}
    else
      {:error, "operator #{inspect(operator)} requires a string, array, or object operand"}
    end
  end

  defp compare_empty(operator, _value),
    do: {:error, "operator #{inspect(operator)} requires a string, array, or object operand"}

  defp primitive?(value),
    do: is_nil(value) or is_binary(value) or is_boolean(value) or is_number(value)

  defp membership_primitive?(value), do: is_nil(value) or is_binary(value) or is_number(value)

  defp strict_equal?(left, right) when is_number(left) and is_number(right), do: left == right
  defp strict_equal?(left, right), do: left === right

  defp portable_regex(pattern, flags) do
    with {:ok, flags} <- portable_regex_flags(flags) do
      if Regex.match?(~r/\(\?/, pattern) or
           Regex.match?(~r/\\(?:[1-9]|k<|k'|g<|g')/, pattern) or
           Regex.match?(~r/(?:[?*+]|\{\d+(?:,\d*)?\})\+/, pattern) do
        {:error, "regular expression uses syntax outside the portable subset"}
      else
        case Regex.compile(pattern, String.replace(flags, "g", "")) do
          {:ok, regex} -> {:ok, regex}
          {:error, message} -> {:error, "invalid regular expression: #{inspect(message)}"}
        end
      end
    end
  end

  defp portable_regex_flags(flags, allow_nil \\ true)
  defp portable_regex_flags(nil, true), do: {:ok, ""}

  defp portable_regex_flags(flags, _allow_nil) do
    if is_binary(flags) and Regex.match?(~r/^[gims]*$/, flags) and
         length(String.graphemes(flags)) == length(Enum.uniq(String.graphemes(flags))),
       do: {:ok, flags},
       else: {:error, "regexFlags must contain unique characters from g, i, m and s"}
  end

  defp portable_datetime(value) when is_binary(value) do
    with captures when is_map(captures) <- Regex.named_captures(@timestamp_regex, value),
         {year, ""} <- Integer.parse(captures["year"]),
         true <- year in 1..9999,
         {month, ""} <- Integer.parse(captures["month"]),
         {day, ""} <- Integer.parse(captures["day"]),
         {:ok, _date} <- Date.new(year, month, day),
         {hour, ""} <- Integer.parse(captures["hour"]),
         {minute, ""} <- Integer.parse(captures["minute"]),
         {second, ""} <- Integer.parse(captures["second"]),
         true <- hour in 0..23 and minute in 0..59 and second in 0..59,
         {:ok, offset} <- portable_offset(captures["zone"]),
         instant =
           :calendar.datetime_to_gregorian_seconds({{year, month, day}, {hour, minute, second}}) -
             offset,
         true <- instant >= :calendar.datetime_to_gregorian_seconds({{1, 1, 1}, {0, 0, 0}}),
         true <-
           instant <= :calendar.datetime_to_gregorian_seconds({{9999, 12, 31}, {23, 59, 59}}) do
      fraction = captures["fraction"] || ""

      milliseconds =
        fraction |> String.trim_leading(".") |> String.slice(0, 3) |> String.pad_trailing(3, "0")

      {:ok, {instant, milliseconds}}
    else
      _ -> {:error, "date comparisons require valid portable timestamps"}
    end
  end

  defp portable_datetime(_), do: {:error, "date comparisons require valid portable timestamps"}

  defp portable_offset("Z"), do: {:ok, 0}

  defp portable_offset(
         <<sign::binary-size(1), hour::binary-size(2), ":", minute::binary-size(2)>>
       ) do
    with {hour, ""} <- Integer.parse(hour),
         {minute, ""} <- Integer.parse(minute),
         true <- hour <= 14 and minute <= 59 and (hour < 14 or minute == 0) do
      seconds = hour * 3600 + minute * 60
      {:ok, if(sign == "+", do: seconds, else: -seconds)}
    else
      _ -> {:error, "invalid timestamp offset"}
    end
  end

  defp reference_label(reference, owner) do
    variable = reference["variable"] || owner || "<missing variable>"
    root = if reference["feature"], do: "#{reference["feature"]}.#{variable}", else: variable

    if not Map.has_key?(reference, "path") or reference["path"] == [],
      do: root,
      else: "#{root}:#{json(reference["path"])}"
  end

  defp json(@missing), do: "<missing>"
  defp json(value), do: Jason.encode!(value)

  defp with_path(path, message),
    do: if(String.starts_with?(message, path), do: message, else: "#{path}: #{message}")

  defp with_metadata(check, message) do
    metadata =
      [
        if(is_binary(check["key"]), do: "key=#{inspect(check["key"])}"),
        if(is_binary(check["description"]),
          do: "description=#{inspect(check["description"])}"
        )
      ]
      |> Enum.reject(&is_nil/1)

    if metadata == [], do: message, else: "#{Enum.join(metadata, " ")}: #{message}"
  end
end
