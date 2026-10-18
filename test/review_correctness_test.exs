defmodule Featurevisor.ReviewCorrectnessTest do
  use ExUnit.Case, async: true

  defp feature do
    %{
      "bucketBy" => "id",
      "traffic" => [
        %{"key" => "all", "conditions" => "*", "percentage" => 100_000}
      ]
    }
  end

  test "invalid selector sentinels do not escape in detailed definition metadata" do
    for version <- ["2", "4"] do
      data = %{
        "schemaVersion" => version,
        "revision" => "wire",
        "segments" => %{},
        "features" => %{},
        "variables" => %{
          "broken" => %{
            "type" => "string",
            "defaultValue" => "unused",
            "conditions" => "[",
            "overrides" => [%{"conditions" => "[", "value" => "unused"}]
          }
        }
      }

      f = Featurevisor.create_featurevisor(%{datafile: data, log_level: :fatal})

      try do
        wire =
          f |> Featurevisor.evaluate_global_variable("broken") |> Featurevisor.Evaluation.to_map()

        assert wire["conditions"] == %{"or" => []}
        assert wire["variable"]["conditions"] == %{"or" => []}
        assert hd(wire["variable"]["overrides"])["conditions"] == %{"or" => []}
        refute String.contains?(Jason.encode!(wire), "invalid_conditions")
      after
        Featurevisor.close(f)
      end
    end
  end

  test "nonarray NOT getters are safe and composed null gates ignore explicit defaults" do
    for operand <- [nil, "missing", %{}, false, 1] do
      data = %{
        "schemaVersion" => "4",
        "revision" => "not",
        "segments" => %{"s" => %{"conditions" => %{"not" => operand}}},
        "features" => %{
          "direct" => Map.put(feature(), "conditions", %{"not" => operand}),
          "segment" => Map.put(feature(), "conditions", "s")
        }
      }

      f = Featurevisor.create_featurevisor(%{datafile: data, log_level: :fatal})

      try do
        refute Featurevisor.enabled?(f, "direct")
        refute Featurevisor.enabled?(f, "segment")
      after
        Featurevisor.close(f)
      end
    end

    data = %{
      "schemaVersion" => "4",
      "revision" => "null-gates",
      "features" => %{},
      "segments" => %{},
      "variables" => %{
        "gated" => %{"type" => "string", "compose" => "neverRead", "conditions" => nil},
        "disabled" => %{
          "type" => "string",
          "compose" => "neverRead",
          "conditions" => nil,
          "disabledValue" => "disabled"
        }
      }
    }

    parent = self()

    module = %Featurevisor.Module{
      before_evaluation: fn options ->
        if options[:variable_key] == "neverRead", do: send(parent, :unexpected_gate_source)

        options
        |> Map.put(:default_variable_value, "module default")
        |> Map.put(:default_variable_present, true)
      end
    }

    f = Featurevisor.create_featurevisor(%{datafile: data, modules: [module], log_level: :fatal})

    try do
      assert Featurevisor.get_global_variable(f, "gated", %{}, %{
               default_variable_value: "caller default"
             }) == nil

      assert Featurevisor.get_global_variable(f, "disabled", %{}, %{
               default_variable_value: "caller default"
             }) == "disabled"

      wire =
        f |> Featurevisor.evaluate_global_variable("gated") |> Featurevisor.Evaluation.to_map()

      assert Map.has_key?(wire, "conditions")
      assert wire["conditions"] == nil
      refute_receive :unexpected_gate_source
    after
      Featurevisor.close(f)
    end
  end

  test "feature dependencies observe datafile replacement between repeated reads" do
    for source <- [:flag, :variable] do
      leaf =
        if source == :flag,
          do: %{"feature" => "leaf"},
          else: %{
            "feature" => "leaf",
            "variable" => "value",
            "operator" => "equals",
            "value" => 1
          }

      changed =
        if source == :flag,
          do: %{"feature" => "leaf", "enabled" => false},
          else: Map.put(leaf, "value", 2)

      data = %{
        "schemaVersion" => "4",
        "revision" => "first",
        "segments" => %{},
        "features" => %{
          "leaf" =>
            Map.put(feature(), "variablesSchema", %{
              "value" => %{"type" => "integer", "defaultValue" => 1}
            }),
          "root" =>
            Map.put(feature(), "conditions", [
              leaf,
              %{"variable" => "mutator", "operator" => "equals", "value" => true},
              changed,
              changed
            ])
        },
        "variables" => %{"mutator" => %{"type" => "boolean", "defaultValue" => true}}
      }

      f = Featurevisor.create_featurevisor(%{datafile: data, log_level: :fatal})
      parent = self()

      module = %Featurevisor.Module{
        before_evaluation: fn options ->
          if options[:feature_key] == "leaf", do: send(parent, {:leaf, options[:dependency_of]})
          options
        end,
        after_evaluation: fn evaluation, _options ->
          if evaluation.variable_key == "mutator" do
            next =
              if source == :flag,
                do: put_in(data, ["features", "leaf", "traffic"], []),
                else:
                  put_in(
                    data,
                    ["features", "leaf", "variablesSchema", "value", "defaultValue"],
                    2
                  )

            assert Featurevisor.set_datafile(f, Map.put(next, "revision", "second"), true)
          end

          evaluation
        end
      }

      Featurevisor.add_module(f, module)

      try do
        assert Featurevisor.enabled?(f, "root")
        assert_receive {:leaf, %{type: :flag, feature_key: "root"}}
        assert_receive {:leaf, %{type: :flag, feature_key: "root"}}
        refute_receive {:leaf, _}
        assert Featurevisor.evaluate_flag(f, "root").reason == :conditions_unmet
        assert_receive {:leaf, %{type: :flag, feature_key: "root"}}

        if source == :flag,
          do: assert(Featurevisor.evaluate_flag(f, "leaf").reason == :no_match),
          else: assert(Featurevisor.get_variable(f, "leaf", "value") == 2)

        assert_receive {:leaf, nil}

        assert Featurevisor.set_datafile(f, data, true)
        assert Featurevisor.enabled?(f, "root")
        assert_receive {:leaf, %{type: :flag, feature_key: "root"}}
        assert_receive {:leaf, %{type: :flag, feature_key: "root"}}
        refute_receive {:leaf, _}
      after
        Featurevisor.close(f)
      end
    end
  end

  test "segment depth counts terminal expressions consistently and recovers after failure" do
    for terminal <- [
          "*",
          %{"not" => [nil]},
          %{"attribute" => "country", "operator" => "equals", "value" => "nl"}
        ],
        count <- [255, 256, 257, 258] do
      limit = if is_map(terminal) and Map.has_key?(terminal, "attribute"), do: 257, else: 256

      segments =
        Map.new(0..(count - 1), fn index ->
          {"s#{index}",
           %{"conditions" => if(index == count - 1, do: terminal, else: "s#{index + 1}")}}
        end)

      data = %{
        "schemaVersion" => "4",
        "revision" => "terminal",
        "segments" => segments,
        "features" => %{"subject" => Map.put(feature(), "conditions", "s0"), "safe" => feature()}
      }

      f =
        Featurevisor.create_featurevisor(%{
          datafile: data,
          context: %{"country" => "nl"},
          log_level: :fatal
        })

      try do
        evaluation = Featurevisor.evaluate_flag(f, "subject")
        assert evaluation.reason == if(count > limit, do: :error, else: :rule)
        assert Featurevisor.enabled?(f, "safe")
      after
        Featurevisor.close(f)
      end
    end
  end

  test "getter projection follows callbacks without leaking its private marker or losing metadata" do
    for feature_source <- [false, true] do
      parent = self()

      reference =
        if feature_source,
          do: %{"key" => "one", "feature" => "sourceFeature", "variable" => "source"},
          else: %{"key" => "one", "variable" => "source"}

      schema = %{"type" => "json", "defaultValue" => ~s("null")}

      data = %{
        "schemaVersion" => "4",
        "revision" => "projection",
        "segments" => %{},
        "features" => %{
          "sourceFeature" => Map.put(feature(), "variablesSchema", %{"source" => schema})
        },
        "variables" => %{
          "source" => schema,
          "view" => %{
            "type" => "object",
            "compose" => [reference, Map.put(reference, "key", "two")]
          }
        }
      }

      module = %Featurevisor.Module{
        before_evaluation: fn options ->
          refute Map.has_key?(options, :__getter_value_normalized)
          refute Map.has_key?(options, :session)
          options
        end,
        after_evaluation: fn evaluation, options ->
          refute Map.has_key?(options, :__getter_value_normalized)
          refute Map.has_key?(options, :session)

          refute Map.has_key?(
                   Featurevisor.Evaluation.to_map(evaluation),
                   "__getter_value_normalized"
                 )

          if evaluation.variable_key == "source" do
            assert evaluation.variable_value == ~s("null")
            assert evaluation.reason == :variable_default
            assert (evaluation.variable_schema || evaluation.variable) == schema
            refute evaluation.__getter_value_normalized
            send(parent, :projected_source)
            %{evaluation | variable_value: ~s("123")}
          else
            evaluation
          end
        end
      }

      f =
        Featurevisor.create_featurevisor(%{datafile: data, modules: [module], log_level: :fatal})

      try do
        for detailed <- [false, true] do
          value =
            if detailed do
              evaluation = Featurevisor.evaluate_global_variable(f, "view")
              wire = Featurevisor.Evaluation.to_map(evaluation)
              refute String.contains?(Jason.encode!(wire), "__getter_value_normalized")
              evaluation.variable_value
            else
              Featurevisor.get_global_variable(f, "view")
            end

          assert value == %{"one" => "123", "two" => "123"}
          assert_receive :projected_source
          refute_receive :projected_source
        end
      after
        Featurevisor.close(f)
      end
    end
  end

  test "live sources keep the selected owner, effective context and fresh root recovery" do
    for feature_source <- [false, true] do
      source =
        if feature_source,
          do: %{"feature" => "source", "variable" => "leaf"},
          else: %{"variable" => "leaf"}

      member = fn key -> Map.put(source, "key", key) end

      initial = %{
        "schemaVersion" => "4",
        "revision" => "old",
        "segments" => %{},
        "features" => %{
          "source" =>
            Map.put(feature(), "variablesSchema", %{
              "leaf" => %{"type" => "integer", "defaultValue" => 1}
            })
        },
        "variables" => %{
          "leaf" => %{"type" => "integer", "defaultValue" => 1},
          "mutator" => %{"type" => "boolean", "defaultValue" => true},
          "context" => %{
            "type" => "string",
            "conditions" => [
              %{"attribute" => "country", "operator" => "equals", "value" => "nl"},
              %{"attribute" => "added", "operator" => "notExists"}
            ],
            "defaultValue" => "preserved",
            "disabledValue" => "changed"
          },
          "view" => %{
            "type" => "object",
            "compose" => [
              member.("before"),
              %{"key" => "mutator", "variable" => "mutator"},
              member.("after"),
              member.("again"),
              %{"key" => "context", "variable" => "context"}
            ]
          }
        }
      }

      replacement =
        initial
        |> Map.put("revision", "new")
        |> put_in(["variables", "leaf", "defaultValue"], 2)
        |> put_in(["features", "source", "variablesSchema", "leaf", "defaultValue"], 2)
        |> put_in(["variables", "view", "compose"], [member.("fresh")])

      f =
        Featurevisor.create_featurevisor(%{
          datafile: initial,
          context: %{"country" => "nl"},
          log_level: :fatal
        })

      Featurevisor.add_module(f, %Featurevisor.Module{
        after_evaluation: fn evaluation, _ ->
          if evaluation.variable_key == "mutator" do
            assert Featurevisor.set_datafile(f, replacement, true)
            Featurevisor.set_context(f, %{"country" => "de", "added" => true}, true)
          end

          evaluation
        end
      })

      try do
        assert Featurevisor.get_global_variable(f, "view") == %{
                 "before" => 1,
                 "mutator" => true,
                 "after" => 2,
                 "again" => 2,
                 "context" => "preserved"
               }

        assert Featurevisor.get_global_variable(f, "view") == %{"fresh" => 2}
        assert Featurevisor.get_global_variable(f, "context") == "changed"
      after
        Featurevisor.close(f)
      end
    end
  end

  test "later segments use new definitions while the loaded owner finishes its old rule" do
    initial = %{
      "schemaVersion" => "4",
      "revision" => "old",
      "segments" => %{"s" => %{"conditions" => "*"}},
      "features" => %{
        "subject" =>
          feature()
          |> Map.put("conditions", [
            "s",
            %{"variable" => "mutator", "operator" => "equals", "value" => true},
            %{"not" => ["s"]}
          ])
          |> put_in(["traffic", Access.at(0), "key"], "old")
      },
      "variables" => %{"mutator" => %{"type" => "boolean", "defaultValue" => true}}
    }

    replacement =
      initial
      |> Map.put("revision", "new")
      |> put_in(["segments", "s", "conditions"], [])
      |> put_in(["features", "subject", "conditions"], "*")
      |> put_in(["features", "subject", "traffic", Access.at(0), "key"], "new")

    f = Featurevisor.create_featurevisor(%{datafile: initial, log_level: :fatal})

    Featurevisor.add_module(f, %Featurevisor.Module{
      after_evaluation: fn evaluation, _ ->
        if evaluation.variable_key == "mutator",
          do: assert(Featurevisor.set_datafile(f, replacement, true))

        evaluation
      end
    })

    try do
      first = Featurevisor.evaluate_flag(f, "subject")
      assert first.reason == :rule
      assert first.rule_key == "old"
      assert first.traffic["key"] == "old"
      assert Featurevisor.evaluate_flag(f, "subject").rule_key == "new"
      assert Featurevisor.get_segment(f, "s")["conditions"] == []
    after
      Featurevisor.close(f)
    end
  end

  test "composition keeps exact getter fallbacks without outer defaults" do
    values = %{"zero" => 0, "false" => false, "empty" => "", "json" => ~s("null")}

    variables =
      Map.new(values, fn {key, value} ->
        type =
          %{"zero" => "integer", "false" => "boolean", "empty" => "string", "json" => "json"}[key]

        {key, %{"type" => type, "defaultValue" => value}}
      end)

    entries =
      Enum.map(["zero", "false", "empty", "json", "missing"], &%{"key" => &1, "variable" => &1}) ++
        [
          %{"key" => "disabled", "feature" => "off", "variable" => "value"},
          %{"key" => "flag", "feature" => "off"},
          %{"key" => "variation", "feature" => "off", "variation" => true}
        ]

    data = %{
      "schemaVersion" => "4",
      "revision" => "fallbacks",
      "segments" => %{},
      "features" => %{
        "off" => %{
          "bucketBy" => "id",
          "traffic" => [],
          "disabledVariationValue" => "",
          "variablesSchema" => %{
            "value" => %{
              "type" => "string",
              "defaultValue" => "wrong",
              "disabledValue" => nil,
              "useDefaultWhenDisabled" => true
            }
          }
        }
      },
      "variables" => Map.put(variables, "view", %{"type" => "object", "compose" => entries})
    }

    f = Featurevisor.create_featurevisor(%{datafile: data, log_level: :fatal})

    try do
      for _ <- 1..2 do
        assert Featurevisor.get_global_variable(f, "view", %{}, %{default_variable_value: "outer"}) ==
                 %{
                   "zero" => 0,
                   "false" => false,
                   "empty" => "",
                   "json" => "null",
                   "missing" => nil,
                   "disabled" => nil,
                   "flag" => false,
                   "variation" => ""
                 }
      end
    after
      Featurevisor.close(f)
    end
  end

  test "module driven context state invalidates repeated composed feature source reads" do
    parent = self()

    source =
      feature()
      |> Map.put("variablesSchema", %{"value" => %{"type" => "integer", "defaultValue" => 1}})
      |> put_in(["traffic", Access.at(0), "variableOverrides"], %{
        "value" => [
          %{
            "conditions" => %{"attribute" => "country", "operator" => "equals", "value" => "nl"},
            "value" => 2
          }
        ]
      })

    ref = %{"feature" => "source", "variable" => "value"}

    data = %{
      "schemaVersion" => "4",
      "revision" => "context",
      "segments" => %{},
      "features" => %{"source" => source},
      "variables" => %{
        "mutator" => %{"type" => "boolean", "defaultValue" => true},
        "view" => %{
          "type" => "object",
          "compose" => [
            Map.put(ref, "key", "before"),
            %{"key" => "mutator", "variable" => "mutator"},
            Map.put(ref, "key", "after"),
            Map.put(ref, "key", "again")
          ]
        }
      }
    }

    f =
      Featurevisor.create_featurevisor(%{
        datafile: data,
        context: %{"country" => "us"},
        log_level: :fatal
      })

    module = %Featurevisor.Module{
      before_evaluation: fn options ->
        if options[:feature_key] == "source" do
          send(parent, :source_read)
          Map.put(options, :context, Featurevisor.get_context(f))
        else
          options
        end
      end,
      after_evaluation: fn evaluation, _ ->
        if evaluation.variable_key == "mutator",
          do: Featurevisor.set_context(f, %{"country" => "nl"})

        evaluation
      end
    }

    Featurevisor.add_module(f, module)

    try do
      assert Featurevisor.get_global_variable(f, "view") == %{
               "before" => 1,
               "mutator" => true,
               "after" => 2,
               "again" => 2
             }

      assert_receive :source_read
      assert_receive :source_read
      refute_receive :source_read
    after
      Featurevisor.close(f)
    end
  end
end
