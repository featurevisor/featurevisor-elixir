defmodule Featurevisor.EvaluationSessionTest do
  use ExUnit.Case, async: true

  defp requirement(key), do: %{"variable" => key, "operator" => "equals", "value" => 1}

  defp variable(requirements \\ nil) do
    %{
      "type" => "integer",
      "defaultValue" => 1,
      "disabledValue" => 0,
      "conditions" => requirements || "*"
    }
  end

  defp feature(requirements \\ nil) do
    %{
      "bucketBy" => "userId",
      "requiredFeatures" => requirements,
      "traffic" => [%{"key" => "all", "segments" => "*", "percentage" => 100_000}]
    }
  end

  test "completed diamonds are memoised per public read with immediate requester metadata" do
    {variables, previous} =
      Enum.reduce(0..11, {%{"leaf" => variable()}, "leaf"}, fn index, {variables, previous} ->
        key = "level#{index}"
        {Map.put(variables, key, variable([requirement(previous), requirement(previous)])), key}
      end)

    parent = self()

    module = %Featurevisor.Module{
      before_evaluation: fn options ->
        send(parent, {:before, options[:variable_key], options[:dependency_of]})
        Map.new(options)
      end
    }

    f =
      Featurevisor.create_featurevisor(%{
        datafile: %{
          "schemaVersion" => "2",
          "revision" => "session",
          "segments" => %{},
          "features" => %{},
          "variables" => variables
        },
        modules: [module],
        log_level: :fatal
      })

    assert Featurevisor.get_global_variable(f, previous) == 1
    seen = for _ <- 1..13, do: assert_receive({:before, _, _})
    assert hd(seen) == {:before, previous, nil}
    assert Enum.at(seen, 1) == {:before, "level10", %{type: :variable, variable_key: previous}}
    refute_receive {:before, _, _}

    assert Featurevisor.get_global_variable(f, previous) == 1
    for _ <- 1..13, do: assert_receive({:before, _, _})
    refute_receive {:before, _, _}
    Featurevisor.close(f)
  end

  test "a root sticky replacement does not disable memo reuse in its dependency diamond" do
    {variables, root_key} =
      Enum.reduce(0..9, {%{"leaf" => variable()}, "leaf"}, fn index, {variables, previous} ->
        key = "level#{index}"
        {Map.put(variables, key, variable([requirement(previous), requirement(previous)])), key}
      end)

    parent = self()

    module = %Featurevisor.Module{
      before_evaluation: fn options ->
        if options[:variable_key] == root_key do
          Map.put(options, :sticky_variables, %{"leaf" => 1})
        else
          send(parent, {:diamond_read, options[:variable_key]})
          options
        end
      end
    }

    f =
      Featurevisor.create_featurevisor(%{
        datafile: %{
          "schemaVersion" => "2",
          "revision" => "replacement-diamond",
          "segments" => %{},
          "features" => %{},
          "variables" => variables
        },
        modules: [module],
        log_level: :fatal
      })

    assert Featurevisor.get_global_variable(f, root_key) == 1
    for _ <- 1..10, do: assert_receive({:diamond_read, _})
    refute_receive {:diamond_read, _}
    Featurevisor.close(f)
  end

  test "replacement ownership flows to descendants and still memoises duplicate edges" do
    parent = self()

    module = %Featurevisor.Module{
      before_evaluation: fn options ->
        cond do
          options[:type] == :variable and options[:variable_key] == "root" ->
            Map.put(options, :sticky_features, %{"gate" => %{"enabled" => true}})

          options[:type] == :flag and options[:feature_key] == "gate" ->
            send(parent, :replaced_gate_read)
            options

          true ->
            options
        end
      end
    }

    f =
      Featurevisor.create_featurevisor(%{
        datafile: %{
          "schemaVersion" => "2",
          "revision" => "replacement-descendants",
          "segments" => %{},
          "features" => %{"gate" => %{}},
          "variables" => %{
            "root" => variable() |> Map.put("requiredFeatures", ["gate", "gate"])
          }
        },
        modules: [module],
        log_level: :fatal
      })

    assert Featurevisor.get_global_variable(f, "root", %{"userId" => "test"}) == 1
    assert_receive :replaced_gate_read
    refute_receive :replaced_gate_read
    Featurevisor.close(f)
  end

  test "a hook replacement with the same map size and a different leaf is not reused" do
    count = :atomics.new(1, [])

    module = %Featurevisor.Module{
      before_evaluation: fn options ->
        if options[:type] == :flag and options[:feature_key] == "gate" do
          visit = :atomics.add_get(count, 1, 1)
          Map.put(options, :sticky_features, %{"gate" => %{"enabled" => visit == 1}})
        else
          options
        end
      end
    }

    f =
      Featurevisor.create_featurevisor(%{
        datafile: %{
          "schemaVersion" => "2",
          "revision" => "replacement-leaf",
          "segments" => %{},
          "features" => %{"gate" => feature()},
          "variables" => %{
            "root" => variable() |> Map.put("requiredFeatures", ["gate", "gate"])
          }
        },
        modules: [module],
        log_level: :fatal
      })

    assert Featurevisor.get_global_variable(f, "root", %{"userId" => "test"}) == 0
    assert :atomics.get(count, 1) == 2
    Featurevisor.close(f)
  end

  test "cycles surface as errors while missing operands keep ordinary fallback" do
    f =
      Featurevisor.create_featurevisor(%{
        datafile: %{
          "schemaVersion" => "2",
          "revision" => "cycle",
          "segments" => %{},
          "features" => %{},
          "variables" => %{
            "root" => variable([requirement("root")]),
            "outer" => variable([requirement("root")]),
            "ordinary" => variable([requirement("missing")])
          }
        },
        log_level: :fatal
      })

    assert Featurevisor.evaluate_global_variable(f, "root").error.message =~ "Circular"
    assert Featurevisor.evaluate_global_variable(f, "outer").error.message =~ "Circular"

    assert Featurevisor.evaluate_global_variable(f, "ordinary").reason ==
             :conditions_unmet

    Featurevisor.close(f)
  end

  test "requester dependent hooks do not share values across different parents" do
    parent = self()

    module = %Featurevisor.Module{
      after_evaluation: fn evaluation, options ->
        if options[:variable_key] == "leaf" do
          requester = options[:dependency_of][:variable_key]
          send(parent, {:leaf, requester})
          %{evaluation | variable_value: if(requester == "right", do: 2, else: 1)}
        else
          evaluation
        end
      end
    }

    f =
      Featurevisor.create_featurevisor(%{
        datafile: %{
          "schemaVersion" => "2",
          "revision" => "parents",
          "segments" => %{},
          "features" => %{},
          "variables" => %{
            "leaf" => variable(),
            "left" => variable([requirement("leaf"), requirement("leaf")]),
            "right" => variable([%{"variable" => "leaf", "operator" => "equals", "value" => 2}]),
            "root" => variable([requirement("left"), requirement("right")])
          }
        },
        modules: [module],
        log_level: :fatal
      })

    assert Featurevisor.get_global_variable(f, "root") == 1
    assert_receive {:leaf, "left"}
    assert_receive {:leaf, "right"}
    refute_receive {:leaf, _}
    Featurevisor.close(f)
  end

  test "sticky changes inside a hook invalidate earlier prerequisite reads" do
    parent = self()

    module = %Featurevisor.Module{
      after_evaluation: fn evaluation, _options ->
        if evaluation.variable_key == "leaf", do: send(parent, :leaf_read)
        if evaluation.variable_key == "mutator", do: send(parent, :mutate_sticky)
        evaluation
      end
    }

    f =
      Featurevisor.create_featurevisor(%{
        datafile: %{
          "schemaVersion" => "2",
          "revision" => "state",
          "segments" => %{},
          "features" => %{},
          "variables" => %{
            "leaf" => variable(),
            "mutator" => variable(),
            "root" =>
              variable([
                requirement("leaf"),
                requirement("mutator"),
                %{"variable" => "leaf", "operator" => "equals", "value" => 2}
              ])
          }
        },
        modules: [module],
        log_level: :fatal
      })

    # The callback runs in the evaluating process. Apply the setter during the
    # second prerequisite's after hook, without using a persistent session.
    mutate = %Featurevisor.Module{
      after_evaluation: fn evaluation, _options ->
        if evaluation.variable_key == "mutator",
          do: Featurevisor.set_sticky_variables(f, %{"leaf" => 2})

        evaluation
      end
    }

    Featurevisor.add_module(f, mutate)
    assert Featurevisor.get_global_variable(f, "root") == 1
    assert_receive :leaf_read
    assert_receive :mutate_sticky
    assert_receive :leaf_read
    refute_receive :leaf_read
    Featurevisor.close(f)
  end

  test "datafile replacement inside a hook invalidates an earlier prerequisite read" do
    root =
      variable([
        requirement("leaf"),
        requirement("mutator"),
        %{"variable" => "leaf", "operator" => "equals", "value" => 2}
      ])

    datafile = %{
      "schemaVersion" => "2",
      "revision" => "first",
      "segments" => %{},
      "features" => %{},
      "variables" => %{"leaf" => variable(), "mutator" => variable(), "root" => root}
    }

    f = Featurevisor.create_featurevisor(%{datafile: datafile, log_level: :fatal})
    parent = self()

    module = %Featurevisor.Module{
      after_evaluation: fn evaluation, _options ->
        if evaluation.variable_key == "leaf", do: send(parent, :leaf_read)

        if evaluation.variable_key == "mutator" do
          next =
            datafile
            |> Map.put("revision", "second")
            |> put_in(["variables", "leaf", "defaultValue"], 2)

          Featurevisor.set_datafile(f, next, true)
        end

        evaluation
      end
    }

    Featurevisor.add_module(f, module)
    assert Featurevisor.get_global_variable(f, "root") == 1
    assert_receive :leaf_read
    assert_receive :leaf_read
    refute_receive :leaf_read
    Featurevisor.close(f)
  end

  test "ordinary nil operands from failing modules are memoised" do
    parent = self()

    module = %Featurevisor.Module{
      before_evaluation: fn options ->
        if options[:variable_key] == "broken" do
          send(parent, :broken_read)
          raise "ordinary module failure"
        end

        options
      end
    }

    f =
      Featurevisor.create_featurevisor(%{
        datafile: %{
          "schemaVersion" => "2",
          "revision" => "errors",
          "segments" => %{},
          "features" => %{},
          "variables" => %{
            "broken" => variable(),
            "root" =>
              variable([
                %{"variable" => "broken", "operator" => "isNull"},
                %{"variable" => "broken", "operator" => "isNull"}
              ])
          }
        },
        modules: [module],
        log_level: :fatal
      })

    assert Featurevisor.get_global_variable(f, "root") == 1
    assert_receive :broken_read
    refute_receive :broken_read
    Featurevisor.close(f)
  end

  test "transformed identities participate in cycle detection" do
    module = %Featurevisor.Module{
      before_evaluation: fn options ->
        if options[:variable_key] in ["root", "alias"],
          do: %{options | variable_key: "actual"},
          else: options
      end
    }

    f =
      Featurevisor.create_featurevisor(%{
        datafile: %{
          "schemaVersion" => "2",
          "revision" => "aliases",
          "segments" => %{},
          "features" => %{},
          "variables" => %{
            "actual" => variable([requirement("alias")]),
            "alias" => variable()
          }
        },
        modules: [module],
        log_level: :fatal
      })

    assert Featurevisor.evaluate_global_variable(f, "root").error.message =~ "Circular"
    Featurevisor.close(f)
  end

  test "a redirected prerequisite may finish before a recursive entry is attempted" do
    datafile = %{
      "schemaVersion" => "2",
      "revision" => "redirect",
      "segments" => %{},
      "features" => %{"a" => feature(["b"]), "b" => feature()},
      "variables" => %{}
    }

    build = fn sticky ->
      module = %Featurevisor.Module{
        before_evaluation: fn options ->
          if options.feature_key == "b" do
            redirected = %{options | feature_key: "a"}

            if sticky,
              do: Map.put(redirected, :sticky_features, %{"a" => %{"enabled" => true}}),
              else: redirected
          else
            options
          end
        end
      }

      Featurevisor.create_featurevisor(%{
        datafile: datafile,
        modules: [module],
        log_level: :fatal
      })
    end

    safe = build.(true)
    recursive = build.(false)
    assert Featurevisor.evaluate_flag(safe, "a").enabled == true
    assert Featurevisor.evaluate_flag(recursive, "a").error.message =~ "Circular"
    Featurevisor.close(safe)
    Featurevisor.close(recursive)
  end

  test "module options omit private session and state plumbing" do
    parent = self()

    module = %Featurevisor.Module{
      before_evaluation: fn options ->
        send(parent, {:options, options})
        Map.new(options)
      end,
      after_evaluation: fn evaluation, options ->
        send(parent, {:options, options})
        evaluation
      end
    }

    f =
      Featurevisor.create_featurevisor(%{
        datafile: %{
          "schemaVersion" => "2",
          "revision" => "private",
          "segments" => %{},
          "features" => %{"a" => feature(["b"]), "b" => feature()},
          "variables" => %{}
        },
        modules: [module],
        log_level: :fatal
      })

    assert Featurevisor.enabled?(f, "a")

    seen =
      for _ <- 1..4,
          do:
            (
              assert_receive {:options, options}
              options
            )

    assert Enum.any?(seen, & &1[:dependency_of])

    Enum.each(seen, fn options ->
      refute Map.has_key?(options, :session)
      refute Map.has_key?(options, :state_source)
      refute Map.has_key?(options, :state_signature)
      refute Map.has_key?(options, :sticky_features_source)
      refute Map.has_key?(options, :sticky_variables_source)
      refute Map.has_key?(options, :required_variables_match)
    end)

    Featurevisor.close(f)
  end

  test "feature before hooks refresh inherited sticky but keep explicit replacement" do
    datafile = %{
      "schemaVersion" => "2",
      "revision" => "sticky-before",
      "segments" => %{},
      "features" => %{"a" => feature()},
      "variables" => %{}
    }

    first = Featurevisor.create_featurevisor(%{datafile: datafile, log_level: :fatal})

    Featurevisor.add_module(first, %Featurevisor.Module{
      before_evaluation: fn options ->
        Featurevisor.set_sticky_features(first, %{"a" => %{"enabled" => false}}, true)
        options
      end
    })

    assert Featurevisor.evaluate_flag(first, "a").enabled == false
    Featurevisor.close(first)

    second = Featurevisor.create_featurevisor(%{datafile: datafile, log_level: :fatal})

    Featurevisor.add_module(second, %Featurevisor.Module{
      before_evaluation: fn options ->
        Featurevisor.set_sticky_features(second, %{"a" => %{"enabled" => false}}, true)
        Map.put(options, :sticky_features, %{"a" => %{"enabled" => true}})
      end
    })

    assert Featurevisor.evaluate_flag(second, "a").enabled == true
    Featurevisor.close(second)
  end

  test "public reentrant callback reads start independent sessions" do
    parent = self()
    {:ok, guard} = Agent.start_link(fn -> false end)

    f =
      Featurevisor.create_featurevisor(%{
        datafile: %{
          "schemaVersion" => "2",
          "revision" => "reentrant",
          "segments" => %{},
          "features" => %{},
          "variables" => %{
            "leaf" => variable(),
            "root" => variable([requirement("leaf"), requirement("leaf")])
          }
        },
        log_level: :fatal
      })

    module = %Featurevisor.Module{
      before_evaluation: fn options ->
        if options[:variable_key] == "root",
          do: send(parent, {:root_marker, options[:dependency_of]})

        if options[:variable_key] == "leaf" do
          send(parent, :leaf_read)
          first = Agent.get_and_update(guard, fn entered -> {not entered, true} end)
          if first, do: assert(Featurevisor.get_global_variable(f, "root") == 1)
        end

        options
      end
    }

    Featurevisor.add_module(f, module)
    assert Featurevisor.get_global_variable(f, "root") == 1
    assert_receive {:root_marker, nil}
    assert_receive {:root_marker, nil}
    assert_receive :leaf_read
    assert_receive :leaf_read
    refute_receive :leaf_read
    Featurevisor.close(f)
    Agent.stop(guard)
  end

  test "nested requirement path errors are not converted into nil operands" do
    f =
      Featurevisor.create_featurevisor(%{
        datafile: %{
          "schemaVersion" => "2",
          "revision" => "path",
          "segments" => %{},
          "features" => %{},
          "variables" => %{
            "source" => %{"type" => "string", "defaultValue" => "abc"},
            "broken" =>
              variable([
                %{"variable" => "source", "path" => "uncompiled", "operator" => "isNull"}
              ]),
            "outer" => variable([%{"variable" => "broken", "operator" => "isNull"}])
          }
        },
        log_level: :fatal
      })

    assert Featurevisor.evaluate_global_variable(f, "outer").reason == :error
    assert Featurevisor.evaluate_global_variable(f, "outer").error.message =~ "path"
    Featurevisor.close(f)
  end

  test "failed reads are not remembered after a hook changes state" do
    f =
      Featurevisor.create_featurevisor(%{
        datafile: %{
          "schemaVersion" => "2",
          "revision" => "failed-state",
          "segments" => %{},
          "features" => %{},
          "variables" => %{
            "leaf" => variable(),
            "root" =>
              variable([
                %{"variable" => "leaf", "operator" => "isNull"},
                %{"variable" => "leaf", "operator" => "isNull"}
              ])
          }
        },
        log_level: :fatal
      })

    parent = self()

    module = %Featurevisor.Module{
      before_evaluation: fn options ->
        if options[:variable_key] == "leaf" do
          send(parent, :failed_read)
          Featurevisor.set_sticky_variables(f, %{"unrelated" => System.unique_integer()})
          raise "ordinary failure"
        end

        options
      end
    }

    Featurevisor.add_module(f, module)
    assert Featurevisor.get_global_variable(f, "root") == 1
    assert_receive :failed_read
    assert_receive :failed_read
    Featurevisor.close(f)
  end

  test "memo keys keep nested object, array and tag shaped contexts distinct" do
    session = Featurevisor.EvaluationSession.new()
    parent = self()
    root = %{type: :variable, variable_key: "root", context: %{}}

    contexts = [
      %{"nested" => %{}},
      %{"nested" => []},
      %{"nested" => %{"array" => []}},
      %{"nested" => ["object", []]}
    ]

    Featurevisor.EvaluationSession.run(session, root, false, fn _ ->
      Enum.each(contexts, fn context ->
        options = %{type: :variable, variable_key: "leaf", context: context}

        Enum.each(1..2, fn _ ->
          result =
            Featurevisor.EvaluationSession.run(session, options, true, fn _ ->
              send(parent, {:read, context})

              %Featurevisor.Evaluation{
                type: :variable,
                variable_key: "leaf",
                reason: :variable_default,
                variable_value: 1
              }
            end)

          assert result.variable_value == 1
        end)
      end)

      :ok
    end)

    assert Enum.sort(
             for _ <- 1..4,
                 do:
                   (
                     assert_receive {:read, context}
                     context
                   )
           ) ==
             Enum.sort(contexts)

    refute_receive {:read, _}
    Featurevisor.EvaluationSession.close(session)
  end

  test "unsupported memo inputs and results are evaluated each time" do
    session = Featurevisor.EvaluationSession.new()
    parent = self()
    root = %{type: :variable, variable_key: "root", context: %{}}

    Featurevisor.EvaluationSession.run(session, root, false, fn _ ->
      Enum.each(
        [%{"host" => {1, 2}}, %{"deep" => Enum.reduce(1..70, [], fn _, acc -> [acc] end)}],
        fn context ->
          options = %{type: :variable, variable_key: "leaf", context: context}

          Enum.each(1..2, fn _ ->
            Featurevisor.EvaluationSession.run(session, options, true, fn _ ->
              send(parent, :read)
              %Featurevisor.Evaluation{type: :variable, variable_value: 1}
            end)
          end)
        end
      )

      options = %{type: :variable, variable_key: "leaf", context: %{"host" => "result"}}

      Enum.each(1..2, fn _ ->
        Featurevisor.EvaluationSession.run(session, options, true, fn _ ->
          send(parent, :read)
          %Featurevisor.Evaluation{type: :variable, variable_value: {1, 2}}
        end)
      end)

      :ok
    end)

    for _ <- 1..6, do: assert_receive(:read)
    refute_receive :read
    Featurevisor.EvaluationSession.close(session)
  end

  test "sticky handoff keys stay bounded and keep owner and child generations" do
    for size <- [0, 100, 1000, 5000],
        kind <- [:features, :variables],
        scope <- [:instance, :child] do
      session = Featurevisor.EvaluationSession.new()
      root = %{type: :variable, variable_key: "root", context: %{}}

      filler =
        if size == 0,
          do: %{},
          else:
            for(index <- 1..size, into: %{}, do: {"unrelated#{index}", %{"nested" => [index]}})

      Process.put(:sticky_owner_generation, 0)
      Process.put(:sticky_child_generation, 0)

      options = %{
        type: :variable,
        variable_key: "leaf",
        context: %{},
        sticky_features: if(kind == :features, do: filler, else: %{}),
        sticky_variables: if(kind == :variables, do: filler, else: %{}),
        sticky_owner: true,
        state_signature: fn -> Process.get(:sticky_owner_generation) end,
        child_signature: fn ->
          if(scope == :child, do: Process.get(:sticky_child_generation), else: nil)
        end
      }

      Featurevisor.EvaluationSession.run(session, root, false, fn _ ->
        read = fn input ->
          Featurevisor.EvaluationSession.run(session, input, true, fn _ ->
            send(self(), :sticky_read)
            %Featurevisor.Evaluation{type: :variable, variable_key: "leaf", variable_value: 1}
          end)
        end

        assert read.(options).variable_value == 1
        assert read.(options).variable_value == 1
        assert_receive :sticky_read
        refute_receive :sticky_read

        Process.put(:sticky_owner_generation, 1)
        assert read.(options).variable_value == 1
        assert_receive :sticky_read

        if scope == :child do
          Process.put(:sticky_child_generation, 1)
          assert read.(options).variable_value == 1
          assert_receive :sticky_read
        end

        assert read.(%{options | context: %{"changed" => true}}).variable_value == 1
        assert_receive :sticky_read
        :ok
      end)

      keys = for {{:memo, key}, _} <- :ets.tab2list(session), do: key
      assert length(keys) == if(scope == :child, do: 4, else: 3)
      assert Enum.all?(keys, &(byte_size(&1) < 512))
      Featurevisor.EvaluationSession.close(session)
    end
  end

  test "explicit replacement maps with equal size and different leaf values stay distinct" do
    session = Featurevisor.EvaluationSession.new()
    root = %{type: :variable, variable_key: "root", context: %{}}

    Featurevisor.EvaluationSession.run(session, root, false, fn _ ->
      for value <- [1, 2, 1] do
        options = %{
          type: :variable,
          variable_key: "leaf",
          context: %{},
          sticky_features: %{"gate" => %{"enabled" => true}},
          sticky_variables: %{"leaf" => value}
        }

        assert Featurevisor.EvaluationSession.run(session, options, true, fn _ ->
                 send(self(), {:replacement_read, value})

                 %Featurevisor.Evaluation{
                   type: :variable,
                   variable_key: "leaf",
                   variable_value: value
                 }
               end).variable_value == value
      end
    end)

    assert_receive {:replacement_read, 1}
    assert_receive {:replacement_read, 2}
    refute_receive {:replacement_read, _}
    Featurevisor.EvaluationSession.close(session)
  end

  test "replacement ownership tokens keep large map keys bounded" do
    session = Featurevisor.EvaluationSession.new()
    root = %{type: :variable, variable_key: "root", context: %{}}
    replacement = for index <- 1..5000, into: %{}, do: {"unrelated#{index}", index}
    first_token = make_ref()
    second_token = make_ref()

    Featurevisor.EvaluationSession.run(session, root, false, fn _ ->
      for {token, value} <- [{first_token, 1}, {first_token, 1}, {second_token, 2}] do
        options = %{
          type: :variable,
          variable_key: "leaf",
          context: %{},
          sticky_owner: true,
          sticky_features: replacement,
          sticky_variables: %{},
          sticky_features_token: token
        }

        assert Featurevisor.EvaluationSession.run(session, options, true, fn _ ->
                 send(self(), {:token_read, value})

                 %Featurevisor.Evaluation{
                   type: :variable,
                   variable_key: "leaf",
                   variable_value: value
                 }
               end).variable_value == value
      end
    end)

    assert_receive {:token_read, 1}
    assert_receive {:token_read, 2}
    refute_receive {:token_read, _}
    keys = for {{:memo, key}, _} <- :ets.tab2list(session), do: key
    assert length(keys) == 2
    assert Enum.all?(keys, &(byte_size(&1) < 512))
    Featurevisor.EvaluationSession.close(session)
  end

  test "request snapshot cache refreshes setters and restores nested and exceptional scopes" do
    f = Featurevisor.create_featurevisor(%{sticky_variables: %{"leaf" => 1}, log_level: :fatal})
    table = f.table

    Featurevisor.Server.with_request_cache(fn ->
      first = Featurevisor.Server.snapshot(table)
      assert first.sticky_variables["leaf"] == 1
      Featurevisor.set_sticky_variables(f, %{"leaf" => 2})
      assert Featurevisor.Server.snapshot(table).sticky_variables["leaf"] == 2

      assert_raise RuntimeError, "nested", fn ->
        Featurevisor.Server.with_request_cache(fn ->
          Featurevisor.set_sticky_variables(f, %{"leaf" => 3})
          assert Featurevisor.Server.snapshot(table).sticky_variables["leaf"] == 3
          raise "nested"
        end)
      end

      assert Featurevisor.Server.snapshot(table).sticky_variables["leaf"] == 3
    end)

    assert Process.get({Featurevisor.Server, :request_cache}) == nil

    child = Featurevisor.spawn(f, %{}, %{sticky_variables: %{"leaf" => 1}})

    initial =
      Agent.get(child.agent, &Map.take(&1, [:generation, :sticky_features, :sticky_variables]))

    assert_raise RuntimeError, "child", fn ->
      Featurevisor.Child.with_request_cache({child.agent, initial}, fn ->
        Featurevisor.Child.set_sticky_variables(child, %{"leaf" => 2})
        raise "child"
      end)
    end

    assert Process.get({Featurevisor.Child, :request_cache}) == nil
    assert Featurevisor.Child.get_global_variable(child, "leaf") == 2
    Featurevisor.Child.close(child)
    Featurevisor.close(f)
  end

  test "large sticky maps preserve repeated prerequisite reuse in parent and child" do
    datafile = %{
      "schemaVersion" => "2",
      "revision" => "sticky-scale",
      "segments" => %{},
      "features" => %{"gate" => feature()},
      "variables" => %{
        "leaf" => variable(),
        "root" =>
          variable([requirement("leaf"), requirement("leaf")])
          |> Map.put("requiredFeatures", ["gate", "gate"])
      }
    }

    parent = self()

    module = %Featurevisor.Module{
      before_evaluation: fn options ->
        if options[:dependency_of],
          do:
            send(
              parent,
              {:sticky_dependency, options.type, options[:feature_key], options[:variable_key]}
            )

        options
      end
    }

    for size <- [0, 100, 1000, 5000],
        kind <- [:features, :variables],
        scope <- [:instance, :child] do
      filler =
        if size == 0,
          do: %{},
          else: for(index <- 1..size, into: %{}, do: {"unrelated#{index}", index})

      features =
        if(kind == :features, do: Map.put(filler, "gate", %{"enabled" => true}), else: %{})

      variables = if(kind == :variables, do: Map.put(filler, "leaf", 1), else: %{})
      sticky = %{sticky_features: features, sticky_variables: variables}

      f =
        Featurevisor.create_featurevisor(
          %{datafile: datafile, modules: [module], log_level: :fatal}
          |> Map.merge(if(scope == :instance, do: sticky, else: %{}))
        )

      child =
        if scope == :child, do: Featurevisor.spawn(f, %{"userId" => "test"}, sticky), else: nil

      getter =
        if child,
          do: fn -> Featurevisor.Child.get_global_variable(child, "root") end,
          else: fn -> Featurevisor.get_global_variable(f, "root", %{"userId" => "test"}) end

      assert getter.() == 1
      assert_receive {:sticky_dependency, :flag, "gate", _}
      assert_receive {:sticky_dependency, :variable, _, "leaf"}
      refute_receive {:sticky_dependency, _, _, _}

      if child, do: Featurevisor.Child.close(child)
      Featurevisor.close(f)
    end
  end
end
