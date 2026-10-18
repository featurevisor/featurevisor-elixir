defmodule Featurevisor.CLI.TestRunner do
  @moduledoc false
  alias Featurevisor.CLI.{Project, Segments, TestChecks, TestCoverage}
  alias Featurevisor.{Evaluation, Module}

  def run(options) do
    project = options.project_directory_path
    coverage = TestCoverage.open(options.coverage)

    try do
      result =
        with :ok <- validate_patterns(options),
             {:ok, sets} <- Project.sets(project, options.set),
             {:ok, tests} <- list_tests(project, sets, options),
             {:ok, environments} <- Project.environments(project),
             {:ok, executions} <- build_executions(project, sets, environments, options),
             {:ok, report} <- execute(tests, executions, sets, coverage, options) do
          output_report(report, options)
        end

      case result do
        {:reported_error, message} ->
          {:error, message}

        {:error, message} ->
          if options.json, do: output_json(error_report(message, options), options.pretty)
          {:error, message}

        other ->
          other
      end
    after
      TestCoverage.close(coverage)
    end
  end

  defp validate_patterns(options) do
    Enum.reduce_while(
      [
        {"--key-pattern", options.key_pattern},
        {"--assertion-pattern", options.assertion_pattern}
      ],
      :ok,
      fn
        {_name, nil}, :ok ->
          {:cont, :ok}

        {name, value}, :ok ->
          case Regex.compile(value, "i") do
            {:ok, _} -> {:cont, :ok}
            {:error, {reason, _}} -> {:halt, {:error, "Invalid #{name}: #{reason}"}}
          end
      end
    )
  end

  defp test_list_args(options, set, case_id) do
    ["--tests", "--execution-protocol", "--apply-matrix", "--execution-metadata"] ++
      if(is_binary(options.entity_type), do: ["--entityType=#{options.entity_type}"], else: []) ++
      set_args(set) ++
      if(is_binary(case_id), do: ["--case=#{case_id}"], else: [])
  end

  defp set_args(nil), do: []
  defp set_args(set), do: ["--set=#{set}"]

  @doc false
  def validate_execution_protocol(%{
        "kind" => "featurevisor.test-execution",
        "schemaVersion" => 1,
        "tests" => tests
      })
      when is_list(tests) do
    if Enum.all?(tests, &is_map/1),
      do: {:ok, tests},
      else: {:error, "Test execution protocol tests must contain only objects"}
  end

  def validate_execution_protocol(%{"kind" => kind})
      when kind != "featurevisor.test-execution",
      do: {:error, "Invalid test execution protocol kind"}

  def validate_execution_protocol(%{"schemaVersion" => version}) when version != 1,
    do: {:error, "Unsupported test execution protocol schemaVersion #{inspect(version)}"}

  def validate_execution_protocol(%{"tests" => tests}) when not is_list(tests),
    do: {:error, "Test execution protocol tests must be an array"}

  def validate_execution_protocol(_), do: {:error, "Invalid test execution protocol envelope"}

  defp list_protocol(project, args) do
    with {:ok, envelope} <- Project.json(project, "list", args) do
      validate_execution_protocol(envelope)
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

  defp list_tests(project, sets, %{case_id: case_id} = options) when is_binary(case_id) do
    if length(sets) == 1 do
      list_protocol(project, test_list_args(options, hd(sets), case_id))
    else
      Enum.reduce_while(sets, {:ok, nil}, fn set, {:ok, nil} ->
        case list_protocol(project, test_list_args(options, set, nil)) do
          {:ok, tests} ->
            matched =
              Enum.any?(tests, fn test ->
                Enum.any?(test["assertions"] || [], fn assertion ->
                  get_in(assertion, ["_case", "id"]) == case_id
                end)
              end)

            if matched,
              do: {:halt, list_protocol(project, test_list_args(options, set, case_id))},
              else: {:cont, {:ok, nil}}

          error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, nil} ->
          list_protocol(project, test_list_args(options, hd(sets), case_id))

        result ->
          result
      end
    end
  end

  defp list_tests(project, sets, options) do
    Enum.reduce_while(sets, {:ok, []}, fn set, {:ok, all} ->
      case list_protocol(project, test_list_args(options, set, nil)) do
        {:ok, tests} when is_list(tests) -> {:cont, {:ok, all ++ tests}}
        error -> {:halt, error}
      end
    end)
  end

  defp build_executions(project, sets, environments, options) do
    Enum.reduce_while(sets, {:ok, %{}}, fn set, {:ok, executions} ->
      with {:ok, available_targets} <- Project.targets(project, set),
           {:ok, targets} <- selected_targets(options.target, available_targets),
           {:ok, segments_list} <-
             Project.json(project, "list", ["--segments"] ++ set_args(set)),
           {:ok, datafiles} <-
             build_datafiles(project, environments, targets, options.inflate, set) do
        execution = %{
          targets: targets,
          segments: Map.new(segments_list, &{&1["key"], &1}),
          datafiles: datafiles
        }

        {:cont, {:ok, Map.put(executions, set, execution)}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp build_datafiles(project, environments, targets, inflate, set) do
    Enum.reduce_while(environments, {:ok, %{}}, fn environment, {:ok, files} ->
      with {:ok, base} <- Project.build(project, environment, nil, inflate, set),
           {:ok, files} <-
             build_target_datafiles(
               project,
               environment,
               targets,
               inflate,
               Map.put(files, Project.datafile_key(environment, nil), base),
               set
             ) do
        {:cont, {:ok, files}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp build_target_datafiles(project, environment, targets, inflate, files, set) do
    Enum.reduce_while(targets, {:ok, files}, fn target, {:ok, current} ->
      case Project.build(project, environment, target, inflate, set) do
        {:ok, datafile} ->
          {:cont, {:ok, Map.put(current, Project.datafile_key(environment, target), datafile)}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp execute(tests, executions, sets, coverage, options) do
    key_pattern = compile_pattern(options.key_pattern)
    assertion_pattern = compile_pattern(options.assertion_pattern)

    with {:ok, results} <-
           Enum.reduce_while(tests, {:ok, []}, fn spec, {:ok, results} ->
             if key_pattern && not Regex.match?(key_pattern, entity_key(spec)) do
               {:cont, {:ok, results}}
             else
               with {:ok, metadata} <- test_metadata(spec),
                    {:ok, execution} <- fetch_execution(executions, metadata.set),
                    {:ok, result} <-
                      execute_spec(
                        spec,
                        metadata,
                        execution,
                        assertion_pattern,
                        coverage,
                        options
                      ) do
                 {:cont, {:ok, if(is_nil(result), do: results, else: results ++ [result])}}
               else
                 error -> {:halt, error}
               end
             end
           end) do
      summary = summary(results)

      errors =
        if summary["specs"]["passed"] + summary["specs"]["failed"] == 0,
          do: [%{"message" => "No test specs matched the requested filters"}],
          else: []

      with {:ok, uncovered} <- maybe_uncovered(options, sets) do
        report = %{
          "schemaVersion" => 1,
          "runner" => "elixir",
          "passed" => summary["specs"]["failed"] == 0 and errors == [],
          "summary" => summary,
          "results" => results,
          "errors" => errors
        }

        report = if is_nil(uncovered), do: report, else: Map.put(report, "uncovered", uncovered)

        report =
          if options.coverage do
            Map.put(report, "coverage", %{
              "mode" => "observed-selections",
              "selections" => TestCoverage.selections(coverage)
            })
          else
            report
          end

        {:ok, report}
      end
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

  defp entity_key(%{"_test" => %{"entityType" => entity_type}} = spec)
       when is_binary(entity_type),
       do: spec[entity_type] || spec["key"] || ""

  defp entity_key(spec), do: spec["key"] || ""

  defp test_metadata(%{"_test" => metadata}) when is_map(metadata) do
    with source when is_binary(source) <- metadata["source"],
         entity_type when is_binary(entity_type) <- metadata["entityType"],
         set when is_nil(set) or is_binary(set) <- metadata["set"] do
      {:ok, %{source: String.replace(source, "\\", "/"), set: set, entity_type: entity_type}}
    else
      _ -> {:error, "Node test listing returned invalid _test metadata"}
    end
  end

  defp test_metadata(_),
    do: {:error, "Node test listing did not include requested _test metadata"}

  defp case_metadata(%{"_case" => metadata}) when is_map(metadata) do
    with id when is_binary(id) and id != "" <- metadata["id"],
         assertion_index when is_integer(assertion_index) and assertion_index >= 0 <-
           metadata["assertionIndex"],
         matrix_values when is_map(matrix_values) <- metadata["matrixValues"] do
      {:ok, %{id: id, assertion_index: assertion_index, matrix_values: matrix_values}}
    else
      _ -> {:error, "Node test listing returned invalid _case metadata"}
    end
  end

  defp case_metadata(_),
    do: {:error, "Node test listing did not include requested _case metadata"}

  defp fetch_execution(executions, set) do
    case Map.fetch(executions, set) do
      {:ok, execution} -> {:ok, execution}
      :error -> {:error, "Missing native execution state for set #{inspect(set)}"}
    end
  end

  defp execute_spec(spec, metadata, execution, pattern, coverage, options) do
    case spec["assertions"] do
      assertions when is_list(assertions) ->
        assertions = Enum.filter(assertions, &selected_assertion?(&1, execution.targets, pattern))

        Enum.reduce_while(assertions, {:ok, []}, fn assertion, {:ok, cases} ->
          case case_metadata(assertion) do
            {:ok, case_metadata} ->
              coverage_metadata = %{
                "set" => metadata.set,
                "environment" => assertion["environment"],
                "target" => assertion["target"]
              }

              discriminators =
                Enum.filter(
                  ["feature", "variable", "segment", "scenario"],
                  &Map.has_key?(spec, &1)
                )

              errors =
                if length(discriminators) == 1 do
                  run_assertion(
                    spec,
                    assertion,
                    execution.datafiles,
                    execution.segments,
                    coverage,
                    coverage_metadata,
                    options,
                    %{
                      entity_type: metadata.entity_type,
                      assertion_index: case_metadata.assertion_index
                    }
                  )
                else
                  ["test spec requires exactly one of feature, variable, segment or scenario"]
                end

              rerun_args =
                ["test", "--case=#{case_metadata.id}"] ++
                  if(is_binary(options.project_directory_path_argument),
                    do: ["--projectDirectoryPath=#{options.project_directory_path_argument}"],
                    else: []
                  ) ++ set_args(metadata.set)

              rerun_args =
                rerun_args ++
                  Enum.map(Enum.uniq(options.target), &"--target=#{&1}")

              result = %{
                "id" => case_metadata.id,
                "description" => assertion["description"],
                "environment" => assertion["environment"],
                "target" => assertion["target"],
                "context" =>
                  if(is_map(assertion["context"]), do: assertion["context"], else: %{}),
                "matrixValues" => case_metadata.matrix_values,
                "passed" => errors == [],
                "errors" =>
                  Enum.map(errors, &normalize_report_error(&1, case_metadata.assertion_index)),
                "rerun" => %{"command" => "./featurevisor", "args" => rerun_args}
              }

              {:cont, {:ok, cases ++ [result]}}

            error ->
              {:halt, error}
          end
        end)
        |> case do
          {:ok, []} ->
            {:ok, nil}

          {:ok, cases} ->
            {:ok,
             %{
               "type" => metadata.entity_type,
               "key" => entity_key(spec),
               "source" => metadata.source,
               "set" => metadata.set,
               "passed" => Enum.all?(cases, & &1["passed"]),
               "cases" => cases
             }}

          error ->
            error
        end

      _ ->
        {:error, "Test #{inspect(spec["key"])} needs an assertions array"}
    end
  end

  defp summary(results) do
    initial = %{
      "specs" => counts(),
      "assertions" => counts(),
      "entitySpecs" => counts(),
      "entityAssertions" => counts(),
      "scenarioSpecs" => counts(),
      "scenarioCases" => counts()
    }

    Enum.reduce(results, initial, fn result, summary ->
      scenario? = result["type"] == "scenario"
      spec_key = if scenario?, do: "scenarioSpecs", else: "entitySpecs"
      case_key = if scenario?, do: "scenarioCases", else: "entityAssertions"
      spec_outcome = if result["passed"], do: "passed", else: "failed"
      passed_cases = Enum.count(result["cases"], & &1["passed"])
      failed_cases = length(result["cases"]) - passed_cases

      summary
      |> increment("specs", spec_outcome, 1)
      |> increment(spec_key, spec_outcome, 1)
      |> increment("assertions", "passed", passed_cases)
      |> increment("assertions", "failed", failed_cases)
      |> increment(case_key, "passed", passed_cases)
      |> increment(case_key, "failed", failed_cases)
    end)
  end

  defp counts, do: %{"passed" => 0, "failed" => 0}

  defp increment(summary, group, outcome, amount),
    do: put_in(summary, [group, outcome], summary[group][outcome] + amount)

  defp maybe_uncovered(%{uncovered: false}, _sets), do: {:ok, nil}

  defp maybe_uncovered(options, sets) do
    Enum.reduce_while(sets, {:ok, []}, fn set, {:ok, values} ->
      with {:ok, features} <-
             Project.json(
               options.project_directory_path,
               "list",
               ["--features", "--without-tests"] ++ set_args(set)
             ),
           {:ok, variables} <-
             Project.json(
               options.project_directory_path,
               "list",
               ["--variables", "--without-tests"] ++ set_args(set)
             ) do
        gap = %{
          "set" => set,
          "features" => sorted_keys(features),
          "variables" => sorted_keys(variables)
        }

        {:cont, {:ok, values ++ [gap]}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp sorted_keys(values) when is_list(values) do
    values |> Enum.map(& &1["key"]) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()
  end

  defp sorted_keys(_), do: []

  defp normalize_report_error(message, _index) when is_binary(message),
    do: %{"message" => message}

  defp normalize_report_error(%{"type" => "check"} = error, _index), do: error

  defp normalize_report_error(error, index) when is_map(error),
    do: Map.update(error, "path", ["assertions", index], &(["assertions", index] ++ &1))

  defp expectation_error(type, path, expected, actual) do
    %{
      "type" => type,
      "path" => path,
      "expected" => expected,
      "actual" => actual,
      "message" => "expected #{inspect(expected)}, received #{inspect(actual)}"
    }
  end

  defp child_errors(errors, index) do
    Enum.map(errors, &Map.update!(&1, "path", fn path -> ["children", index] ++ path end))
  end

  defp check_report_errors(result, authored, child_index \\ nil) do
    base =
      if authored.entity_type == "scenario",
        do: [],
        else: ["assertions", authored.assertion_index]

    base = if is_integer(child_index), do: base ++ ["children", child_index], else: base
    base = base ++ ["checks"]

    Enum.map(result.report_failures, fn failure ->
      path =
        if is_integer(failure.check_index),
          do: base ++ [failure.check_index],
          else: base

      evaluated =
        Enum.map(failure.evaluated, fn leaf ->
          Map.put(leaf, "path", base ++ (leaf["path"] || []))
        end)

      details =
        %{
          "checkIndex" => failure.check_index,
          "checkKey" => failure.check_key,
          "checkDescription" => failure.check_description,
          "evaluated" => evaluated
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      %{
        "message" => failure.message,
        "type" => "check",
        "path" => path,
        "expected" => failure.expected,
        "actual" => failure.actual,
        "details" => details
      }
    end)
  end

  defp output_report(report, options) do
    if options.json, do: output_json(report, options.pretty), else: output_human(report, options)

    if report["passed"],
      do: :ok,
      else:
        {:reported_error,
         get_in(report, ["errors", Access.at(0), "message"]) ||
           "#{report["summary"]["specs"]["failed"]} test specs failed"}
  end

  defp output_json(report, pretty),
    do: IO.puts(Jason.encode!(report, pretty: pretty, escape: :unicode_safe))

  defp output_human(report, options) do
    unless options.quiet do
      Enum.each(report["results"], fn result ->
        if not result["passed"] or not options.only_failures do
          label = if result["type"] == "scenario", do: "scenario ", else: ""
          set = if result["set"], do: " [set #{result["set"]}]", else: ""

          IO.puts(
            "#{if(result["passed"], do: "PASS", else: "FAIL")} #{label}#{result["key"]}#{set}"
          )
        end

        result["cases"]
        |> Enum.with_index()
        |> Enum.reject(fn {test_case, _index} ->
          options.only_failures and test_case["passed"]
        end)
        |> Enum.each(fn {test_case, index} ->
          kind = "check"
          description = test_case["description"] || "assertion"
          label = human_case_label(test_case, index)
          IO.puts("  #{if(test_case["passed"], do: "✔", else: "✘")} #{label}")

          Enum.each(test_case["errors"], fn error ->
            IO.puts(
              :stderr,
              "  #{result["key"]} (#{description}) #{kind}: #{human_check_message(error["message"])}"
            )
          end)

          unless test_case["passed"] do
            rerun = test_case["rerun"]
            command = Enum.map_join(rerun["args"], " ", &shell_arg/1)
            IO.puts(:stderr, "  Rerun (POSIX shell): #{rerun["command"]} #{command}")
          end
        end)
      end)
    end

    summary = report["summary"]
    IO.puts("\n---")
    print_counts("Entity specs", summary["entitySpecs"])
    print_counts("Entity assertions", summary["entityAssertions"])
    print_counts("Scenario specs", summary["scenarioSpecs"])
    print_counts("Scenario cases", summary["scenarioCases"])
    print_counts("Total cases", summary["assertions"])

    if report["uncovered"] do
      IO.puts("\nDefinitions without associated specs (not evaluation coverage):")

      Enum.each(report["uncovered"], fn entry ->
        if entry["set"], do: IO.puts("  Set: #{entry["set"]}")
        IO.puts("  Features: #{Enum.join(entry["features"], ", ") |> none_if_empty()}")
        IO.puts("  Global variables: #{Enum.join(entry["variables"], ", ") |> none_if_empty()}")
      end)
    end

    if report["coverage"] do
      IO.puts("\nObserved rule and override selections (not branch coverage):")
      selections = report["coverage"]["selections"]
      Enum.each(selections, &IO.puts("  #{human_coverage_selection(&1)}"))
      if selections == [], do: IO.puts("  No selections observed")
    end
  end

  defp none_if_empty(""), do: "none"
  defp none_if_empty(value), do: value

  defp human_check_message(message) do
    Regex.replace(~r/\b(checks|children)\[(\d+)\]/, message, fn _, kind, index ->
      "#{if(kind == "children", do: "Child", else: "check")} #{String.to_integer(index) + 1}"
    end)
  end

  defp human_case_label(test_case, index) do
    label = test_case["description"] || "assertion #{index + 1}"
    details = ["case #{index + 1}"]
    matrix = test_case["matrixValues"] || %{}

    details =
      if map_size(matrix) > 0 do
        values =
          Enum.map_join(matrix, ", ", fn {key, value} -> "#{key}=#{Jason.encode!(value)}" end)

        details ++ ["matrix #{values}"]
      else
        details
      end

    details =
      if test_case["target"], do: details ++ ["target #{test_case["target"]}"], else: details

    "#{label} (#{Enum.join(details, "; ")})"
  end

  defp human_coverage_selection(selection) do
    owner =
      if selection["featureKey"] do
        "feature #{selection["featureKey"]}" <>
          if(selection["variableKey"], do: " variable #{selection["variableKey"]}", else: "")
      else
        "global variable #{selection["variableKey"]}"
      end

    scope =
      Enum.filter(
        [
          selection["set"] && "set #{selection["set"]}",
          selection["environment"] && "environment #{selection["environment"]}",
          selection["target"] && "target #{selection["target"]}"
        ],
        & &1
      )

    picks =
      Enum.filter(
        [
          selection["ruleKey"] && "rule #{selection["ruleKey"]}",
          Map.has_key?(selection, "variation") &&
            "variation #{Jason.encode!(selection["variation"])}",
          selection["overridePath"] && "override #{Enum.join(selection["overridePath"], " > ")}",
          is_integer(selection["overrideIndex"]) && "override #{selection["overrideIndex"] + 1}"
        ],
        & &1
      )

    owner <>
      if(scope == [], do: "", else: " (#{Enum.join(scope, ", ")})") <>
      ": #{Enum.join(picks, ", ")}"
  end

  defp print_counts(label, counts),
    do: IO.puts("#{label}: #{counts["passed"]} passed, #{counts["failed"]} failed")

  defp shell_arg(value) do
    if Regex.match?(~r/^[A-Za-z0-9_\-\.\/:=]+$/, value),
      do: value,
      else: "'#{String.replace(value, "'", "'\\''")}'"
  end

  defp error_report(message, options) do
    report = %{
      "schemaVersion" => 1,
      "runner" => "elixir",
      "passed" => false,
      "summary" => summary([]),
      "results" => [],
      "errors" => [%{"message" => message}]
    }

    report = if options.uncovered, do: Map.put(report, "uncovered", []), else: report

    if options.coverage,
      do:
        Map.put(report, "coverage", %{
          "mode" => "observed-selections",
          "selections" => []
        }),
      else: report
  end

  defp run_assertion(
         _spec,
         %{"__invalidDiscriminator" => true},
         _datafiles,
         _segments,
         _coverage,
         _coverage_metadata,
         _options,
         _authored
       ),
       do: ["test spec requires exactly one of feature, variable, segment or scenario"]

  defp run_assertion(
         %{"segment" => segment} = spec,
         assertion,
         datafiles,
         segments,
         coverage,
         coverage_metadata,
         options,
         authored
       ) do
    definitions = spec["_segments"] || segments
    selected = datafiles[Project.datafile_key(assertion["environment"], assertion["target"])]

    needs_datafile =
      not is_nil(assertion["environment"]) or not is_nil(assertion["target"]) or
        Segments.dependent?(segment, definitions)

    if is_nil(selected) and needs_datafile do
      [missing_datafile_message(assertion)]
    else
      datafile = selected || Segments.empty()

      with :ok <- Segments.preflight(segment, datafile, definitions),
           [] <- preflight_assertion_tree(spec, assertion, datafile, nil, false, authored) do
        {datafile, keys} = Segments.prepare(datafile, definitions)

        module = %Module{
          bucket_value: fn value ->
            if is_number(assertion["at"]),
              do: trunc(assertion["at"] * 1_000),
              else: value.bucket_value
          end
        }

        diagnostic_ref = make_ref()
        diagnostic_target = self()

        f =
          Featurevisor.create_featurevisor(%{
            datafile: datafile,
            context: assertion["context"] || %{},
            sticky_features: assertion["stickyFeatures"],
            sticky_variables: assertion["stickyVariables"],
            log_level: if(options.verbose, do: :debug, else: :error),
            on_diagnostic: TestChecks.diagnostic_handler(diagnostic_target, diagnostic_ref),
            modules:
              modules(
                [module, TestChecks.diagnostic_module(diagnostic_target, diagnostic_ref)],
                coverage,
                coverage_metadata,
                Map.values(keys)
              )
          })

        try do
          result = Featurevisor.evaluate_flag(f, keys[segment])
          errors = segment_errors(diagnostic_ref)

          cond do
            errors != [] ->
              errors

            result.reason == :error ->
              [Exception.message(result.error)]

            result.enabled == true == assertion["expectedToMatch"] ->
              []

            true ->
              [
                expectation_error(
                  "segment",
                  ["expectedToMatch"],
                  assertion["expectedToMatch"],
                  result.enabled == true
                )
              ]
          end
        after
          Featurevisor.close(f)
        end
      else
        {:error, message} -> [message]
        errors -> errors
      end
    end
  end

  defp run_assertion(
         %{"feature" => feature},
         assertion,
         datafiles,
         _segments,
         coverage,
         coverage_metadata,
         options,
         _authored
       ) do
    datafile =
      datafiles[Project.datafile_key(assertion["environment"], assertion["target"])]

    if is_nil(datafile) do
      [missing_datafile_message(assertion)]
    else
      run_feature_assertion(feature, assertion, datafile, coverage, coverage_metadata, options)
    end
  end

  defp run_assertion(
         %{"variable" => variable} = spec,
         assertion,
         datafiles,
         _segments,
         coverage,
         coverage_metadata,
         options,
         authored
       ) do
    datafile =
      datafiles[Project.datafile_key(assertion["environment"], assertion["target"])]

    if is_nil(datafile) do
      [missing_datafile_message(assertion)]
    else
      run_variable_assertion(
        spec,
        variable,
        assertion,
        datafile,
        coverage,
        coverage_metadata,
        options,
        authored
      )
    end
  end

  defp run_assertion(
         %{"scenario" => _scenario} = spec,
         assertion,
         datafiles,
         _segments,
         coverage,
         coverage_metadata,
         options,
         authored
       ) do
    datafile = datafiles[Project.datafile_key(assertion["environment"], assertion["target"])]

    if is_nil(datafile),
      do: [missing_datafile_message(assertion)],
      else:
        run_scenario_assertion(
          spec,
          assertion,
          datafile,
          coverage,
          coverage_metadata,
          options,
          authored
        )
  end

  defp run_feature_assertion(feature, assertion, datafile, coverage, coverage_metadata, options) do
    if options.show_datafile, do: IO.puts(:stderr, Jason.encode!(datafile, pretty: true))

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
        sticky_features: assertion["stickyFeatures"],
        sticky_variables: assertion["stickyVariables"],
        log_level: check_log_level(options, assertion),
        modules: modules([module], coverage, coverage_metadata)
      })

    try do
      errors =
        compare_present(
          [],
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

      errors
      |> compare_variables(assertion, f, feature)
      |> compare_evaluations(assertion, f, feature)
      |> compare_children(assertion, f, feature)
    after
      Featurevisor.close(f)
    end
  end

  defp run_variable_assertion(
         spec,
         variable,
         assertion,
         datafile,
         coverage,
         coverage_metadata,
         options,
         authored
       ) do
    case preflight_assertion_tree(spec, assertion, datafile, variable, false, authored) do
      [] ->
        do_run_variable_assertion(
          spec,
          variable,
          assertion,
          datafile,
          coverage,
          coverage_metadata,
          options,
          authored
        )

      errors ->
        errors
    end
  end

  defp do_run_variable_assertion(
         spec,
         variable,
         assertion,
         datafile,
         coverage,
         coverage_metadata,
         options,
         authored
       ) do
    if options.show_datafile, do: IO.puts(:stderr, Jason.encode!(datafile, pretty: true))

    module = %Module{
      name: "tester",
      bucket_value: fn value ->
        if is_number(assertion["at"]),
          do: trunc(assertion["at"] * 1_000),
          else: value.bucket_value
      end
    }

    diagnostic_ref = make_ref()
    diagnostic_target = self()

    {datafile, segment_keys} = Segments.prepare(datafile, spec["_segments"] || %{})
    root_context = assertion["context"] || %{}

    f =
      Featurevisor.create_featurevisor(%{
        datafile: datafile,
        context: root_context,
        sticky_features: assertion["stickyFeatures"],
        sticky_variables: assertion["stickyVariables"],
        log_level: check_log_level(options, assertion),
        on_diagnostic: TestChecks.diagnostic_handler(diagnostic_target, diagnostic_ref),
        modules:
          modules(
            [module, TestChecks.diagnostic_module(diagnostic_target, diagnostic_ref)],
            coverage,
            coverage_metadata,
            Map.values(segment_keys)
          )
      })

    evaluation_options =
      if Map.has_key?(assertion, "defaultVariableValue"),
        do: %{default_variable_value: assertion["defaultVariableValue"]},
        else: %{}

    try do
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

      errors =
        if Map.has_key?(assertion, "checks") do
          errors ++
            check_report_errors(
              TestChecks.evaluate_result(
                f,
                datafile,
                assertion["checks"],
                variable,
                diagnostic_ref,
                "checks",
                segment_check_options(segment_keys, spec, root_context)
              ),
              authored
            )
        else
          errors
        end

      compare_variable_children(
        errors,
        assertion,
        f,
        variable,
        %{
          datafile: datafile,
          diagnostic_ref: diagnostic_ref,
          authored: authored,
          segment_evaluator: segment_keys,
          spec: spec,
          root_context: root_context
        }
      )
    after
      Featurevisor.close(f)
    end
  end

  defp compare_variable_children(
         errors,
         assertion,
         f,
         variable,
         check_execution
       ) do
    Enum.with_index(assertion["children"] || [])
    |> Enum.reduce(errors, fn {item, index}, current ->
      child =
        Featurevisor.spawn(f, item["context"] || %{}, %{
          sticky_features: item["stickyFeatures"] || %{},
          sticky_variables: item["stickyVariables"] || %{}
        })

      options =
        if Map.has_key?(item, "defaultVariableValue"),
          do: %{default_variable_value: item["defaultVariableValue"]},
          else: %{}

      evaluation = Featurevisor.Child.evaluate_global_variable(child, variable, %{}, options)
      prefix = "#{variable}: children[#{index}]"
      effective_context = Map.merge(check_execution.root_context, item["context"] || %{})

      try do
        failures =
          compare_present(
            [],
            item,
            "expectedValue",
            fn -> evaluation.variable_value end,
            prefix
          )

        failures =
          compare_evaluation(
            failures,
            item["expectedEvaluation"],
            wire(evaluation),
            "#{prefix}.expectedEvaluation"
          )

        current = current ++ child_errors(failures, index)

        if Map.has_key?(item, "checks") do
          current ++
            check_report_errors(
              TestChecks.evaluate_result(
                child,
                check_execution.datafile,
                item["checks"],
                variable,
                check_execution.diagnostic_ref,
                "children[#{index}].checks",
                segment_check_options(
                  check_execution.segment_evaluator,
                  check_execution.spec,
                  effective_context
                )
              ),
              check_execution.authored,
              index
            )
        else
          current
        end
      after
        Featurevisor.Child.close(child)
      end
    end)
  end

  defp run_scenario_assertion(
         spec,
         assertion,
         datafile,
         coverage,
         coverage_metadata,
         options,
         authored
       ) do
    case preflight_assertion_tree(spec, assertion, datafile, nil, true, authored) do
      [] ->
        do_run_scenario_assertion(
          spec,
          assertion,
          datafile,
          coverage,
          coverage_metadata,
          options,
          authored
        )

      errors ->
        errors
    end
  end

  defp do_run_scenario_assertion(
         spec,
         assertion,
         datafile,
         coverage,
         coverage_metadata,
         options,
         authored
       ) do
    if options.show_datafile, do: IO.puts(:stderr, Jason.encode!(datafile, pretty: true))

    module = %Module{
      name: "tester",
      bucket_value: fn value ->
        if is_number(assertion["at"]),
          do: trunc(assertion["at"] * 1_000),
          else: value.bucket_value
      end
    }

    diagnostic_ref = make_ref()
    diagnostic_target = self()

    {datafile, segment_keys} = Segments.prepare(datafile, spec["_segments"] || %{})
    root_context = assertion["context"] || %{}

    f =
      Featurevisor.create_featurevisor(%{
        datafile: datafile,
        context: root_context,
        sticky_features: assertion["stickyFeatures"] || %{},
        sticky_variables: assertion["stickyVariables"] || %{},
        log_level: check_log_level(options, assertion),
        on_diagnostic: TestChecks.diagnostic_handler(diagnostic_target, diagnostic_ref),
        modules:
          modules(
            [module, TestChecks.diagnostic_module(diagnostic_target, diagnostic_ref)],
            coverage,
            coverage_metadata,
            Map.values(segment_keys)
          )
      })

    try do
      errors =
        cond do
          assertion["__missingAssertions"] ->
            ["scenario spec requires assertions"]

          Map.has_key?(assertion, "checks") ->
            TestChecks.evaluate_result(
              f,
              datafile,
              assertion["checks"],
              nil,
              diagnostic_ref,
              "checks",
              segment_check_options(segment_keys, spec, root_context)
            )
            |> check_report_errors(authored)

          (assertion["children"] || []) == [] ->
            ["scenario assertion requires checks or children"]

          true ->
            []
        end

      Enum.with_index(assertion["children"] || [])
      |> Enum.reduce(errors, fn {item, index}, current ->
        effective_context = Map.merge(root_context, item["context"] || %{})

        child =
          Featurevisor.spawn(f, item["context"] || %{}, %{
            sticky_features: item["stickyFeatures"] || %{},
            sticky_variables: item["stickyVariables"] || %{}
          })

        try do
          current ++
            check_report_errors(
              TestChecks.evaluate_result(
                child,
                datafile,
                item["checks"],
                nil,
                diagnostic_ref,
                "children[#{index}].checks",
                segment_check_options(segment_keys, spec, effective_context)
              ),
              authored,
              index
            )
        after
          Featurevisor.Child.close(child)
        end
      end)
    after
      Featurevisor.close(f)
    end
  end

  defp preflight_assertion_tree(spec, assertion, datafile, owner, scenario?, authored) do
    definitions = if(is_map(spec["_segments"]), do: spec["_segments"], else: %{})
    segment_checks = %{definitions: definitions}

    children_result =
      case Map.get(assertion, "children", []) do
        children when is_list(children) -> {:ok, children}
        value -> {:error, malformed_children_error(value, authored)}
      end

    root_errors =
      cond do
        Map.has_key?(assertion, "checks") ->
          datafile
          |> TestChecks.preflight(assertion["checks"], owner, "checks", segment_checks)
          |> check_report_errors(authored)

        scenario? and children_result == {:ok, []} ->
          [%{"message" => "scenario assertion requires checks or children"}]

        true ->
          []
      end

    case children_result do
      {:error, error} ->
        root_errors ++ [error]

      {:ok, children} ->
        children
        |> Enum.with_index()
        |> Enum.reduce(root_errors, fn {child, index}, errors ->
          cond do
            not is_map(child) ->
              errors ++ [malformed_child_error(child, index, authored)]

            Map.has_key?(child, "checks") ->
              errors ++
                (datafile
                 |> TestChecks.preflight(
                   child["checks"],
                   owner,
                   "children[#{index}].checks",
                   segment_checks
                 )
                 |> check_report_errors(authored, index))

            scenario? ->
              errors ++ [missing_child_checks_error(index, authored)]

            true ->
              errors
          end
        end)
    end
  end

  defp malformed_children_error(value, authored) do
    %{
      "message" => "children must be an array",
      "type" => "check",
      "path" => authored_path(authored) ++ ["children"],
      "expected" => "array",
      "actual" => value
    }
  end

  defp malformed_child_error(value, index, authored) do
    %{
      "message" => "children[#{index}] must be an object",
      "type" => "check",
      "path" => authored_path(authored) ++ ["children", index],
      "expected" => "object",
      "actual" => value
    }
  end

  defp missing_child_checks_error(index, authored) do
    %{
      "message" => "children[#{index}].checks: checks must be a nonempty array",
      "type" => "check",
      "path" => authored_path(authored) ++ ["children", index, "checks"],
      "expected" => "valid checks",
      "actual" => nil
    }
  end

  defp authored_path(%{entity_type: "scenario"}), do: []
  defp authored_path(%{assertion_index: index}), do: ["assertions", index]

  defp missing_datafile_message(assertion) do
    environment = assertion["environment"] || "none"
    target = if assertion["target"], do: " and target \"#{assertion["target"]}\"", else: ""
    "datafile not found for environment \"#{environment}\"#{target}"
  end

  defp compare_present(errors, assertion, key, getter, _feature) do
    if Map.has_key?(assertion, key) do
      actual = getter.()

      type =
        %{
          "expectedToBeEnabled" => "flag",
          "expectedVariation" => "variation",
          "expectedValue" => "variable"
        }[key]

      if actual == assertion[key],
        do: errors,
        else: errors ++ [expectation_error(type, [key], assertion[key], actual)]
    else
      errors
    end
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
          current ++ [expectation_error("variable", ["expectedVariables", key], expected, actual)]
    end)
  end

  defp compare_evaluations(errors, assertion, f, feature) do
    expected = assertion["expectedEvaluations"] || %{}

    errors =
      compare_evaluation(
        errors,
        expected["flag"],
        wire(Featurevisor.evaluate_flag(f, feature)),
        "#{feature}: flag",
        ["expectedEvaluations", "flag"]
      )

    errors =
      compare_evaluation(
        errors,
        expected["variation"],
        wire(Featurevisor.evaluate_variation(f, feature)),
        "#{feature}: variation",
        ["expectedEvaluations", "variation"]
      )

    Enum.reduce(expected["variables"] || %{}, errors, fn {key, value}, current ->
      compare_evaluation(
        current,
        value,
        wire(Featurevisor.evaluate_variable(f, feature, key)),
        "#{feature}: variable #{key}",
        ["expectedEvaluations", "variables", key]
      )
    end)
  end

  defp compare_evaluation(errors, expected, actual, label, path \\ ["expectedEvaluation"])
  defp compare_evaluation(errors, nil, _actual, _label, _path), do: errors

  defp compare_evaluation(errors, expected, actual, _label, path) do
    Enum.reduce(expected, errors, fn {key, value}, current ->
      if actual[key] == value,
        do: current,
        else: current ++ [expectation_error("evaluation", path ++ [key], value, actual[key])]
    end)
  end

  defp compare_children(errors, assertion, f, feature) do
    Enum.with_index(assertion["children"] || [])
    |> Enum.reduce(errors, fn {item, index}, current ->
      # A child owns its sticky values. It does not inherit the parent assertion's.
      child =
        Featurevisor.spawn(f, item["context"] || %{}, %{
          sticky_features: item["stickyFeatures"] || %{},
          sticky_variables: item["stickyVariables"] || %{}
        })

      try do
        variation_options =
          if Map.has_key?(item, "defaultVariationValue"),
            do: %{default_variation_value: item["defaultVariationValue"]},
            else: %{}

        failures =
          []
          |> compare_present(
            item,
            "expectedToBeEnabled",
            fn -> Featurevisor.Child.enabled?(child, feature) end,
            feature
          )
          |> compare_present(
            item,
            "expectedVariation",
            fn -> Featurevisor.Child.get_variation(child, feature, %{}, variation_options) end,
            feature
          )

        failures =
          Enum.reduce(item["expectedVariables"] || %{}, failures, fn {key, expected}, acc ->
            options =
              if is_map(item["defaultVariableValues"]) and
                   Map.has_key?(item["defaultVariableValues"], key),
                 do: %{default_variable_value: item["defaultVariableValues"][key]},
                 else: %{}

            actual = Featurevisor.Child.get_variable(child, feature, key, %{}, options)

            if actual == expected,
              do: acc,
              else:
                acc ++
                  [expectation_error("variable", ["expectedVariables", key], expected, actual)]
          end)

        expected = item["expectedEvaluations"] || %{}

        failures =
          Enum.reduce(["flag", "variation"], failures, fn kind, acc ->
            if is_map(expected[kind]) do
              evaluation =
                if kind == "flag",
                  do: Featurevisor.Child.evaluate_flag(child, feature),
                  else: Featurevisor.Child.evaluate_variation(child, feature)

              compare_evaluation(acc, expected[kind], wire(evaluation), feature, [
                "expectedEvaluations",
                kind
              ])
            else
              acc
            end
          end)

        failures =
          Enum.reduce(expected["variables"] || %{}, failures, fn {key, value}, acc ->
            compare_evaluation(
              acc,
              value,
              wire(Featurevisor.Child.evaluate_variable(child, feature, key)),
              feature,
              ["expectedEvaluations", "variables", key]
            )
          end)

        current ++ child_errors(failures, index)
      after
        Featurevisor.Child.close(child)
      end
    end)
  end

  defp wire(%Evaluation{} = evaluation),
    do:
      evaluation
      |> Evaluation.to_map()
      |> Map.update("error", nil, fn error -> %{"message" => Exception.message(error)} end)
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
      |> Jason.encode!()
      |> Jason.decode!()

  defp log_level(%{json: true}), do: :error
  defp log_level(%{verbose: true}), do: :debug
  defp log_level(%{quiet: true}), do: :fatal
  defp log_level(_), do: :error

  defp check_log_level(options, assertion) do
    if Map.has_key?(assertion, "checks") or (assertion["children"] || []) != [],
      do: :error,
      else: log_level(options)
  end

  defp segment_errors(ref) do
    receive do
      {:featurevisor_cli_check_diagnostic, ^ref, diagnostic} ->
        errors = segment_errors(ref)
        if to_string(diagnostic.level) == "error", do: [diagnostic.message | errors], else: errors
    after
      0 -> []
    end
  end

  defp modules(base, coverage, metadata, synthetic \\ []),
    do: Enum.reject(base ++ [TestCoverage.module(coverage, metadata, synthetic)], &is_nil/1)

  defp segment_check_options(evaluator, spec, context) do
    %{
      keys: evaluator,
      definitions: if(is_map(spec["_segments"]), do: spec["_segments"], else: %{}),
      context: context
    }
  end
end
