defmodule Featurevisor.ConformanceTest do
  use ExUnit.Case, async: true
  alias Featurevisor.{Bucketer, Conditions, Module}

  @fixture Path.expand("../conformance/sdk-v3.json", __DIR__) |> File.read!() |> Jason.decode!()

  test "executes the canonical fixture version and bucket boundaries" do
    assert @fixture["version"] == 6
    assert is_binary(@fixture["description"])

    assert Enum.sort(Map.keys(@fixture)) ==
             Enum.sort([
               "version",
               "description",
               "bucketing",
               "regularExpressions",
               "typedVariables",
               "datafile",
               "globalVariables",
               "requiredFeatures",
               "diagnostics",
               "numericBucketKeys",
               "portableConditions",
               "conditionCases",
               "childInstances",
               "defaults",
               "modulePipeline",
               "lifecycle",
               "openFeature",
               "diagnosticCase",
               "nativeContexts"
             ])

    assert @fixture["bucketing"]["minimum"] == 0
    assert Bucketer.max_bucketed_number() == @fixture["bucketing"]["maximum"]

    allocations = @fixture["bucketing"]["allocations"]

    Enum.each(@fixture["bucketing"]["allocationExpectations"], fn {value, expected} ->
      number = String.to_integer(value)

      allocation =
        Enum.find(allocations, fn %{"range" => [first, last]} ->
          first <= number and last >= number
        end)

      assert allocation["variation"] == expected
    end)

    percentage = @fixture["bucketing"]["percentage"]

    Enum.each(percentage["enabledAt"], fn bucket_value ->
      assert Featurevisor.enabled?(
               fixed_bucket_feature(percentage["percentage"], bucket_value),
               "feature"
             )
    end)

    Enum.each(percentage["disabledAt"], fn bucket_value ->
      refute Featurevisor.enabled?(
               fixed_bucket_feature(percentage["percentage"], bucket_value),
               "feature"
             )
    end)
  end

  test "evaluates canonical global variables and required features" do
    global = @fixture["globalVariables"]

    Enum.each(global["cases"], fn item ->
      f =
        Featurevisor.create_featurevisor(%{
          datafile: global["datafile"],
          sticky_variables: item["stickyVariables"],
          log_level: :fatal
        })

      options =
        if Map.has_key?(item, "defaultVariableValue"),
          do: %{default_variable_value: item["defaultVariableValue"]},
          else: %{}

      evaluation =
        Featurevisor.evaluate_global_variable(f, item["key"], item["context"] || %{}, options)

      assert Atom.to_string(evaluation.reason) == item["expectedReason"], item["name"]

      if Map.has_key?(item, "expectedValue"),
        do: assert(evaluation.variable_value == item["expectedValue"], item["name"]),
        else: assert(is_nil(evaluation.variable_value), item["name"])

      assert evaluation.variable_override_index == item["expectedOverrideIndex"], item["name"]
      assert evaluation.variable_override_key == item["expectedOverrideKey"], item["name"]
      assert evaluation.variable_override_path == item["expectedOverridePath"], item["name"]
      Featurevisor.close(f)
    end)

    required = @fixture["requiredFeatures"]
    f = Featurevisor.create_featurevisor(%{datafile: required["datafile"], log_level: :fatal})

    Enum.each(required["cases"], fn item ->
      assert Featurevisor.enabled?(f, item["feature"]) == item["expectedEnabled"], item["name"]
    end)

    item = required["featureVariableCase"]
    evaluation = Featurevisor.evaluate_variable(f, item["feature"], item["variable"])
    assert evaluation.variable_value == item["expectedValue"]
    assert evaluation.variable_override_key == item["expectedOverrideKey"]
    Featurevisor.close(f)
  end

  test "datafile events include global variables and dependency changes" do
    item = @fixture["globalVariables"]["dependencyUpdateCase"]
    parent = self()
    f = Featurevisor.create_featurevisor(%{datafile: item["initial"], log_level: :fatal})
    Featurevisor.on(f, :datafile_set, &send(parent, {:datafile, &1}))
    assert :ok = Featurevisor.set_datafile(f, item["updated"], true)
    assert_receive {:datafile, details}
    assert Enum.sort(details.features) == Enum.sort(item["expectedChangedFeatures"])
    assert Enum.sort(details.variables) == Enum.sort(item["expectedChangedVariables"])
    Featurevisor.close(f)
  end

  test "global null values remain present ahead of caller defaults" do
    datafile = %{
      "schemaVersion" => "2",
      "revision" => "nulls",
      "segments" => %{},
      "features" => %{},
      "variables" => %{"nullable" => %{"type" => "object", "defaultValue" => nil}}
    }

    f =
      Featurevisor.create_featurevisor(%{
        datafile: datafile,
        sticky_variables: %{"sticky" => nil},
        log_level: :fatal
      })

    options = %{default_variable_value: "caller"}

    assert Featurevisor.evaluate_global_variable(f, "nullable", %{}, options).variable_value ==
             nil

    assert Featurevisor.evaluate_global_variable(f, "sticky", %{}, options).variable_value == nil

    assert Featurevisor.evaluate_global_variable(f, "missing", %{}, options).variable_value ==
             "caller"

    Featurevisor.close(f)
  end

  test "MurmurHash and bucketing match known JavaScript values" do
    assert Featurevisor.MurmurHash.hash("foo", 1) == 884_891_506
    assert Bucketer.bucketed_number("foo") == 20_602
  end

  test "executes every portable regular expression case" do
    cache = :ets.new(:regex_cases, [:set, :public, write_concurrency: true])
    report = fn diagnostic -> flunk("unexpected diagnostic #{inspect(diagnostic)}") end

    Enum.each(@fixture["regularExpressions"]["portableCases"], fn item ->
      condition = %{
        "attribute" => "value",
        "operator" => "matches",
        "value" => item["pattern"],
        "regexFlags" => item["flags"]
      }

      assert Conditions.all_conditions?(condition, %{"value" => item["value"]}, cache, report) ==
               item["expected"]
    end)
  end

  test "executes every generic condition case" do
    cache = :ets.new(:condition_cases, [:set, :public, write_concurrency: true])
    report = fn _ -> :ok end

    Enum.each(@fixture["conditionCases"], fn item ->
      assert Conditions.all_conditions?(item["condition"], item["context"], cache, report) ==
               item["expected"],
             item["name"]
    end)
  end

  test "formats numeric bucket context values like JavaScript" do
    Enum.each(@fixture["numericBucketKeys"], fn item ->
      assert Bucketer.bucket_string(item["value"]) == item["expected"]

      value = item["value"] * 1.0

      datafile = %{
        "schemaVersion" => "2",
        "revision" => "numeric-bucket",
        "segments" => %{},
        "features" => %{
          "feature" => %{
            "key" => "feature",
            "bucketBy" => "number",
            "traffic" => [
              %{
                "key" => "rule",
                "segments" => "*",
                "percentage" => 100_000,
                "enabled" => true
              }
            ]
          }
        }
      }

      f = Featurevisor.create_featurevisor(%{datafile: datafile, log_level: :fatal})
      evaluation = Featurevisor.evaluate_flag(f, "feature", %{"number" => value})
      assert evaluation.bucket_key == "#{item["expected"]}.feature"
      Featurevisor.close(f)
    end)
  end

  test "executes all portable date and semantic version values" do
    cache = :ets.new(:portable_values, [:set, :public])
    report = fn diagnostic -> flunk("unexpected diagnostic #{inspect(diagnostic)}") end
    assert @fixture["portableConditions"]["dateFormat"] == "ISO 8601 with an explicit timezone"

    Enum.each(@fixture["portableConditions"]["dates"], fn date ->
      assert Conditions.all_conditions?(
               %{"attribute" => "date", "operator" => "equals", "value" => date},
               %{"date" => date},
               cache,
               report
             )
    end)

    Enum.each(@fixture["portableConditions"]["semanticVersions"], fn version ->
      assert Conditions.all_conditions?(
               %{"attribute" => "version", "operator" => "semverEquals", "value" => version},
               %{"version" => version},
               cache,
               report
             )
    end)

    assert Enum.sort(@fixture["portableConditions"]["regexFlags"]) == ["g", "i", "m", "s"]

    Enum.each(@fixture["portableConditions"]["rejectedRegexFlags"], fn flag ->
      parent = self()

      report = fn diagnostic -> send(parent, diagnostic) end

      refute Conditions.all_conditions?(
               %{
                 "attribute" => "value",
                 "operator" => "matches",
                 "value" => "chrome",
                 "regexFlags" => flag
               },
               %{"value" => "chrome"},
               cache,
               report
             )

      assert_receive %{code: "condition_match_error"}
    end)

    parent = self()
    report = fn diagnostic -> send(parent, diagnostic) end

    refute Conditions.all_conditions?(
             %{
               "attribute" => "version",
               "operator" => "semverEquals",
               "value" => @fixture["portableConditions"]["semanticVersions"] |> hd()
             },
             %{"version" => @fixture["portableConditions"]["invalidSemanticVersion"]},
             cache,
             report
           )

    assert_receive %{
      code: code
    }

    assert code == @fixture["portableConditions"]["invalidSemanticVersionDiagnosticCode"]
  end

  test "repeated regex evaluations do not retain state" do
    regex = @fixture["regularExpressions"]
    cache = :ets.new(:repeated_regex, [:set, :public, write_concurrency: true])
    report = fn diagnostic -> flunk("unexpected diagnostic #{inspect(diagnostic)}") end

    Enum.zip(regex["values"], regex["matches"])
    |> Enum.each(fn {value, expected} ->
      assert Conditions.all_conditions?(
               %{
                 "attribute" => "value",
                 "operator" => "matches",
                 "value" => regex["pattern"],
                 "regexFlags" => regex["flags"]
               },
               %{"value" => value},
               cache,
               report
             ) == expected
    end)

    assert Enum.all?(regex["rejectedSyntax"], &is_binary/1)
  end

  test "executes every typed variable case" do
    Enum.each(@fixture["typedVariables"], fn item ->
      datafile =
        datafile(%{
          "feature" => %{
            "key" => "feature",
            "bucketBy" => "userId",
            "variablesSchema" => %{
              "value" => %{"type" => item["type"], "defaultValue" => item["value"]}
            },
            "traffic" => [
              %{"key" => "rule", "segments" => "*", "percentage" => 100_000, "enabled" => true}
            ]
          }
        })

      f = Featurevisor.create_featurevisor(%{datafile: datafile, log_level: :fatal})

      value =
        case item["type"] do
          "integer" -> Featurevisor.get_variable_integer(f, "feature", "value")
          "double" -> Featurevisor.get_variable_double(f, "feature", "value")
          "boolean" -> Featurevisor.get_variable_boolean(f, "feature", "value")
        end

      assert not is_nil(value) == item["valid"]
      Featurevisor.close(f)
    end)
  end

  test "executes datafile, defaults, diagnostics, and native context contracts" do
    assert @fixture["datafile"]["schemaVersionIsInformational"]
    assert @fixture["datafile"]["schemaVersionType"] == "string"

    f =
      Featurevisor.create_featurevisor(%{
        datafile: %{
          "schemaVersion" => "informational",
          "revision" => "schema",
          "segments" => %{},
          "features" => %{}
        },
        log_level: :fatal
      })

    assert Featurevisor.get_schema_version(f) == "informational"
    Featurevisor.close(f)

    defaults = @fixture["defaults"]
    assert defaults["presenceBased"]
    assert defaults["values"] == ["", 0, false, nil]
    assert defaults["aggregateEvaluationPreservesEmptyVariation"]

    default_f =
      Featurevisor.create_featurevisor(%{
        datafile: defaults["aggregateCase"]["datafile"],
        log_level: :fatal
      })

    Enum.each(defaults["values"], fn value ->
      assert Featurevisor.get_variable(default_f, "experiment", "missing", %{}, %{
               default_variable_value: value
             }) === value
    end)

    Featurevisor.close(default_f)

    assert @fixture["nativeContexts"]["numericTypesUseOneComparisonContract"]
    assert @fixture["nativeContexts"]["primitiveNativeSlicesSupportIncludes"]

    cache = :ets.new(:native_contexts, [:set, :public])
    report = fn diagnostic -> flunk("unexpected diagnostic #{inspect(diagnostic)}") end

    for number <- [2, 2.0] do
      assert Conditions.all_conditions?(
               %{"attribute" => "score", "operator" => "greaterThan", "value" => 1.5},
               %{"score" => number},
               cache,
               report
             )
    end

    assert Conditions.all_conditions?(
             %{"attribute" => "roles", "operator" => "includes", "value" => "admin"},
             %{"roles" => ["user", "admin"]},
             cache,
             report
           )
  end

  test "executes diagnostic envelope and error event contracts" do
    parent = self()
    diagnostics_contract = @fixture["diagnostics"]
    assert diagnostics_contract["detailsType"] == "object"

    module = %Module{
      name: "conformance",
      setup: fn api ->
        api.report_diagnostic.(%{
          level: :info,
          code: "module_ready",
          message: "ready",
          details: %{}
        })
      end
    }

    f =
      Featurevisor.create_featurevisor(%{
        datafile: Featurevisor.TestFixtures.datafile(),
        log_level: :debug,
        modules: [module],
        on_diagnostic: fn diagnostic -> send(parent, {:diagnostic, diagnostic}) end
      })

    assert_receive {:diagnostic, module_ready}
    assert module_ready.code == "module_ready"
    assert module_ready.module == "conformance"
    assert module_ready.details == %{}
    assert Jason.encode!(module_ready.details) == diagnostics_contract["emptyDetailsJson"]

    Featurevisor.enabled?(f, @fixture["diagnosticCase"]["featureKey"])

    assert_receive {:diagnostic, %{code: "feature_not_found"} = missing}
    assert Atom.to_string(missing.level) == @fixture["diagnosticCase"]["expectedLevel"]
    assert missing.code == @fixture["diagnosticCase"]["expectedCode"]
    assert is_map(missing.details) == @fixture["diagnosticCase"]["detailsMustBeObject"]

    Enum.each(diagnostics_contract["requiredFields"], fn field ->
      assert Map.has_key?(
               Map.from_struct(missing),
               String.to_existing_atom(Macro.underscore(field))
             )
    end)

    Featurevisor.get_variable(f, "experiment", "missing")
    assert_receive {:diagnostic, %{code: "variable_not_found"} = variable_missing}

    Enum.each(diagnostics_contract["evaluationDetailFields"], fn field ->
      assert Map.has_key?(variable_missing.details, String.to_existing_atom(field))
    end)

    Featurevisor.on(f, :error, fn details -> send(parent, {:error_event, details}) end)
    Featurevisor.set_datafile(f, "{")
    assert_receive {:error_event, %{diagnostic: %{level: :error}}}
    assert diagnostics_contract["errorEventLevels"] == ["error"]

    broken = %Module{name: "broken", setup: fn _ -> raise "broken" end}
    Featurevisor.add_module(f, broken)
    assert_receive {:diagnostic, %{code: "module_setup_error"} = setup_error}
    assert setup_error.module_name == "broken"
    assert setup_error.original_error

    envelope = %{
      "module" => module_ready.module,
      "moduleName" => setup_error.module_name,
      "originalError" => setup_error.original_error
    }

    Enum.each(diagnostics_contract["moduleEnvelopeFields"], &assert(Map.has_key?(envelope, &1)))
    Featurevisor.close(f)
  end

  test "executes child context, detailed evaluation, and subscription contracts" do
    child_contract = @fixture["childInstances"]
    assert is_binary(child_contract["contextModel"])
    assert child_contract["closeRemovesLocalAndDelegatedSubscriptions"]

    assert Enum.sort(child_contract["detailedEvaluationMethods"]) == [
             "flag",
             "variable",
             "variation"
           ]

    f =
      Featurevisor.create_featurevisor(%{
        datafile: Featurevisor.TestFixtures.datafile(),
        context: child_contract["contextCase"]["parentAtSpawn"],
        log_level: :fatal
      })

    child = Featurevisor.spawn(f, child_contract["contextCase"]["child"])
    Featurevisor.set_context(f, child_contract["contextCase"]["parentAfterSpawn"], true)
    assert Featurevisor.Child.get_context(child) == child_contract["contextCase"]["expected"]
    assert %Featurevisor.Evaluation{} = Featurevisor.Child.evaluate_flag(child, "flag")
    assert %Featurevisor.Evaluation{} = Featurevisor.Child.evaluate_variation(child, "experiment")

    assert %Featurevisor.Evaluation{} =
             Featurevisor.Child.evaluate_variable(child, "experiment", "title")

    parent = self()
    Featurevisor.Child.on(child, :context_set, fn _ -> send(parent, :local) end)
    Featurevisor.Child.on(child, :datafile_set, fn _ -> send(parent, :delegated) end)
    Featurevisor.Child.close(child)
    Featurevisor.set_datafile(f, Featurevisor.TestFixtures.datafile(), true)
    refute_receive :local
    refute_receive :delegated
    Featurevisor.close(f)
  end

  test "preserves aggregate empty variation default" do
    item = @fixture["defaults"]["aggregateCase"]
    f = Featurevisor.create_featurevisor(%{datafile: item["datafile"], log_level: :fatal})

    result =
      Featurevisor.get_feature_evaluations(f, %{}, [], %{
        default_variation_value: item["defaultVariationValue"]
      })

    assert result["experiment"] == %{enabled: false, variation: ""}
    Featurevisor.close(f)
  end

  defp datafile(features) do
    %{
      "schemaVersion" => "2",
      "revision" => "conformance",
      "segments" => %{},
      "features" => features
    }
  end

  defp fixed_bucket_feature(percentage, bucket_value) do
    f =
      Featurevisor.create_featurevisor(%{
        datafile:
          datafile(%{
            "feature" => %{
              "key" => "feature",
              "bucketBy" => "userId",
              "traffic" => [
                %{
                  "key" => "rule",
                  "segments" => "*",
                  "percentage" => percentage
                }
              ]
            }
          }),
        modules: [%Module{name: "bucket", bucket_value: fn _ -> bucket_value end}],
        log_level: :fatal
      })

    ExUnit.Callbacks.on_exit(fn -> Featurevisor.close(f) end)
    f
  end

  test "module diagnostic threshold is independent from instance threshold" do
    parent = self()

    f =
      Featurevisor.create_featurevisor(%{
        datafile: Featurevisor.TestFixtures.datafile(),
        log_level: :fatal
      })

    module = %Module{
      name: "observer",
      setup: fn api ->
        api.on_diagnostic.(fn diagnostic -> send(parent, diagnostic) end, %{log_level: :debug})
      end
    }

    Featurevisor.add_module(f, module)
    Featurevisor.enabled?(f, "missing")
    assert_receive %{level: :warn, code: "feature_not_found", details: details}
    assert is_map(details)
    assert Map.has_key?(details, :evaluation)
    Featurevisor.close(f)
  end
end
