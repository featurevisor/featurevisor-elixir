defmodule Featurevisor.ModulesAndChildTest do
  use ExUnit.Case, async: true
  alias Featurevisor.Module

  test "module lifecycle, diagnostics, transformations, removal, and duplicate names" do
    parent = self()

    f =
      Featurevisor.create_featurevisor(%{
        datafile: Featurevisor.TestFixtures.datafile(),
        log_level: :debug,
        on_diagnostic: fn diagnostic -> send(parent, {:instance, diagnostic}) end
      })

    module = %Module{
      name: "audit",
      setup: fn api ->
        send(parent, {:revision, api.get_revision.()})

        api.on_diagnostic.(fn diagnostic -> send(parent, {:module, diagnostic}) end, %{
          log_level: :debug
        })

        api.report_diagnostic.(%{level: :info, code: "ready", message: "ready", details: %{}})
      end,
      before_evaluation: fn options ->
        %{options | context: Map.put(options.context, "country", "nl")}
      end,
      bucket_key: fn options -> options.bucket_key <> ".module" end,
      bucket_value: fn _ -> 75_000 end,
      after_evaluation: fn evaluation, _ -> evaluation end,
      close: fn -> send(parent, :closed) end
    }

    unsubscribe = Featurevisor.add_module(f, module)
    assert_receive {:revision, "test"}
    assert_receive {:instance, %{code: "ready", module: "audit"}}
    assert Featurevisor.enabled?(f, "flag", %{"userId" => "1"})
    assert Featurevisor.get_variation(f, "experiment", %{"userId" => "1"}) == "treatment"

    assert Featurevisor.add_module(f, %{module | close: nil}) == nil
    assert_receive {:instance, %{code: "duplicate_module", module_name: "audit"}}
    unsubscribe.()
    unsubscribe.()
    assert_receive :closed
    Featurevisor.close(f)
  end

  test "module phases follow the canonical order" do
    parent = self()

    modules =
      Enum.map(["first", "second"], fn name ->
        %Module{
          name: name,
          before_evaluation: fn options ->
            send(parent, "beforeEvaluation:#{name}")
            options
          end,
          after_evaluation: fn evaluation, _ ->
            send(parent, "afterEvaluation:#{name}")
            evaluation
          end
        }
      end)

    f =
      Featurevisor.create_featurevisor(%{
        datafile: Featurevisor.TestFixtures.datafile(),
        modules: modules,
        log_level: :fatal
      })

    Featurevisor.enabled?(f, "flag", %{"userId" => "1"})

    assert_receive "beforeEvaluation:first"
    assert_receive "beforeEvaluation:second"
    assert_receive "afterEvaluation:first"
    assert_receive "afterEvaluation:second"
  end

  test "required feature evaluations use modules" do
    parent = self()

    datafile = %{
      "schemaVersion" => "2",
      "revision" => "required",
      "segments" => %{},
      "features" => %{
        "enabled" => %{
          "bucketBy" => "userId",
          "traffic" => [%{"key" => "all", "segments" => "*", "percentage" => 100_000}]
        },
        "disabled" => %{"bucketBy" => "userId", "traffic" => []},
        "dependent" => %{
          "bucketBy" => "userId",
          "requiredFeatures" => ["enabled"],
          "traffic" => [%{"key" => "all", "segments" => "*", "percentage" => 100_000}]
        }
      }
    }

    module = %Module{
      name: "redirect",
      before_evaluation: fn options ->
        if options.feature_key == "enabled",
          do: %{options | feature_key: "disabled"},
          else: options
      end
    }

    f =
      Featurevisor.create_featurevisor(%{
        datafile: datafile,
        modules: [module],
        log_level: :debug,
        on_diagnostic: fn diagnostic -> send(parent, {:prerequisite, diagnostic}) end
      })

    refute Featurevisor.enabled?(f, "dependent")
    evaluation = Featurevisor.evaluate_flag(f, "dependent")
    assert evaluation.reason == :conditions_unmet
    assert evaluation.enabled == false
    assert evaluation.conditions == [%{"feature" => "enabled"}]

    wire = evaluation |> Featurevisor.Evaluation.to_map() |> Jason.encode!() |> Jason.decode!()
    assert wire["reason"] == "conditions_unmet"
    assert wire["conditions"] == [%{"feature" => "enabled"}]

    assert_receive {:prerequisite,
                    %{
                      code: "conditions_unmet",
                      details: %{
                        reason: "conditions_unmet",
                        evaluation: %{"reason" => :conditions_unmet}
                      }
                    }}

    refute_receive {:prerequisite, %{code: "required"}}
    Featurevisor.close(f)
  end

  test "explicit null feature variable beats the caller default" do
    datafile = %{
      "schemaVersion" => "2",
      "revision" => "null",
      "segments" => %{},
      "features" => %{
        "feature" => %{
          "bucketBy" => "userId",
          "variablesSchema" => %{"value" => %{"type" => "json", "defaultValue" => nil}},
          "traffic" => [%{"key" => "all", "segments" => "*", "percentage" => 100_000}]
        }
      }
    }

    f = Featurevisor.create_featurevisor(%{datafile: datafile, log_level: :fatal})

    evaluation =
      Featurevisor.evaluate_variable(f, "feature", "value", %{}, %{
        default_variable_value: %{"fallback" => true}
      })

    assert evaluation.variable_value == nil
  end

  test "child snapshots existing parent keys, inherits new keys, and owns sticky" do
    f =
      Featurevisor.create_featurevisor(%{
        datafile: Featurevisor.TestFixtures.datafile(),
        context: %{"country" => "nl", "plan" => "free"},
        log_level: :fatal
      })

    child =
      Featurevisor.spawn(f, %{"country" => "de"}, %{
        sticky_features: %{"flag" => %{"enabled" => true}}
      })

    Featurevisor.set_context(f, %{"country" => "us", "plan" => "pro", "region" => "eu"}, true)

    assert Featurevisor.Child.get_context(child) == %{
             "country" => "de",
             "plan" => "free",
             "region" => "eu"
           }

    assert Featurevisor.Child.enabled?(child, "flag")
    assert Featurevisor.Child.get_variable_string(child, "experiment", "title") == "Control"
    assert Featurevisor.Child.get_variable_integer(child, "experiment", "count") == 0

    assert Featurevisor.Child.get_variable_json(child, "experiment", "config") == %{
             "enabled" => true
           }

    assert Featurevisor.Child.get_feature_evaluations(child, %{}, ["flag"])["flag"].enabled
    Featurevisor.Child.close(child)
    assert Featurevisor.Child.set_context(child, %{"country" => "fr"}) == :ok
    assert Featurevisor.Child.set_sticky_features(child, %{}) == :ok
    refute Featurevisor.Child.enabled?(child, "missing")
    Featurevisor.Child.close(child)
    Featurevisor.close(f)
  end

  test "callbacks may re-enter the instance without deadlocking" do
    parent = self()

    f =
      Featurevisor.create_featurevisor(%{
        datafile: Featurevisor.TestFixtures.datafile(),
        log_level: :debug,
        on_diagnostic: fn _ -> :ok end
      })

    Featurevisor.on(f, :context_set, fn _ ->
      send(parent, {:revision, Featurevisor.get_revision(f)})
    end)

    Featurevisor.set_context(f, %{"country" => "nl"})
    assert_receive {:revision, "test"}
    Featurevisor.close(f)
  end

  test "unified modules and child sticky state support global variables" do
    datafile = %{
      "schemaVersion" => "2",
      "revision" => "global",
      "segments" => %{},
      "features" => %{
        "disabled" => %{"bucketBy" => "userId", "traffic" => []}
      },
      "variables" => %{
        "message" => %{
          "type" => "string",
          "defaultValue" => "default",
          "overrides" => [
            %{
              "key" => "nl",
              "conditions" => %{"attribute" => "country", "operator" => "equals", "value" => "nl"},
              "value" => "matched"
            }
          ]
        }
      }
    }

    module = %Module{
      name: "global",
      before_evaluation: fn options ->
        %{options | context: Map.put(options.context, "country", "nl")}
      end,
      after_evaluation: fn evaluation, _ -> %{evaluation | variable_value: "after"} end
    }

    f =
      Featurevisor.create_featurevisor(%{
        datafile: datafile,
        sticky_features: %{"disabled" => %{"enabled" => true}},
        sticky_variables: %{"message" => "parent"},
        modules: [module],
        log_level: :fatal
      })

    child = Featurevisor.spawn(f, %{}, %{sticky_variables: %{"message" => "child"}})
    plain = Featurevisor.spawn(f)
    assert Featurevisor.get_global_variable(f, "message") == "after"
    assert Featurevisor.Child.get_global_variable(child, "message") == "after"
    assert Featurevisor.Child.get_global_variable(plain, "message") == "after"

    Featurevisor.remove_module(f, "global")
    assert Featurevisor.enabled?(f, "disabled")
    refute Featurevisor.Child.enabled?(plain, "disabled")
    assert Featurevisor.get_global_variable(f, "message") == "parent"
    assert Featurevisor.Child.get_global_variable(child, "message") == "child"
    assert Featurevisor.Child.get_global_variable(plain, "message") == "default"
    Featurevisor.close(f)
  end

  test "required features treat a source module error as disabled" do
    datafile = %{
      "schemaVersion" => "2",
      "revision" => "module-error-requirement",
      "segments" => %{},
      "features" => %{
        "source" => %{
          "bucketBy" => "userId",
          "traffic" => [%{"key" => "all", "segments" => "*", "percentage" => 100_000}]
        },
        "explicitFalse" => %{
          "bucketBy" => "userId",
          "requiredFeatures" => [%{"feature" => "source", "enabled" => false}],
          "traffic" => [%{"key" => "all", "segments" => "*", "percentage" => 100_000}]
        },
        "negated" => %{
          "bucketBy" => "userId",
          "requiredFeatures" => %{"not" => ["source"]},
          "traffic" => [%{"key" => "all", "segments" => "*", "percentage" => 100_000}]
        }
      }
    }

    module = %Module{
      name: "source-error",
      before_evaluation: fn options ->
        if options.feature_key == "source", do: raise("source failed"), else: options
      end
    }

    f =
      Featurevisor.create_featurevisor(%{
        datafile: datafile,
        modules: [module],
        log_level: :fatal
      })

    refute Featurevisor.enabled?(f, "source")
    assert Featurevisor.enabled?(f, "explicitFalse")
    assert Featurevisor.enabled?(f, "negated")
    Featurevisor.close(f)
  end

  test "concurrent module registration reserves names and returned unsubscribers survive close" do
    parent = self()
    f = Featurevisor.create_featurevisor(%{log_level: :fatal})
    gate = make_ref()

    module = %Module{
      name: "one",
      setup: fn _ ->
        send(parent, {:setup, self()})

        receive do
          {:continue, ^gate} -> :ok
        end
      end
    }

    first = Task.async(fn -> Featurevisor.add_module(f, module) end)
    assert_receive {:setup, setup_process}
    assert Featurevisor.add_module(f, module) == nil
    send(setup_process, {:continue, gate})
    unsubscribe = Task.await(first)

    event_unsubscribe = Featurevisor.on(f, :context_set, fn _ -> :ok end)
    Featurevisor.close(f)
    assert unsubscribe.() == :ok
    assert event_unsubscribe.() == :ok
  end
end
