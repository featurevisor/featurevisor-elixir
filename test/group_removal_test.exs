defmodule Featurevisor.GroupRemovalTest do
  use ExUnit.Case, async: true

  defp datafile do
    Jason.decode!(~s'''
    {
      "schemaVersion":"2","revision":"exclusion","segments":{},"features":{
        "priority":{"bucketBy":"userId","traffic":[{"key":"all","segments":"*","percentage":50000}]},
        "fallback":{"bucketBy":"userId","requiredFeatures":[{"feature":"priority","enabled":false}],"traffic":[{"key":"all","segments":"*","percentage":100000}]},
        "allocator":{"bucketBy":"userId","variations":[{"value":"a","variables":{"label":"A"}},{"value":"b","variables":{"label":"B"}}],"variablesSchema":{"label":{"type":"string","defaultValue":"none"}},"traffic":[{"key":"all","segments":"*","percentage":100000,"allocation":[{"variation":"a","range":[0,50000]},{"variation":"b","range":[50000,100000]}]}]},
        "experimentA":{"bucketBy":"userId","requiredFeatures":[{"feature":"allocator","variation":"a"}],"traffic":[{"key":"all","segments":"*","percentage":100000}]},
        "experimentB":{"bucketBy":"userId","requiredFeatures":[{"feature":"allocator","variation":"b"}],"traffic":[{"key":"all","segments":"*","percentage":100000}]},
        "off":{"bucketBy":"userId","traffic":[{"key":"all","segments":"*","percentage":0}]},
        "explicitOff":{"bucketBy":"userId","traffic":[{"key":"all","segments":"*","percentage":100000,"enabled":false}]},
        "explicitOn":{"bucketBy":"userId","traffic":[{"key":"all","segments":"*","percentage":50000,"enabled":true}]}
      }
    }
    ''')
  end

  defp instance(datafile) do
    parent = self()

    f =
      Featurevisor.create_featurevisor(%{
        datafile: datafile,
        log_level: :warn,
        on_diagnostic: fn diagnostic -> send(parent, {:unexpected_diagnostic, diagnostic}) end
      })

    on_exit(fn -> Featurevisor.close(f) end)
    f
  end

  test "legacy feature ranges are ignored without warnings or parsing" do
    baseline = datafile()
    expected = instance(baseline)

    for ranges <- [[[0, 1]], [[0, 100_000]], [], nil, "removed", [["invalid", %{}]]] do
      features =
        Map.new(baseline["features"], fn {key, feature} ->
          {key, Map.put(feature, "ranges", ranges)}
        end)

      actual = instance(Jason.encode!(%{baseline | "features" => features}))

      for index <- 1..40 do
        context = %{"userId" => "user-#{index}"}

        for key <- Map.keys(features) do
          assert Featurevisor.evaluate_flag(actual, key, context) ==
                   Featurevisor.evaluate_flag(expected, key, context)
        end

        assert Featurevisor.get_variation(actual, "allocator", context) ==
                 Featurevisor.get_variation(expected, "allocator", context)

        assert Featurevisor.get_variable(actual, "allocator", "label", context) ==
                 Featurevisor.get_variable(expected, "allocator", "label", context)
      end
    end

    refute_received {:unexpected_diagnostic, _}
  end

  test "priority requirements exclude overlapping features across ordinary hash cohorts" do
    for holdout <- [false, true] do
      f = instance(population_datafile(holdout))
      reverse = instance(population_datafile(holdout))

      winners =
        for index <- 1..20_000 do
          context = %{"userId" => "user-#{index}"}
          priority = Featurevisor.enabled?(f, "priority", context)
          fallback = Featurevisor.enabled?(f, "fallback", context)
          reverse_fallback = Featurevisor.enabled?(reverse, "fallback", context)
          reverse_priority = Featurevisor.enabled?(reverse, "priority", context)
          refute priority and fallback
          refute reverse_priority and reverse_fallback
          assert {priority, fallback} == {reverse_priority, reverse_fallback}
          {priority, fallback}
        end

      assert_population(winners, {true, false}, 10_000)
      assert_population(winners, {false, true}, if(holdout, do: 5000, else: 10_000))
      assert_population(winners, {false, false}, if(holdout, do: 5000, else: 0))
      refute Enum.any?(winners, &(&1 == {true, true}))
    end

    refute_received {:unexpected_diagnostic, _}
  end

  test "shared variation allocation gates exclusive features across ordinary hash cohorts" do
    for holdout <- [false, true] do
      f = instance(population_datafile(holdout))
      reverse = instance(population_datafile(holdout))

      variations =
        for index <- 1..20_000 do
          context = %{"userId" => "user-#{index}"}
          a = Featurevisor.enabled?(f, "experimentA", context)
          b = Featurevisor.enabled?(f, "experimentB", context)
          reverse_b = Featurevisor.enabled?(reverse, "experimentB", context)
          reverse_a = Featurevisor.enabled?(reverse, "experimentA", context)
          refute a and b
          refute reverse_a and reverse_b
          assert {a, b} == {reverse_a, reverse_b}
          variation = Featurevisor.get_variation(f, "allocator", context)
          assert variation in ["a", "b", "holdout"]
          assert a == (variation == "a")
          assert b == (variation == "b")

          assert Featurevisor.get_variable(f, "allocator", "label", context) ==
                   String.upcase(variation)

          assert Featurevisor.evaluate_variation(f, "allocator", context).reason == :allocated
          variation
        end

      assert_population(variations, "a", if(holdout, do: 9000, else: 10_000))
      assert_population(variations, "b", if(holdout, do: 9000, else: 10_000))
      assert_population(variations, "holdout", if(holdout, do: 2000, else: 0))
    end

    refute_received {:unexpected_diagnostic, _}
  end

  defp population_datafile(false), do: datafile()

  defp population_datafile(true) do
    datafile()
    |> put_in(["features", "fallback", "traffic", Access.at(0), "percentage"], 50_000)
    |> put_in(["features", "allocator", "variations"], [
      %{"value" => "a", "variables" => %{"label" => "A"}},
      %{"value" => "b", "variables" => %{"label" => "B"}},
      %{"value" => "holdout", "variables" => %{"label" => "HOLDOUT"}}
    ])
    |> put_in(["features", "allocator", "traffic", Access.at(0), "allocation"], [
      %{"variation" => "a", "range" => [0, 45_000]},
      %{"variation" => "b", "range" => [45_000, 90_000]},
      %{"variation" => "holdout", "range" => [90_000, 100_000]}
    ])
  end

  defp assert_population(values, value, 0), do: refute(Enum.any?(values, &(&1 == value)))

  defp assert_population(values, value, expected) do
    # Allow two percentage points of sampling variation across 20,000 users.
    assert abs(Enum.count(values, &(&1 == value)) - expected) <= 400
  end
end
