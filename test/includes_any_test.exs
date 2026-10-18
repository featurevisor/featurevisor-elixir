defmodule Featurevisor.IncludesAnyTest do
  use ExUnit.Case, async: true
  alias Featurevisor.{CLI.TestChecks, Conditions}

  @cases [
    {["admin", 2, true, nil], ["missing", 2.0], true, true},
    {["admin", 2, true, nil], [true], true, true},
    {["admin", 2, true, nil], [nil], true, true},
    {["admin"], ["admin", "admin"], true, true},
    {["admin", "admin"], ["other", "admin"], true, true},
    {["admin"], ["admin", "other"], true, true},
    {[1], [true], false, true},
    {[true], [1], false, true},
    {[false], [0], false, true},
    {["1"], [1], false, true},
    {[1], ["1"], false, true},
    {["true"], [true], false, true},
    {[%{}, [1], "admin"], ["admin"], true, true},
    {[%{}, [1]], [nil, 1], false, true},
    {[], [nil], false, true},
    {["admin"], [], false, true},
    {[], [], false, true},
    {nil, [], false, false},
    {"admin", ["admin"], false, false},
    {1, [1], false, false},
    {true, [true], false, false},
    {%{}, [], false, false},
    {["admin"], nil, false, false},
    {["admin"], "admin", false, false},
    {["admin"], 1, false, false},
    {["admin"], true, false, false},
    {["admin"], %{}, false, false},
    {["admin"], ["admin", %{}], false, false},
    {["admin"], [[], "admin"], false, false}
  ]

  test "conditions and feature and global requirements share strict membership" do
    cache = :ets.new(:includes_any, [:set, :public])

    for {actual, candidates, found, valid} <- @cases,
        operator <- ["includesAny", "notIncludesAny"],
        source <- [
          %{"variable" => "source", "path" => ["items"]},
          %{"feature" => "sourceFeature", "variable" => "items"},
          %{"variable" => "source", "path" => ["missing"]}
        ] do
      expected = valid and if(operator == "includesAny", do: found, else: not found)
      requirement = Map.merge(source, %{"operator" => operator, "value" => candidates})
      requirement_expected = expected and source["path"] != ["missing"]
      condition = %{"attribute" => "profile.items", "operator" => operator, "value" => candidates}
      context = %{"profile" => %{"items" => actual}}
      assert Conditions.all_conditions?(condition, context, cache, fn _ -> :ok end) == expected
      datafile = datafile(actual, candidates, requirement)
      instance = Featurevisor.create_featurevisor(%{datafile: datafile, log_level: :fatal})

      try do
        for _ <- 1..2 do
          assert Featurevisor.enabled?(instance, "gate") == requirement_expected
          assert Featurevisor.get_global_variable(instance, "gate") == requirement_expected
          assert Featurevisor.get_variable(instance, "override", "result") == requirement_expected
        end
      after
        Featurevisor.close(instance)
      end
    end
  end

  test "missing paths and invalid runtime comparisons preserve NOT and OR semantics" do
    cache = :ets.new(:includes_any_groups, [:set, :public])
    report = fn _ -> :ok end

    for operator <- ["includesAny", "notIncludesAny"] do
      invalid = %{
        "attribute" => "profile.items",
        "operator" => operator,
        "value" => ["admin", %{}]
      }

      for context <- [%{}, %{"profile" => %{"items" => ["admin"]}}] do
        refute Conditions.all_conditions?(invalid, context, cache, report)
        assert Conditions.all_conditions?(%{"not" => [invalid]}, context, cache, report)
        assert Conditions.all_conditions?(%{"or" => [invalid, "*"]}, context, cache, report)
      end
    end
  end

  test "CLI literal and compareTo checks validate operands and report structured errors" do
    for {actual, candidates, found, valid} <- @cases,
        operator <- ["includesAny", "notIncludesAny"] do
      datafile = datafile(actual, candidates, nil)
      instance = Featurevisor.create_featurevisor(%{datafile: datafile, log_level: :fatal})

      try do
        for operand <- [%{"value" => candidates}, %{"compareTo" => %{"variable" => "candidates"}}] do
          check =
            Map.merge(
              %{"variable" => "source", "path" => ["items"], "operator" => operator},
              operand
            )

          result = TestChecks.evaluate_result(instance, datafile, [check], nil, make_ref())

          assert result.passed ==
                   (valid and if(operator == "includesAny", do: found, else: not found))

          assert result.error == not valid

          if not valid do
            assert length(result.report_failures) == 1

            for group <- ["not", "or"] do
              checks = [%{group => [check, %{"variable" => "source", "operator" => "exists"}]}]
              grouped = TestChecks.evaluate_result(instance, datafile, checks, nil, make_ref())
              refute grouped.passed
              assert grouped.error
            end
          end
        end
      after
        Featurevisor.close(instance)
      end
    end
  end

  test "CLI missing paths retain nonerror comparison and OR skips incompatible values" do
    datafile = datafile(["admin"], nil, nil)
    instance = Featurevisor.create_featurevisor(%{datafile: datafile, log_level: :fatal})

    try do
      for operator <- ["includesAny", "notIncludesAny"] do
        missing = %{
          "variable" => "source",
          "path" => ["missing"],
          "operator" => operator,
          "value" => []
        }

        result = TestChecks.evaluate_result(instance, datafile, [missing], nil, make_ref())
        refute result.passed
        refute result.error

        checks = [
          %{
            "or" => [
              %{"variable" => "source", "operator" => "exists"},
              %{
                "variable" => "source",
                "path" => ["items"],
                "operator" => operator,
                "compareTo" => %{"variable" => "candidates"}
              }
            ]
          }
        ]

        assert TestChecks.evaluate_result(instance, datafile, checks, nil, make_ref()).passed
      end
    after
      Featurevisor.close(instance)
    end
  end

  defp datafile(actual, candidates, requirement) do
    traffic = [%{"key" => "all", "segments" => "*", "percentage" => 100_000, "enabled" => true}]
    requirements = if is_nil(requirement), do: [], else: [requirement]

    %{
      "schemaVersion" => "2",
      "revision" => "includes-any",
      "segments" => %{},
      "features" => %{
        "sourceFeature" => %{
          "bucketBy" => "userId",
          "variablesSchema" => %{"items" => %{"type" => "object", "defaultValue" => actual}},
          "traffic" => traffic
        },
        "gate" => %{
          "bucketBy" => "userId",
          "conditions" => requirements,
          "traffic" => traffic
        },
        "override" => %{
          "bucketBy" => "userId",
          "variablesSchema" => %{"result" => %{"type" => "boolean", "defaultValue" => false}},
          "traffic" => [
            Map.put(hd(traffic), "variableOverrides", %{
              "result" => [
                %{"key" => "matched", "conditions" => requirements, "value" => true}
              ]
            })
          ]
        }
      },
      "variables" => %{
        "source" => %{"type" => "object", "defaultValue" => %{"items" => actual}},
        "candidates" => %{"type" => "object", "defaultValue" => candidates},
        "gate" => %{
          "type" => "boolean",
          "defaultValue" => true,
          "disabledValue" => false,
          "conditions" => requirements
        }
      }
    }
  end
end
