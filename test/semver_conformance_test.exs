defmodule Featurevisor.SemverConformanceTest do
  use ExUnit.Case, async: true
  @fixture Path.expand("../conformance/semver.json", __DIR__) |> File.read!() |> Jason.decode!()
  alias Featurevisor.CLI.TestChecks

  test "executes every portable version comparison in both directions" do
    assert @fixture["kind"] == "featurevisor.semver"
    assert @fixture["version"] == 1
    assert length(@fixture["cases"]) == 44

    for entry <- @fixture["cases"], reverse <- [false, true] do
      {left, right} =
        if reverse, do: {entry["right"], entry["left"]}, else: {entry["left"], entry["right"]}

      actual = Featurevisor.Semver.compare(left, right)

      if is_nil(entry["order"]) do
        assert match?({:error, _}, actual), entry["name"]
      else
        expected = if reverse, do: -entry["order"], else: entry["order"]
        assert actual == expected, entry["name"]
      end

      order = if reverse && entry["order"], do: -entry["order"], else: entry["order"]

      for {operator, expected} <- [
            {"semverEquals", order == 0},
            {"semverNotEquals", not is_nil(order) and order != 0},
            {"semverGreaterThan", not is_nil(order) and order > 0},
            {"semverGreaterThanOrEquals", not is_nil(order) and order >= 0},
            {"semverLessThan", not is_nil(order) and order < 0},
            {"semverLessThanOrEquals", not is_nil(order) and order <= 0}
          ] do
        requirement = %{"variable" => "source", "operator" => operator, "value" => right}

        feature_requirement = %{
          "feature" => "sourceFeature",
          "variable" => "version",
          "operator" => operator,
          "value" => right
        }

        datafile = %{
          "schemaVersion" => "2",
          "revision" => "semver",
          "segments" => %{},
          "features" => %{
            "condition" => %{
              "bucketBy" => "userId",
              "traffic" => [],
              "force" => [
                %{
                  "conditions" => %{
                    "attribute" => "version",
                    "operator" => operator,
                    "value" => right
                  },
                  "enabled" => true
                }
              ]
            },
            "sourceFeature" => %{
              "bucketBy" => "userId",
              "traffic" => [],
              "force" => [%{"segments" => "*", "enabled" => true}],
              "variablesSchema" => %{"version" => %{"type" => "string", "defaultValue" => left}}
            }
          },
          "variables" => %{
            "source" => %{"type" => "string", "defaultValue" => left},
            "other" => %{"type" => "string", "defaultValue" => right},
            "subject" => %{
              "type" => "boolean",
              "defaultValue" => true,
              "disabledValue" => false,
              "conditions" => [requirement]
            },
            "negated" => %{
              "type" => "boolean",
              "defaultValue" => true,
              "disabledValue" => false,
              "conditions" => [%{"not" => [requirement]}]
            },
            "featureSubject" => %{
              "type" => "boolean",
              "defaultValue" => true,
              "disabledValue" => false,
              "conditions" => [feature_requirement]
            },
            "featureNegated" => %{
              "type" => "boolean",
              "defaultValue" => true,
              "disabledValue" => false,
              "conditions" => [%{"not" => [feature_requirement]}]
            }
          }
        }

        ref = make_ref()

        sdk =
          Featurevisor.create_featurevisor(%{
            datafile: datafile,
            log_level: :fatal,
            on_diagnostic: TestChecks.diagnostic_handler(self(), ref),
            modules: [TestChecks.diagnostic_module(self(), ref)]
          })

        label = "#{entry["name"]} reverse=#{reverse} #{operator}"

        try do
          assert Featurevisor.enabled?(sdk, "condition", %{"version" => left}) == expected, label

          for {variable, value} <- [
                {"subject", expected},
                {"negated", not expected},
                {"featureSubject", expected},
                {"featureNegated", not expected}
              ] do
            evaluation = Featurevisor.evaluate_global_variable(sdk, variable)

            if is_nil(order) do
              assert evaluation.reason == :error, label
            else
              assert evaluation.variable_value == value, label
            end
          end

          check = %{
            "variable" => "source",
            "operator" => operator,
            "compareTo" => %{"variable" => "other"}
          }

          for {node, matched} <- [{check, expected}, {%{"not" => [check]}, not expected}] do
            result = TestChecks.evaluate_result(sdk, datafile, [node], nil, ref)
            assert result.error == is_nil(order), label
            assert result.passed == (not is_nil(order) and matched), label
          end
        after
          Featurevisor.close(sdk)
        end
      end
    end
  end
end
