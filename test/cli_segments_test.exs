defmodule Featurevisor.CLI.SegmentsTest do
  use ExUnit.Case, async: true
  alias Featurevisor.{Child, Module}
  alias Featurevisor.CLI.{Segments, TestChecks, TestCoverage}

  defp datafile do
    %{
      "schemaVersion" => "4",
      "revision" => "segments",
      "segments" => %{},
      "features" => %{
        "gate" => %{
          "bucketBy" => "id",
          "traffic" => [%{"key" => "some", "conditions" => "*", "percentage" => 10_000}]
        }
      },
      "variables" => %{
        "policy" => %{"type" => "object", "defaultValue" => %{"items" => [%{"enabled" => false}]}}
      }
    }
  end

  defp definitions do
    %{
      "eligible" => %{
        "conditions" => [
          "flag",
          %{
            "variable" => "policy",
            "path" => ["items", 0, "enabled"],
            "operator" => "equals",
            "value" => true
          }
        ]
      },
      "flag" => %{"conditions" => %{"feature" => "gate"}}
    }
  end

  test "SDK gates use compiled paths, at and root or child sticky state" do
    original = datafile()
    definitions = definitions()
    assert Segments.preflight("eligible", original, definitions) == :ok
    {prepared, keys} = Segments.prepare(original, definitions)
    coverage = TestCoverage.open(true)
    module = %Module{bucket_value: fn _ -> 5_000 end}

    f =
      Featurevisor.create_featurevisor(%{
        datafile: prepared,
        log_level: :fatal,
        sticky_variables: %{"policy" => %{"items" => [%{"enabled" => true}]}},
        modules: [module, TestCoverage.module(coverage, %{}, Map.values(keys))]
      })

    child =
      Featurevisor.spawn(f, %{"country" => "nl"}, %{
        sticky_features: %{"gate" => %{"enabled" => true}},
        sticky_variables: %{"policy" => %{"items" => [%{"enabled" => true}]}}
      })

    checks = [%{"segment" => "eligible", "matches" => true}]
    options = %{definitions: definitions, keys: keys}

    assert TestChecks.evaluate_result(f, prepared, checks, nil, make_ref(), "checks", options).passed

    assert TestChecks.evaluate_result(child, prepared, checks, nil, make_ref(), "checks", options).passed

    Child.set_sticky_variables(child, %{}, true)

    refute TestChecks.evaluate_result(child, prepared, checks, nil, make_ref(), "checks", options).passed

    selections = TestCoverage.selections(coverage)
    assert Enum.any?(selections, &(&1["featureKey"] == "gate"))
    refute Enum.any?(selections, &(&1["featureKey"] in Map.values(keys)))
    Child.close(child)
    Featurevisor.close(f)
    TestCoverage.close(coverage)
  end

  test "selected Target segment specialization wins and helpers do not overwrite real features" do
    definitions = %{"eligible" => %{"conditions" => "*"}}

    selected =
      datafile()
      |> put_in(["segments", "eligible"], %{"conditions" => []})
      |> put_in(["features", "__featurevisor_segment_test__eligible"], %{
        "bucketBy" => "id",
        "traffic" => []
      })

    {prepared, keys} = Segments.prepare(selected, definitions)
    assert keys["eligible"] == "__featurevisor_segment_test__eligible_"
    assert prepared["segments"]["eligible"]["conditions"] == []

    assert prepared["features"]["__featurevisor_segment_test__eligible"] ==
             selected["features"]["__featurevisor_segment_test__eligible"]

    f = Featurevisor.create_featurevisor(%{datafile: prepared, log_level: :fatal})

    result =
      TestChecks.evaluate_result(
        f,
        prepared,
        [%{"segment" => "eligible", "matches" => false}],
        nil,
        make_ref(),
        "checks",
        %{definitions: definitions, keys: keys}
      )

    assert result.passed
    Featurevisor.close(f)
  end

  test "preflight traverses skipped and stringified references, composition and feature variable schemas without getters" do
    for condition <- [
          %{"or" => ["*", %{"feature" => "missing"}]},
          Jason.encode!(%{"feature" => "gate", "variable" => "missing", "operator" => "isNull"}),
          %{"variable" => "alias", "operator" => "notNull"}
        ] do
      definitions = %{"root" => %{"conditions" => "leaf"}, "leaf" => %{"conditions" => condition}}

      selected =
        datafile()
        |> put_in(["variables", "alias"], %{"type" => "object", "compose" => "missing"})

      {prepared, keys} = Segments.prepare(selected, definitions)
      count = :atomics.new(1, [])

      f =
        Featurevisor.create_featurevisor(%{
          datafile: prepared,
          log_level: :fatal,
          modules: [
            %Module{
              before_evaluation: fn options ->
                :atomics.add_get(count, 1, 1)
                options
              end
            }
          ]
        })

      result =
        TestChecks.evaluate_result(
          f,
          prepared,
          [%{"not" => [%{"segment" => "root", "matches" => true}]}],
          nil,
          make_ref(),
          "checks",
          %{definitions: definitions, keys: keys}
        )

      assert result.error
      assert :atomics.get(count, 1) == 0
      Featurevisor.close(f)
    end
  end

  test "segment cycles are errors which check NOT cannot invert and attribute chains need no datafile" do
    definitions = %{"root" => %{"conditions" => "leaf"}, "leaf" => %{"conditions" => "root"}}
    {prepared, keys} = Segments.prepare(Segments.empty(), definitions)
    f = Featurevisor.create_featurevisor(%{datafile: prepared, log_level: :fatal})

    result =
      TestChecks.evaluate_result(
        f,
        prepared,
        [%{"not" => [%{"segment" => "root", "matches" => true}]}],
        nil,
        make_ref(),
        "checks",
        %{definitions: definitions, keys: keys}
      )

    assert result.error
    Featurevisor.close(f)

    definitions =
      put_in(definitions, ["leaf", "conditions"], %{
        "attribute" => "age",
        "operator" => "greaterThan",
        "value" => 18
      })

    refute Segments.dependent?("root", definitions)
    assert Segments.preflight("root", Segments.empty(), definitions) == :ok
    assert Segments.dependent?("eligible", definitions())
  end
end
