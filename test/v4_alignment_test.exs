defmodule Featurevisor.V4AlignmentTest do
  use ExUnit.Case, async: true
  alias Featurevisor.{Evaluation, Module}

  @conditions Path.expand("../conformance/sdk-conditions.json", __DIR__)
              |> File.read!()
              |> Jason.decode!()
  @composition Path.expand("../conformance/sdk-composition.json", __DIR__)
               |> File.read!()
               |> Jason.decode!()

  test "shared diagnostics fixture checks revision cache and reentry" do
    fixture =
      Path.expand("../conformance/sdk-diagnostics.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

    assert fixture["kind"] == "featurevisor.sdk-diagnostics"
    assert fixture["version"] == 1
    assert is_list(fixture["cases"]) and fixture["cases"] != []

    for item <- fixture["cases"], _repetition <- 1..2 do
      handle = :ets.new(:diagnostics_fixture, [:set, :public])

      f =
        Featurevisor.create_featurevisor(%{
          log_level: :error,
          on_diagnostic: fn diagnostic ->
            if diagnostic.code == "conditions_parse_error" do
              [{:instance, owner}] = :ets.lookup(handle, :instance)

              details =
                Map.new(diagnostic.details, fn {key, value} -> {to_string(key), value} end)

              entry = %{
                "code" => diagnostic.code,
                "level" => Atom.to_string(diagnostic.level),
                "details" => details,
                "revision" => Featurevisor.get_revision(owner)
              }

              :ets.insert(handle, {{:diagnostic, make_ref()}, entry})

              if details["entityType"] == "feature" and
                   :ets.insert_new(handle, {:reentering, true}) do
                try do
                  before = length(:ets.match_object(handle, {{:diagnostic, :_}, :_}))
                  Featurevisor.enabled?(owner, Map.fetch!(details, "entityKey"))

                  if length(:ets.match_object(handle, {{:diagnostic, :_}, :_})) != before,
                    do: :ets.insert(handle, {:reentry_failed, true})
                after
                  :ets.delete(handle, :reentering)
                end
              end
            end
          end
        })

      :ets.insert(handle, {:instance, f})

      try do
        assert is_list(item["operations"]) and item["operations"] != []

        for operation <- item["operations"] do
          :ets.match_delete(handle, {{:diagnostic, :_}, :_})

          result =
            case operation["action"] do
              "setDatafile" ->
                Featurevisor.set_datafile(
                  f,
                  Map.fetch!(operation, "datafile"),
                  Map.fetch!(operation, "replace")
                )

              "isEnabled" ->
                Featurevisor.enabled?(f, Map.fetch!(operation, "feature"))

              other ->
                flunk("unsupported diagnostics action #{inspect(other)}")
            end

          assert is_boolean(operation["expectedResult"])
          assert result === operation["expectedResult"], item["name"]
          seen = :ets.match_object(handle, {{:diagnostic, :_}, :_}) |> Enum.map(&elem(&1, 1))

          assert Enum.frequencies(seen) === Enum.frequencies(Map.fetch!(operation, "diagnostics")),
                 item["name"]

          refute :ets.member(handle, :reentry_failed)
        end
      after
        Featurevisor.close(f)
        :ets.delete(handle)
      end
    end
  end

  test "runs every conditions capability case twice, including dependency callback order" do
    assert @conditions["version"] == 1
    assert @conditions["capability"] == "unified-conditions"
    assert is_list(@conditions["cases"]) and @conditions["cases"] != []

    executed =
      Enum.map(@conditions["cases"], fn item ->
        assert item["type"] in ["flag", "variable"]
        parent = self()

        module = %Module{
          before_evaluation: fn options ->
            if options[:dependency_purpose] do
              entry = %{"dependencyPurpose" => Atom.to_string(options.dependency_purpose)}

              entry =
                if options[:feature_key],
                  do: Map.put(entry, "feature", options.feature_key),
                  else: entry

              entry =
                if options[:variable_key],
                  do: Map.put(entry, "variable", options.variable_key),
                  else: entry

              send(parent, {:dependency, entry})
            end

            options
          end
        }

        options =
          Map.new(item["options"] || %{}, fn
            {"stickyFeatures", value} -> {:sticky_features, value}
            {"stickyVariables", value} -> {:sticky_variables, value}
            {"context", value} -> {:context, value}
          end)

        f =
          Featurevisor.create_featurevisor(
            Map.merge(options, %{datafile: item["datafile"], modules: [module], log_level: :fatal})
          )

        try do
          for attempt <- 1..2 do
            drain()

            evaluation =
              if item["type"] == "flag",
                do: Featurevisor.evaluate_flag(f, item["feature"], item["context"] || %{}),
                else:
                  Featurevisor.evaluate_global_variable(
                    f,
                    item["variable"],
                    item["context"] || %{}
                  )

            wire = Evaluation.to_map(evaluation) |> Map.update!("reason", &Atom.to_string/1)

            Enum.each(Map.delete(item["expected"], "value"), fn {key, expected} ->
              assert Map.has_key?(wire, key), "#{item["name"]}: missing #{key}"
              assert wire[key] == expected, "#{item["name"]}: #{key}, attempt #{attempt}"
            end)

            seen = drain()

            if Map.has_key?(item, "dependencies"),
              do: assert(seen == item["dependencies"], item["name"])

            if Map.has_key?(item["expected"], "value"),
              do:
                assert(
                  Featurevisor.get_global_variable(f, item["variable"], item["context"] || %{}) ==
                    item["expected"]["value"],
                  item["name"]
                )

            if item["type"] == "flag",
              do:
                assert(
                  Featurevisor.enabled?(f, item["feature"], item["context"] || %{}) ==
                    (item["expected"]["enabled"] == true),
                  item["name"]
                )

            attempt
          end
        after
          Featurevisor.close(f)
          drain()
        end
      end)

    assert Enum.frequencies(List.flatten(executed)) == %{
             1 => length(@conditions["cases"]),
             2 => length(@conditions["cases"])
           }
  end

  test "runs all composition cases twice and checks every expected evaluation field" do
    assert @composition["version"] == 2
    assert @composition["capability"] == "composition-and-overrides"
    assert is_list(@composition["cases"]) and @composition["cases"] != []

    executed =
      Enum.map(@composition["cases"], fn item ->
        datafile = @composition["datafile"]

        f =
          Featurevisor.create_featurevisor(%{
            datafile: datafile,
            log_level: :fatal,
            sticky_features: item["stickyFeatures"],
            sticky_variables: item["stickyVariables"]
          })

        try do
          attempts =
            for attempt <- 1..2 do
              assert Featurevisor.get_global_variable(f, item["variable"], item["context"]) ==
                       item["expectedValue"],
                     item["name"]

              evaluation =
                Featurevisor.evaluate_global_variable(f, item["variable"], item["context"])

              wire = Evaluation.to_map(evaluation) |> Map.update!("reason", &Atom.to_string/1)

              Enum.each(item["expectedEvaluation"], fn {key, expected} ->
                assert Map.has_key?(wire, key), "#{item["name"]}: missing #{key}"
                assert wire[key] == expected, "#{item["name"]}: #{key}"
              end)

              expected =
                if item["stickyVariables"] && Map.has_key?(item["stickyVariables"], "policy"),
                  do: item["stickyVariables"]["policy"],
                  else: %{"limit" => 50, "methods" => ["card"]}

              assert Featurevisor.get_global_variable(f, "policy") == expected
              attempt
            end

          assert datafile == @composition["datafile"]
          attempts
        after
          Featurevisor.close(f)
        end
      end)

    assert Enum.frequencies(List.flatten(executed)) == %{
             1 => length(@composition["cases"]),
             2 => length(@composition["cases"])
           }
  end

  defp drain do
    receive do
      {:dependency, entry} -> [entry | drain()]
    after
      0 -> []
    end
  end
end
