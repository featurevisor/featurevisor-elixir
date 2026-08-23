defmodule Featurevisor.ConformanceTest do
  use ExUnit.Case, async: true
  alias Featurevisor.{Bucketer, Conditions, Module}

  @fixture Path.expand("../conformance/sdk-v3.json", __DIR__) |> File.read!() |> Jason.decode!()

  test "executes the canonical fixture version and bucket boundaries" do
    assert @fixture["version"] == 2
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
    end)
  end

  test "executes all portable date and semantic version values" do
    cache = :ets.new(:portable_values, [:set, :public])
    report = fn diagnostic -> flunk("unexpected diagnostic #{inspect(diagnostic)}") end

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
  end

  test "preserves aggregate empty variation default" do
    item = @fixture["defaults"]["aggregateCase"]
    f = Featurevisor.create_featurevisor(%{datafile: item["datafile"], log_level: :fatal})

    result =
      Featurevisor.get_all_evaluations(f, %{}, [], %{
        default_variation_value: item["defaultVariationValue"]
      })

    assert result["experiment"] == %{enabled: false, variation: ""}
    Featurevisor.close(f)
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
