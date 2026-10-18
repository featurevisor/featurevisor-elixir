defmodule Featurevisor.V4RuntimeTest do
  use ExUnit.Case, async: true

  alias Featurevisor.{Conditions, Evaluation, Module, Mutations}

  @v3 Path.expand("../conformance/sdk-v3.json", __DIR__) |> File.read!() |> Jason.decode!()
  @v4 Path.expand("../conformance/sdk-v4-cases.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

  test "executes all portable v4 cases through one persistent instance twice" do
    assert @v4["version"] == 1
    assert length(@v4["cases"]) == 255

    Enum.each(@v4["cases"], fn item ->
      input = Jason.decode!(Jason.encode!(item["datafile"]))
      original = Jason.decode!(Jason.encode!(input))

      instance_options =
        item["options"]
        |> instance_options()
        |> Map.put_new(:log_level, :fatal)
        |> Map.put(:datafile, input)

      f = Featurevisor.create_featurevisor(instance_options)

      for attempt <- 1..2 do
        assert Featurevisor.get_global_variable(f, "subject", item["context"] || %{}) ==
                 item["expected"]["value"],
               "#{item["name"]} getter attempt #{attempt}"

        evaluation =
          Featurevisor.evaluate_global_variable(f, "subject", item["context"] || %{})

        assert evaluation.variable_value == item["expected"]["value"],
               "#{item["name"]} value attempt #{attempt}"

        wire =
          evaluation
          |> Evaluation.to_map()
          |> Map.update("reason", nil, &Atom.to_string/1)

        Enum.each(Map.drop(item["expected"], ["value"]), fn {key, expected} ->
          assert wire[key] == expected, "#{item["name"]} #{key} attempt #{attempt}"
        end)
      end

      assert input == original, "#{item["name"]} input datafile changed"
      Featurevisor.close(f)
    end)
  end

  test "executes canonical grouped feature and variable requirements" do
    Enum.each(@v3["requiredFeatureGroups"], fn group ->
      Enum.with_index(@v3["requiredFeatureGroupInputs"])
      |> Enum.each(fn {input, index} ->
        datafile = %{
          "schemaVersion" => "2",
          "revision" => "groups",
          "segments" => %{},
          "features" => %{
            "a" => %{"bucketBy" => "userId", "traffic" => []},
            "b" => %{"bucketBy" => "userId", "traffic" => []},
            "subject" => %{
              "bucketBy" => "userId",
              "requiredFeatures" => group["requirements"],
              "traffic" => [
                %{"key" => "all", "segments" => "*", "percentage" => 100_000}
              ]
            }
          }
        }

        sticky =
          Map.new(input, fn {key, enabled} -> {key, %{"enabled" => enabled}} end)

        f =
          Featurevisor.create_featurevisor(%{
            datafile: datafile,
            sticky_features: sticky,
            log_level: :fatal
          })

        assert Featurevisor.enabled?(f, "subject") == Enum.at(group["results"], index),
               group["name"]

        Featurevisor.close(f)
      end)
    end)

    Enum.each(@v3["requiredVariables"]["groups"], fn group ->
      Enum.with_index(@v3["requiredVariables"]["groupInputs"])
      |> Enum.each(fn {input, index} ->
        datafile = %{
          "schemaVersion" => "2",
          "revision" => "variable-groups",
          "segments" => %{},
          "features" => %{},
          "variables" => %{
            "a" => %{"type" => "boolean", "defaultValue" => false},
            "b" => %{"type" => "boolean", "defaultValue" => false},
            "subject" => %{
              "type" => "string",
              "defaultValue" => "matched",
              "disabledValue" => "miss",
              "conditions" => variable_requirements(group["requirements"])
            }
          }
        }

        f =
          Featurevisor.create_featurevisor(%{
            datafile: datafile,
            sticky_variables: input,
            log_level: :fatal
          })

        expected = if Enum.at(group["results"], index), do: "matched", else: "miss"
        assert Featurevisor.get_global_variable(f, "subject") == expected, group["name"]
        Featurevisor.close(f)
      end)
    end)
  end

  test "executes canonical sticky requirements and accumulation" do
    contract = @v3["requiredVariables"]

    Enum.each(contract["stickyCases"], fn item ->
      f =
        Featurevisor.create_featurevisor(%{
          datafile: contract["datafile"],
          sticky_features: item["stickyFeatures"],
          sticky_variables: item["stickyVariables"],
          log_level: :fatal
        })

      assert Featurevisor.enabled?(f, "gated") == item["matched"], item["name"]

      assert Featurevisor.get_global_variable(f, "root") ==
               if(item["matched"], do: "matched", else: "default"),
             item["name"]

      assert Featurevisor.get_variable(f, "featureOverride", "message") ==
               if(item["matched"], do: "matched", else: "default"),
             item["name"]

      assert Featurevisor.get_global_variable(f, "accumulated") == item["accumulated"],
             item["name"]

      Featurevisor.close(f)
    end)
  end

  test "preserves numeric equality and ordinary null presence semantics" do
    assert Mutations.apply([1], [%{"op" => "appendUnique", "path" => [], "value" => 1.0}]) == [
             1
           ]

    assert Mutations.apply([true], [%{"op" => "appendUnique", "path" => [], "value" => 1}]) ==
             [true, 1]

    assert Mutations.apply([1.0, 1], [%{"op" => "removeValue", "path" => [], "value" => 1}]) ==
             []

    assert Mutations.apply(
             [%{"id" => 1.0, "value" => "old"}],
             [
               %{
                 "op" => "set",
                 "path" => [
                   %{"select" => %{"property" => "id", "values" => [1]}},
                   "value"
                 ],
                 "value" => "matched"
               }
             ]
           ) == [%{"id" => 1.0, "value" => "matched"}]

    cache = :ets.new(:v4_conditions, [:set, :public])
    report = fn _ -> :ok end

    refute Conditions.all_conditions?(
             %{"attribute" => "missing", "operator" => "isNull"},
             %{},
             cache,
             report
           )

    refute Conditions.all_conditions?(
             %{"attribute" => "missing", "operator" => "notNull"},
             %{},
             cache,
             report
           )

    assert Conditions.all_conditions?(
             %{"attribute" => "present", "operator" => "isNull"},
             %{"present" => nil},
             cache,
             report
           )
  end

  test "required variables share empty and notEmpty condition semantics" do
    cases = [
      {"empty string", "", [], "empty", true},
      {"whitespace", " ", [], "notEmpty", true},
      {"empty array", [], [], "empty", true},
      {"array containing null", [nil], [], "notEmpty", true},
      {"empty object", %{}, [], "empty", true},
      {"object containing null", %{"value" => nil}, [], "notEmpty", true},
      {"nested empty array", %{"nested" => []}, ["nested"], "empty", true},
      {"null is neither", nil, [], "empty", false},
      {"null is not notEmpty", nil, [], "notEmpty", false},
      {"missing is neither", %{}, ["missing"], "empty", false},
      {"missing is not notEmpty", %{}, ["missing"], "notEmpty", false},
      {"number is unsupported", 0, [], "empty", false},
      {"number is not notEmpty", 0, [], "notEmpty", false}
    ]

    Enum.each(cases, fn {name, value, path, operator, matched} ->
      source_type =
        cond do
          is_binary(value) -> "string"
          is_list(value) -> "array"
          is_map(value) -> "object"
          is_number(value) -> "integer"
          true -> "object"
        end

      datafile = %{
        "schemaVersion" => "2",
        "revision" => "empty-requirement",
        "segments" => %{},
        "features" => %{},
        "variables" => %{
          "source" => %{"type" => source_type, "defaultValue" => value},
          "subject" => %{
            "type" => "string",
            "defaultValue" => "matched",
            "disabledValue" => "miss",
            "conditions" => [
              %{
                "variable" => "source",
                "path" => path,
                "operator" => operator
              }
            ]
          }
        }
      }

      f = Featurevisor.create_featurevisor(%{datafile: datafile, log_level: :fatal})
      expected = if(matched, do: "matched", else: "miss")
      assert Featurevisor.get_global_variable(f, "subject") == expected, name
      Featurevisor.close(f)
    end)
  end

  test "accepts safe integral numeric path components and rejects invalid ones" do
    assert Mutations.apply(["zero", "one"], [
             %{"op" => "set", "path" => [1.0], "value" => "changed"}
           ]) == ["zero", "changed"]

    assert Mutations.apply(["zero"], [
             %{"op" => "set", "path" => [9_007_199_254_740_991.0], "value" => "ignored"}
           ]) == ["zero"]

    Enum.each([-1, 1.5, 9_007_199_254_740_992, 9_007_199_254_740_992.0, true], fn part ->
      assert_raise ArgumentError, fn ->
        Mutations.apply(["zero", "one"], [
          %{"op" => "set", "path" => [part], "value" => "invalid"}
        ])
      end
    end)

    datafile = %{
      "schemaVersion" => "2",
      "revision" => "numeric-paths",
      "segments" => %{},
      "features" => %{},
      "variables" => %{
        "source" => %{"type" => "array", "defaultValue" => ["zero", "one"]},
        "mutated" => %{
          "type" => "array",
          "defaultValue" => ["zero", "one"],
          "overrideProgram" => [
            %{
              "key" => "raw",
              "segments" => "*",
              "operations" => [%{"op" => "set", "path" => [1.0], "value" => "changed"}],
              "onMatch" => 1,
              "onMiss" => 1
            }
          ]
        },
        "gate" => %{
          "type" => "string",
          "defaultValue" => "matched",
          "disabledValue" => "miss",
          "conditions" => [
            %{"variable" => "source", "path" => [1.0], "operator" => "equals", "value" => "one"}
          ]
        }
      }
    }

    raw = Jason.encode!(datafile)
    assert raw =~ ~s("path":[1.0])
    f = Featurevisor.create_featurevisor(%{datafile: raw, log_level: :fatal})
    assert Featurevisor.get_global_variable(f, "mutated") == ["zero", "changed"]
    assert Featurevisor.get_global_variable(f, "gate") == "matched"
    Featurevisor.close(f)

    Enum.each([-1, 1.5, 9_007_199_254_740_992, 9_007_199_254_740_992.0, true], fn part ->
      invalid =
        put_in(datafile, ["variables", "gate", "conditions", Access.at(0), "path"], [part])

      f = Featurevisor.create_featurevisor(%{datafile: invalid, log_level: :fatal})
      assert Featurevisor.evaluate_global_variable(f, "gate").reason == :error
      Featurevisor.close(f)
    end)
  end

  test "source getter callback errors become null while comparator errors still abort" do
    parent = self()

    module = %Module{
      name: "throw-source",
      before_evaluation: fn options ->
        if options[:variable_key] == "source" do
          send(parent, :source_called)
          raise "source callback failed"
        end

        options
      end
    }

    datafile = %{
      "schemaVersion" => "2",
      "revision" => "source-error",
      "segments" => %{},
      "features" => %{},
      "variables" => %{
        "source" => %{"type" => "string", "defaultValue" => "value"},
        "subject" => %{
          "type" => "string",
          "defaultValue" => "matched",
          "disabledValue" => "miss",
          "conditions" => [%{"variable" => "source", "operator" => "isNull"}]
        },
        "badComparator" => %{
          "type" => "string",
          "defaultValue" => "wrong",
          "conditions" => [
            %{
              "variable" => "subject",
              "operator" => "semverEquals",
              "value" => "not-semver"
            }
          ]
        }
      }
    }

    f =
      Featurevisor.create_featurevisor(%{
        datafile: datafile,
        modules: [module],
        log_level: :fatal
      })

    assert Featurevisor.get_global_variable(f, "subject") == "matched"
    assert_receive :source_called
    assert Featurevisor.evaluate_global_variable(f, "badComparator").reason == :error
    Featurevisor.close(f)
  end

  test "empty JSON getters remain values and legacy required is ignored" do
    datafile = %{
      "schemaVersion" => "2",
      "revision" => "empty-json",
      "segments" => %{},
      "features" => %{
        "subject" => %{
          "bucketBy" => "userId",
          "required" => ["missing"],
          "traffic" => [%{"key" => "all", "segments" => "*", "percentage" => 100_000}]
        }
      },
      "variables" => %{
        "array" => %{"type" => "json", "defaultValue" => "[]"},
        "object" => %{"type" => "json", "defaultValue" => "{}"}
      }
    }

    f = Featurevisor.create_featurevisor(%{datafile: datafile, log_level: :fatal})
    assert Featurevisor.enabled?(f, "subject")
    assert Featurevisor.get_global_variable(f, "array") == []
    assert Featurevisor.get_global_variable(f, "object") == %{}
    refute Map.has_key?(Map.from_struct(%Module{}), :before)
    refute Map.has_key?(Map.from_struct(%Module{}), :after)
    Featurevisor.close(f)
  end

  test "dependency events traverse mixed feature and variable graphs but honour empty programs" do
    parent = self()

    initial = %{
      "schemaVersion" => "2",
      "revision" => "one",
      "segments" => %{},
      "features" => %{
        "featureRoot" => %{
          "hash" => "feature-root",
          "conditions" => [
            %{"variable" => "source", "operator" => "equals", "value" => true}
          ]
        },
        "owner" => %{
          "hash" => "owner",
          "variablesSchema" => %{
            "message" => %{"type" => "string", "defaultValue" => "default"}
          },
          "traffic" => [
            %{
              "variableOverrides" => %{
                "message" => [
                  %{
                    "conditions" => [
                      %{"variable" => "source", "operator" => "equals", "value" => true}
                    ],
                    "value" => "matched"
                  }
                ]
              }
            }
          ]
        }
      },
      "variables" => %{
        "source" => %{"hash" => "source-one", "type" => "boolean", "defaultValue" => true},
        "programDependent" => %{
          "hash" => "program",
          "type" => "string",
          "defaultValue" => "default",
          "overrideProgram" => [
            %{
              "conditions" => [
                %{"variable" => "source", "operator" => "equals", "value" => true}
              ],
              "operations" => [%{"op" => "set", "path" => [], "value" => "matched"}],
              "onMatch" => 1,
              "onMiss" => 1
            }
          ]
        },
        "emptyProgram" => %{
          "hash" => "empty",
          "type" => "string",
          "defaultValue" => "default",
          "overrideProgram" => [],
          "overrides" => [
            %{
              "conditions" => [
                %{"variable" => "source", "operator" => "equals", "value" => true}
              ],
              "value" => "wrong"
            }
          ]
        },
        "featureDependent" => %{
          "hash" => "feature-dependent",
          "type" => "string",
          "defaultValue" => "default",
          "conditions" => [
            %{
              "feature" => "owner",
              "variable" => "message",
              "operator" => "equals",
              "value" => "matched"
            }
          ]
        }
      }
    }

    f = Featurevisor.create_featurevisor(%{datafile: initial, log_level: :fatal})
    Featurevisor.on(f, :datafile_set, &send(parent, {:datafile_set, &1}))

    updated = %{
      initial
      | "revision" => "two",
        "variables" =>
          Map.put(initial["variables"], "source", %{
            "hash" => "source-two",
            "type" => "boolean",
            "defaultValue" => false
          })
    }

    assert true == Featurevisor.set_datafile(f, updated, true)
    assert_receive {:datafile_set, details}
    assert Enum.sort(details.features) == ["featureRoot", "owner"]
    assert Enum.sort(details.variables) == ["featureDependent", "programDependent", "source"]
    Featurevisor.close(f)
  end

  test "definitions without usable hashes are always reported as changed" do
    parent = self()

    initial = %{
      "schemaVersion" => "2",
      "revision" => "one",
      "segments" => %{},
      "features" => %{
        "missingHash" => %{"bucketBy" => "userId", "traffic" => []},
        "emptyHash" => %{"hash" => "", "bucketBy" => "userId", "traffic" => []}
      },
      "variables" => %{
        "missingHash" => %{"type" => "string", "defaultValue" => "same"},
        "emptyHash" => %{"hash" => "", "type" => "string", "defaultValue" => "same"}
      }
    }

    f = Featurevisor.create_featurevisor(%{datafile: initial, log_level: :fatal})
    Featurevisor.on(f, :datafile_set, &send(parent, {:hashless_datafile_set, &1}))

    assert true == Featurevisor.set_datafile(f, %{initial | "revision" => "two"}, true)
    assert_receive {:hashless_datafile_set, details}
    assert Enum.sort(details.features) == ["emptyHash", "missingHash"]
    assert Enum.sort(details.variables) == ["emptyHash", "missingHash"]
    Featurevisor.close(f)
  end

  test "precomputed and runtime first-match trees stay equivalent through child and datafile state" do
    names = [
      "first match precomputed parsed: child",
      "first match runtime parsed: child"
    ]

    child_value = %{
      "stage" => "parent",
      "rows" => [
        %{"id" => 0, "tags" => []},
        %{"id" => 1, "tags" => ["parent", "child"]}
      ],
      "flags" => ["a"]
    }

    fallback_value = %{"stage" => "fallback", "rows" => [], "flags" => ["a"]}
    sticky_value = %{"stage" => "sticky", "rows" => [], "flags" => [nil]}
    replacement_value = %{"stage" => "replacement", "rows" => [], "flags" => []}

    Enum.each(names, fn name ->
      item = Enum.find(@v4["cases"], &(&1["name"] == name))
      assert item
      datafile = Jason.decode!(Jason.encode!(item["datafile"]))
      original_variables = Jason.encode!(datafile["variables"])

      f =
        Featurevisor.create_featurevisor(%{
          datafile: datafile,
          context: item["context"],
          log_level: :fatal
        })

      child = Featurevisor.spawn(f, %{"country" => "be", "city" => "rotterdam"})
      sticky_child = Featurevisor.spawn(f, %{}, %{sticky_variables: %{"subject" => sticky_value}})

      for _attempt <- 1..2 do
        assert Featurevisor.get_global_variable(f, "subject") == child_value
        assert Featurevisor.evaluate_global_variable(f, "subject").variable_value == child_value
        assert Featurevisor.Child.get_global_variable(child, "subject") == fallback_value
        assert Featurevisor.Child.get_global_variable(sticky_child, "subject") == sticky_value
      end

      assert :ok = Featurevisor.Child.set_sticky_variables(sticky_child, %{}, true)
      assert Featurevisor.Child.get_global_variable(sticky_child, "subject") == child_value

      replacement = %{
        "schemaVersion" => "2",
        "revision" => "replacement",
        "segments" => %{},
        "features" => %{},
        "variables" => %{
          "subject" => %{"type" => "object", "defaultValue" => replacement_value}
        }
      }

      assert true == Featurevisor.set_datafile(f, replacement, true)
      assert Featurevisor.get_global_variable(f, "subject") == replacement_value
      assert Featurevisor.Child.get_global_variable(child, "subject") == replacement_value

      assert true == Featurevisor.set_datafile(f, datafile)
      assert Featurevisor.get_global_variable(f, "subject") == child_value
      assert Featurevisor.Child.get_global_variable(child, "subject") == fallback_value
      assert Jason.encode!(datafile["variables"]) == original_variables

      Featurevisor.Child.close(sticky_child)
      Featurevisor.Child.close(child)
      Featurevisor.close(f)
    end)
  end

  test "accumulation invokes callbacks once and preserves nested metadata" do
    parent = self()

    module = %Module{
      name: "accumulation",
      before_evaluation: fn options ->
        send(parent, {:before, options.variable_key})
        options
      end,
      after_evaluation: fn evaluation, _options ->
        send(parent, {:after, evaluation.variable_override_paths})
        evaluation
      end
    }

    datafile = %{
      "schemaVersion" => "2",
      "revision" => "callbacks",
      "segments" => %{},
      "features" => %{},
      "variables" => %{
        "subject" => %{
          "type" => "object",
          "defaultValue" => %{},
          "overrideProgram" => [
            %{
              "key" => "parent",
              "keyPath" => ["parent"],
              "segments" => "*",
              "operations" => [%{"op" => "set", "path" => ["parent"], "value" => true}],
              "onMatch" => 1,
              "onMiss" => 2
            },
            %{
              "key" => "child",
              "keyPath" => ["parent", "child"],
              "segments" => "*",
              "operations" => [%{"op" => "set", "path" => ["child"], "value" => true}],
              "onMatch" => 2,
              "onMiss" => 2
            }
          ]
        }
      }
    }

    f =
      Featurevisor.create_featurevisor(%{
        datafile: datafile,
        modules: [module],
        log_level: :fatal
      })

    evaluation = Featurevisor.evaluate_global_variable(f, "subject")
    assert evaluation.variable_value == %{"child" => true, "parent" => true}
    assert evaluation.variable_override_paths == [["parent"], ["parent", "child"]]
    assert evaluation.variable_override_key == "child"
    assert_receive {:before, "subject"}
    assert_receive {:after, [["parent"], ["parent", "child"]]}
    refute_receive {:before, "subject"}
    refute_receive {:after, _}
    Featurevisor.close(f)
  end

  test "feature variable overrides evaluate prerequisites before false selectors" do
    parent = self()

    module = %Module{
      name: "prerequisite-order",
      before_evaluation: fn options ->
        if options[:variable_key] == "source", do: send(parent, :source_prerequisite)
        options
      end
    }

    requirement = %{"variable" => "source", "operator" => "equals", "value" => true}
    false_condition = %{"attribute" => "country", "operator" => "equals", "value" => "never"}

    datafile = %{
      "schemaVersion" => "2",
      "revision" => "feature-override-order",
      "segments" => %{},
      "features" => %{
        "owner" => %{
          "bucketBy" => "userId",
          "variablesSchema" => %{
            "ruleValue" => %{"type" => "string", "defaultValue" => "default"},
            "variationValue" => %{"type" => "string", "defaultValue" => "default"}
          },
          "variations" => [
            %{
              "value" => "on",
              "variableOverrides" => %{
                "variationValue" => [
                  %{
                    "key" => "variation",
                    "conditions" => [false_condition, requirement],
                    "value" => "wrong"
                  }
                ]
              }
            }
          ],
          "traffic" => [
            %{
              "key" => "all",
              "segments" => "*",
              "percentage" => 100_000,
              "variation" => "on",
              "variableOverrides" => %{
                "ruleValue" => [
                  %{
                    "key" => "rule",
                    "conditions" => [false_condition, requirement],
                    "value" => "wrong"
                  }
                ]
              }
            }
          ]
        }
      },
      "variables" => %{"source" => %{"type" => "boolean", "defaultValue" => true}}
    }

    f =
      Featurevisor.create_featurevisor(%{
        datafile: datafile,
        modules: [module],
        log_level: :fatal
      })

    assert Featurevisor.get_variable(f, "owner", "ruleValue", %{"country" => "other"}) ==
             "default"

    refute_receive :source_prerequisite

    assert Featurevisor.get_variable(f, "owner", "variationValue", %{"country" => "other"}) ==
             "default"

    refute_receive :source_prerequisite
    Featurevisor.close(f)
  end

  defp instance_options(options) do
    keys = %{
      "context" => :context,
      "logLevel" => :log_level,
      "stickyFeatures" => :sticky_features,
      "stickyVariables" => :sticky_variables
    }

    Map.new(options || %{}, fn {key, value} -> {Map.fetch!(keys, key), value} end)
  end

  defp variable_requirements(value) when is_binary(value),
    do: %{"variable" => value, "operator" => "equals", "value" => true}

  defp variable_requirements(value) when is_list(value),
    do: Enum.map(value, &variable_requirements/1)

  defp variable_requirements(value) when is_map(value) do
    Enum.find_value(["and", "or", "not"], value, fn operator ->
      if Map.has_key?(value, operator),
        do: %{operator => Enum.map(value[operator], &variable_requirements/1)}
    end)
  end
end
