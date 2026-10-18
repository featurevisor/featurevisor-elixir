defmodule Featurevisor.EmptyModulesHotPathTest do
  use ExUnit.Case, async: false

  test "an ordinary warm read does not rebuild callback options without modules" do
    sdk =
      Featurevisor.create_featurevisor(%{
        log_level: :fatal,
        datafile: %{
          "schemaVersion" => "4",
          "revision" => "hot",
          "segments" => %{},
          "features" => %{"flag" => %{"bucketBy" => "id", "traffic" => []}},
          "variables" => %{"object" => %{"type" => "object", "defaultValue" => %{"n" => 1}}}
        }
      })

    on_exit(fn -> Featurevisor.close(sdk) end)
    Featurevisor.enabled?(sdk, "flag")
    Featurevisor.get_global_variable(sdk, "object")

    targets = [
      {Featurevisor.Evaluator, :before_modules, 1},
      {Featurevisor, :before_global_modules, 4},
      {Featurevisor.EvaluationSession, :update_current, 2},
      {Featurevisor, :global_dependencies, 4}
    ]

    for target <- targets, do: assert(:erlang.trace_pattern(target, true, [:call_count]) == 1)

    try do
      Featurevisor.enabled?(sdk, "flag")
      assert Featurevisor.get_global_variable(sdk, "object") == %{"n" => 1}

      for target <- targets,
          do: assert(:erlang.trace_info(target, :call_count) == {:call_count, 0})
    after
      for target <- targets, do: :erlang.trace_pattern(target, false, [:call_count])
    end
  end

  test "global reads without modules retain current parent and child sticky values and defaults" do
    sdk = create_global_sdk()
    child = Featurevisor.spawn(sdk)
    on_exit(fn -> Featurevisor.close(sdk) end)

    assert Featurevisor.get_global_variable(sdk, "alias") == %{"n" => 1}
    assert Featurevisor.Child.get_global_variable(child, "alias") == %{"n" => 1}

    Featurevisor.set_sticky_variables(sdk, %{"object" => %{"n" => 2}})
    Featurevisor.Child.set_sticky_variables(child, %{"object" => %{"n" => 3}})
    assert Featurevisor.get_global_variable(sdk, "alias") == %{"n" => 2}
    assert Featurevisor.Child.get_global_variable(child, "alias") == %{"n" => 3}

    Featurevisor.set_sticky_variables(sdk, %{}, true)
    Featurevisor.Child.set_sticky_variables(child, %{}, true)
    assert Featurevisor.get_global_variable(sdk, "alias") == %{"n" => 1}
    assert Featurevisor.Child.get_global_variable(child, "alias") == %{"n" => 1}

    assert Featurevisor.get_global_variable(sdk, "missing", %{}, default_variable_value: 7) == 7
    assert Featurevisor.get_global_variable(sdk, "gated") == 0
    Featurevisor.set_sticky_features(sdk, %{"flag" => %{"enabled" => true}})
    assert Featurevisor.get_global_variable(sdk, "gated") == 1
  end

  test "global modules retain private boundaries, redirected identity and sticky replacements" do
    sdk = create_global_sdk()
    on_exit(fn -> Featurevisor.close(sdk) end)
    parent = self()

    module = %Featurevisor.Module{
      name: "global-boundary",
      before_evaluation: fn options ->
        send(parent, {:before_global, options})

        if options[:variable_key] == "redirect" do
          options
          |> Map.put(:variable_key, "gated_alias")
          |> Map.put(:sticky_features, %{"flag" => %{"enabled" => true}})
          |> Map.put(:sticky_variables, %{"object" => %{"n" => 9}})
        else
          options
        end
      end,
      after_evaluation: fn evaluation, options ->
        send(parent, {:after_global, options})
        evaluation
      end
    }

    remove = Featurevisor.add_module(sdk, module)
    target = {Featurevisor, :before_global_modules, 4}
    assert :erlang.trace_pattern(target, true, [:call_count]) == 1

    try do
      assert Featurevisor.get_global_variable(sdk, "redirect") == %{"n" => 9}
      assert :erlang.trace_info(target, :call_count) == {:call_count, 2}

      for phase <- [:before_global, :after_global] do
        for _ <- 1..3 do
          assert_receive {^phase, options}

          refute Enum.any?(Map.keys(options), fn key ->
                   key in [
                     :sticky_owner,
                     :sticky_features_token,
                     :sticky_variables_token,
                     :regex_cache,
                     :state_signature,
                     :child_signature,
                     :session,
                     :state_source,
                     :entity_source,
                     :sticky_features_source,
                     :sticky_variables_source
                   ] or String.starts_with?(Atom.to_string(key), "__")
                 end)

          assert is_map(options.sticky_features)
          assert is_map(options.sticky_variables)
          if is_nil(options[:feature_key]), do: refute(Map.has_key?(options, :report))

          if options[:feature_key] == "flag" or options[:variable_key] == "object" do
            assert options.dependency_of == %{type: :variable, variable_key: "gated_alias"}
          end
        end
      end

      remove.()
      assert Featurevisor.get_global_variable(sdk, "gated_alias") == nil
      assert Featurevisor.get_global_variable(sdk, "alias") == %{"n" => 1}
      assert :erlang.trace_info(target, :call_count) == {:call_count, 2}
    after
      :erlang.trace_pattern(target, false, [:call_count])
    end
  end

  defp create_global_sdk do
    Featurevisor.create_featurevisor(%{
      log_level: :fatal,
      sticky_features: %{},
      sticky_variables: %{},
      datafile: %{
        "schemaVersion" => "4",
        "revision" => "global-hot",
        "segments" => %{},
        "features" => %{"flag" => %{"bucketBy" => "id", "traffic" => []}},
        "variables" => %{
          "object" => %{"type" => "object", "defaultValue" => %{"n" => 1}},
          "alias" => %{"type" => "object", "compose" => "object"},
          "gated_alias" => %{
            "type" => "object",
            "compose" => "object",
            "conditions" => %{"feature" => "flag", "enabled" => true}
          },
          "gated" => %{
            "type" => "integer",
            "defaultValue" => 1,
            "disabledValue" => 0,
            "conditions" => %{"feature" => "flag", "enabled" => true}
          }
        }
      }
    })
  end
end
