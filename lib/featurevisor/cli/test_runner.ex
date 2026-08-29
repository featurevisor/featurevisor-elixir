defmodule Featurevisor.CLI.TestRunner do
  @moduledoc false
  alias Featurevisor.CLI.Project
  alias Featurevisor.{Evaluation, Module}

  def run(options) do
    project = options.project_directory_path

    with {:ok, available_targets} <- Project.targets(project),
         {:ok, targets} <- selected_targets(options.target, available_targets),
         {:ok, tests} <- Project.json(project, "list", ["--tests", "--apply-matrix"]),
         {:ok, environments} <- Project.environments(project),
         {:ok, segments_list} <- Project.json(project, "list", ["--segments"]),
         {:ok, datafiles} <- build_datafiles(project, environments, targets, options.inflate) do
      segments = Map.new(segments_list, &{&1["key"], &1})
      execute(tests, datafiles, segments, targets, options)
    end
  end

  defp selected_targets([], available), do: {:ok, available}

  defp selected_targets(values, available) do
    values = Enum.uniq(values)

    case Enum.find(values, &(&1 not in available)) do
      nil -> {:ok, values}
      unknown -> {:error, "Unknown target \"#{unknown}\""}
    end
  end

  defp build_datafiles(project, environments, targets, inflate) do
    Enum.reduce_while(environments, {:ok, %{}}, fn environment, {:ok, files} ->
      with {:ok, base} <- Project.build(project, environment, nil, inflate),
           {:ok, files} <-
             build_target_datafiles(
               project,
               environment,
               targets,
               inflate,
               Map.put(files, Project.datafile_key(environment, nil), base)
             ) do
        {:cont, {:ok, files}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp build_target_datafiles(project, environment, targets, inflate, files) do
    Enum.reduce_while(targets, {:ok, files}, fn target, {:ok, current} ->
      case Project.build(project, environment, target, inflate) do
        {:ok, datafile} ->
          {:cont, {:ok, Map.put(current, Project.datafile_key(environment, target), datafile)}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp execute(tests, datafiles, segments, targets, options) do
    key_pattern = compile_pattern(options.key_pattern)
    assertion_pattern = compile_pattern(options.assertion_pattern)

    result =
      Enum.reduce(
        tests,
        %{passed_specs: 0, failed_specs: 0, passed_assertions: 0, failed_assertions: 0},
        fn spec, totals ->
          if key_pattern && not Regex.match?(key_pattern, spec["key"] || "") do
            totals
          else
            assertions =
              Enum.filter(
                spec["assertions"] || [],
                &selected_assertion?(&1, targets, assertion_pattern)
              )

            errors = Enum.map(assertions, &run_assertion(spec, &1, datafiles, segments, options))
            failed = Enum.count(errors, &(&1 != []))

            Enum.each(Enum.zip(assertions, errors), fn {assertion, messages} ->
              Enum.each(
                messages,
                &IO.puts(
                  :stderr,
                  "  #{spec["key"]} (#{assertion["description"] || "assertion"}): #{&1}"
                )
              )
            end)

            if assertions == [] do
              totals
            else
              success = failed == 0

              unless options.only_failures or options.quiet or not success,
                do: IO.puts("PASS #{spec["key"]}")

              unless options.quiet or success, do: IO.puts("FAIL #{spec["key"]}")

              totals
              |> Map.update!(if(success, do: :passed_specs, else: :failed_specs), &(&1 + 1))
              |> Map.update!(:passed_assertions, &(&1 + length(assertions) - failed))
              |> Map.update!(:failed_assertions, &(&1 + failed))
            end
          end
        end
      )

    IO.puts("\n---")
    IO.puts("Test specs: #{result.passed_specs} passed, #{result.failed_specs} failed")
    IO.puts("Assertions: #{result.passed_assertions} passed, #{result.failed_assertions} failed")

    cond do
      result.passed_specs + result.failed_specs == 0 ->
        {:error, "No test specs matched the requested filters"}

      result.failed_specs > 0 ->
        {:error, "#{result.failed_specs} test specs failed"}

      true ->
        :ok
    end
  rescue
    error in Regex.CompileError -> {:error, "Invalid test filter: #{Exception.message(error)}"}
  end

  defp selected_assertion?(assertion, targets, pattern) do
    (is_nil(assertion["target"]) or assertion["target"] in targets) and
      (is_nil(pattern) or Regex.match?(pattern, assertion["description"] || ""))
  end

  defp compile_pattern(nil), do: nil
  defp compile_pattern(value), do: Regex.compile!(value, "i")

  defp run_assertion(%{"segment" => segment}, assertion, datafiles, segments, options) do
    datafile = base_datafile(datafiles, assertion["environment"]) |> Map.put("segments", segments)

    f =
      Featurevisor.create_featurevisor(%{
        datafile: datafile,
        context: assertion["context"] || %{},
        log_level: log_level(options)
      })

    actual = Featurevisor.segment_matches?(f, segment)
    Featurevisor.close(f)

    if actual == assertion["expectedToMatch"],
      do: [],
      else: ["expected segment match #{assertion["expectedToMatch"]}, got #{actual}"]
  end

  defp run_assertion(%{"feature" => feature}, assertion, datafiles, _segments, options) do
    datafile =
      datafiles[Project.datafile_key(assertion["environment"], assertion["target"])] ||
        base_datafile(datafiles, assertion["environment"])

    if options.show_datafile, do: IO.puts(Jason.encode!(datafile, pretty: true))

    module = %Module{
      name: "tester",
      bucket_value: fn value ->
        if is_number(assertion["at"]),
          do: trunc(assertion["at"] * 1_000),
          else: value.bucket_value
      end
    }

    f =
      Featurevisor.create_featurevisor(%{
        datafile: datafile,
        context: assertion["context"] || %{},
        sticky_features: assertion["sticky"],
        sticky_variables: assertion["stickyVariables"],
        log_level: log_level(options),
        modules: [module]
      })

    errors = []

    errors =
      compare_present(
        errors,
        assertion,
        "expectedToBeEnabled",
        fn -> Featurevisor.enabled?(f, feature) end,
        feature
      )

    variation_options =
      if Map.has_key?(assertion, "defaultVariationValue"),
        do: %{default_variation_value: assertion["defaultVariationValue"]},
        else: %{}

    errors =
      compare_present(
        errors,
        assertion,
        "expectedVariation",
        fn -> Featurevisor.get_variation(f, feature, %{}, variation_options) end,
        feature
      )

    errors = compare_variables(errors, assertion, f, feature)
    errors = compare_evaluations(errors, assertion, f, feature)
    errors = compare_children(errors, assertion, f, feature)
    Featurevisor.close(f)
    errors
  end

  defp run_assertion(%{"variable" => variable}, assertion, datafiles, _segments, options) do
    datafile =
      datafiles[Project.datafile_key(assertion["environment"], assertion["target"])] ||
        base_datafile(datafiles, assertion["environment"])

    f =
      Featurevisor.create_featurevisor(%{
        datafile: datafile,
        context: assertion["context"] || %{},
        sticky_variables: assertion["stickyVariables"],
        log_level: log_level(options)
      })

    evaluation_options =
      if Map.has_key?(assertion, "defaultVariableValue"),
        do: %{default_variable_value: assertion["defaultVariableValue"]},
        else: %{}

    evaluation = Featurevisor.evaluate_global_variable(f, variable, %{}, evaluation_options)

    errors =
      compare_present(
        [],
        assertion,
        "expectedValue",
        fn -> evaluation.variable_value end,
        variable
      )

    errors =
      compare_evaluation(
        errors,
        assertion["expectedEvaluation"],
        wire(evaluation),
        "#{variable}: variable"
      )

    Featurevisor.close(f)
    errors
  end

  defp compare_present(errors, assertion, key, actual, feature) do
    if Map.has_key?(assertion, key) and actual.() != assertion[key],
      do:
        errors ++
          ["#{feature}: #{key} expected #{inspect(assertion[key])}, got #{inspect(actual.())}"],
      else: errors
  end

  defp compare_variables(errors, assertion, f, feature) do
    Enum.reduce(assertion["expectedVariables"] || %{}, errors, fn {key, expected}, current ->
      options =
        if get_in(assertion, ["defaultVariableValues", key]) != nil or
             (is_map(assertion["defaultVariableValues"]) and
                Map.has_key?(assertion["defaultVariableValues"], key)),
           do: %{default_variable_value: get_in(assertion, ["defaultVariableValues", key])},
           else: %{}

      actual = Featurevisor.get_variable(f, feature, key, %{}, options)

      schema =
        get_in(Featurevisor.get_feature(f, feature) || %{}, ["variablesSchema", key]) || %{}

      expected =
        if schema["type"] == "json" and is_binary(expected),
          do:
            (case Jason.decode(expected) do
               {:ok, value} -> value
               _ -> expected
             end),
          else: expected

      if actual == expected,
        do: current,
        else:
          current ++ ["#{feature}.#{key}: expected #{inspect(expected)}, got #{inspect(actual)}"]
    end)
  end

  defp compare_evaluations(errors, assertion, f, feature) do
    expected = assertion["expectedEvaluations"] || %{}

    errors =
      compare_evaluation(
        errors,
        expected["flag"],
        wire(Featurevisor.evaluate_flag(f, feature)),
        "#{feature}: flag"
      )

    errors =
      compare_evaluation(
        errors,
        expected["variation"],
        wire(Featurevisor.evaluate_variation(f, feature)),
        "#{feature}: variation"
      )

    Enum.reduce(expected["variables"] || %{}, errors, fn {key, value}, current ->
      compare_evaluation(
        current,
        value,
        wire(Featurevisor.evaluate_variable(f, feature, key)),
        "#{feature}: variable #{key}"
      )
    end)
  end

  defp compare_evaluation(errors, nil, _actual, _label), do: errors

  defp compare_evaluation(errors, expected, actual, label) do
    Enum.reduce(expected, errors, fn {key, value}, current ->
      if actual[key] == value,
        do: current,
        else:
          current ++ ["#{label} #{key} expected #{inspect(value)}, got #{inspect(actual[key])}"]
    end)
  end

  defp compare_children(errors, assertion, f, feature) do
    Enum.with_index(assertion["children"] || [])
    |> Enum.reduce(errors, fn {item, index}, current ->
      child =
        Featurevisor.spawn(f, item["context"] || %{}, %{
          sticky_features: item["sticky"] || assertion["sticky"] || %{},
          sticky_variables: item["stickyVariables"] || assertion["stickyVariables"] || %{}
        })

      current =
        compare_present(
          current,
          item,
          "expectedToBeEnabled",
          fn -> Featurevisor.Child.enabled?(child, feature) end,
          "#{feature}: child #{index + 1}"
        )

      current =
        compare_present(
          current,
          item,
          "expectedVariation",
          fn -> Featurevisor.Child.get_variation(child, feature) end,
          "#{feature}: child #{index + 1}"
        )

      current =
        Enum.reduce(item["expectedVariables"] || %{}, current, fn {key, expected}, acc ->
          actual = Featurevisor.Child.get_variable(child, feature, key)

          if actual == expected,
            do: acc,
            else:
              acc ++
                [
                  "#{feature}: child #{index + 1} variable #{key} expected #{inspect(expected)}, got #{inspect(actual)}"
                ]
        end)

      Featurevisor.Child.close(child)
      current
    end)
  end

  defp wire(%Evaluation{} = evaluation),
    do: evaluation |> Evaluation.to_map() |> Jason.encode!() |> Jason.decode!()

  defp base_datafile(datafiles, environment),
    do:
      datafiles[Project.datafile_key(environment, nil)] ||
        Enum.find_value(datafiles, fn {key, value} ->
          if not String.contains?(key, "-target-"), do: value
        end)

  defp log_level(%{verbose: true}), do: :debug
  defp log_level(%{quiet: true}), do: :fatal
  defp log_level(_), do: :error
end
