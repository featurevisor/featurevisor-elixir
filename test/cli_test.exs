defmodule Featurevisor.CLITest do
  use ExUnit.Case, async: false
  alias Featurevisor.CLI.{Project, Segments, TestChecks, TestRunner}

  test "datafile cache keys preserve every environment and target selection" do
    names = [
      nil,
      "",
      "false",
      "__no_environment__",
      "prod",
      "prod-target-web",
      "web",
      "web-target-mobile",
      "mobile",
      "Café 東京 🧪\"\\",
      "[null,\"web\"]"
    ]

    selections = for environment <- names, target <- names, do: {environment, target}

    cache =
      Map.new(selections, fn {environment, target} = selection ->
        {Project.datafile_key(environment, target), selection}
      end)

    assert map_size(cache) == length(selections)

    for {environment, target} = selection <- selections do
      assert cache[Project.datafile_key(environment, target)] == selection
    end
  end

  test "validates commands before delegating to Node" do
    assert {:error, "--feature or --variable is required"} =
             Featurevisor.CLI.execute(["benchmark"])

    assert {:error, "--n must be a positive integer"} =
             Featurevisor.CLI.execute(["benchmark", "--feature=foo", "--n=0"])

    assert {:error, "--context must be a JSON object"} =
             Featurevisor.CLI.execute(["benchmark", "--feature=foo", "--context=[]"])

    assert {:error, _} = Featurevisor.CLI.execute(["benchmark", "--feature=foo", "--unknown"])
  end

  test "legacy flags remain accepted and ignored" do
    assert {:error, "--feature or --variable is required"} =
             Featurevisor.CLI.execute([
               "benchmark",
               "--with-scopes",
               "--with-tags",
               "--schemaVersion=1"
             ])

    assert {:error, "--feature or --variable is required"} =
             Featurevisor.CLI.execute(["benchmark", "--schema-version=1"])
  end

  test "shared check fixture executes every case with a fresh native instance" do
    fixture =
      Path.expand("../conformance/test-checks.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

    assert fixture["version"] == 3
    assert length(fixture["cases"]) == 255

    assert Enum.count(
             fixture["cases"],
             &String.contains?(&1["name"], ["includesAny", "IncludesAny"])
           ) == 36

    assert is_map(fixture["datafile"])

    Enum.each(fixture["cases"], fn item ->
      assert is_binary(item["name"])
      assert Map.has_key?(item, "checks")
      assert is_boolean(item["passed"])
      ref = make_ref()

      instance =
        Featurevisor.create_featurevisor(%{
          datafile: fixture["datafile"],
          log_level: :fatal,
          on_diagnostic: TestChecks.diagnostic_handler(self(), ref),
          modules: [TestChecks.diagnostic_module(self(), ref)]
        })

      result =
        try do
          TestChecks.evaluate_result(
            instance,
            fixture["datafile"],
            item["checks"],
            item["owner"],
            ref
          )
        after
          Featurevisor.close(instance)
        end

      preflight_names = [
        "or skips unreached missing feature",
        "and skips unreached missing feature",
        "short circuit skips unresolved ref",
        "AND short circuit"
      ]

      expected_passed = if item["name"] in preflight_names, do: false, else: item["passed"]

      expected_error =
        if item["name"] in preflight_names, do: true, else: Map.get(item, "error", false)

      assert result.passed == expected_passed,
             "#{item["name"]}: #{Enum.join(result.failures, "; ")}"

      assert result.error == expected_error,
             "#{item["name"]}: #{Enum.join(result.failures, "; ")}"
    end)
  end

  test "execution protocol rejects malformed and future envelopes" do
    valid = %{
      "kind" => "featurevisor.test-execution",
      "schemaVersion" => 1,
      "tests" => [%{"scenario" => "checkout"}]
    }

    assert {:ok, [%{"scenario" => "checkout"}]} =
             TestRunner.validate_execution_protocol(valid)

    for invalid <- [
          [],
          %{},
          %{"kind" => nil, "schemaVersion" => 1, "tests" => []},
          %{"kind" => "wrong", "schemaVersion" => 1, "tests" => []},
          %{"kind" => "featurevisor.test-execution", "tests" => []},
          %{"kind" => "featurevisor.test-execution", "schemaVersion" => nil, "tests" => []},
          %{"kind" => "featurevisor.test-execution", "schemaVersion" => "1", "tests" => []},
          %{"kind" => "featurevisor.test-execution", "schemaVersion" => 2, "tests" => []},
          %{"kind" => "featurevisor.test-execution", "schemaVersion" => 1, "tests" => nil},
          %{"kind" => "featurevisor.test-execution", "schemaVersion" => 1, "tests" => [nil]}
        ] do
      assert {:error, _} = TestRunner.validate_execution_protocol(invalid)
    end
  end

  test "preflight validates all references without an evaluator" do
    datafile = %{
      "features" => %{
        "checkout" => %{"variablesSchema" => %{"message" => %{"type" => "string"}}}
      },
      "variables" => %{"message" => %{"type" => "string", "defaultValue" => "ok"}}
    }

    cases = [
      [%{"variable" => "missing", "operator" => "exists"}],
      [%{"feature" => "missing", "enabled" => false}],
      [%{"feature" => "checkout", "variable" => "missing", "operator" => "isNull"}],
      [
        %{
          "variable" => "message",
          "operator" => "equals",
          "compareTo" => %{"variable" => "missing"}
        }
      ],
      [
        %{
          "or" => [
            %{"variable" => "message", "operator" => "equals", "value" => "ok"},
            %{"feature" => "missing", "enabled" => false}
          ]
        }
      ],
      [%{"segment" => "missing", "matches" => false}],
      [%{"not" => [%{"and" => "malformed"}]}]
    ]

    Enum.each(cases, fn checks ->
      result = TestChecks.preflight(datafile, checks, nil, "checks", %{definitions: %{}})
      assert result.error
      refute result.passed
    end)

    assert TestChecks.preflight(
             datafile,
             [%{"variable" => "message", "operator" => "equals", "value" => "ok"}],
             nil
           ).passed
  end

  test "quiet check collection turns malformed JSON getter diagnostics into errors" do
    datafile = %{
      "schemaVersion" => "2",
      "revision" => "bad-json",
      "segments" => %{},
      "features" => %{},
      "variables" => %{"broken" => %{"type" => "json", "defaultValue" => "["}}
    }

    ref = make_ref()

    instance =
      Featurevisor.create_featurevisor(%{
        datafile: datafile,
        log_level: :error,
        on_diagnostic: TestChecks.diagnostic_handler(self(), ref),
        modules: [TestChecks.diagnostic_module(self(), ref)]
      })

    result =
      try do
        TestChecks.evaluate_result(
          instance,
          datafile,
          [%{"variable" => "broken", "operator" => "isNull"}],
          nil,
          ref
        )
      after
        Featurevisor.close(instance)
      end

    refute result.passed
    assert result.error
    assert hd(result.failures) =~ "variable getter reported"
  end

  test "feature checks evaluate both getters and surface native getter diagnostics" do
    parent = self()
    ref = make_ref()

    module = %Featurevisor.Module{
      name: "feature-check-trace",
      before_evaluation: fn options ->
        send(parent, {:feature_check_getter, options.type})
        if options.type == :variation, do: raise("variation exploded"), else: options
      end
    }

    datafile = %{
      "schemaVersion" => "2",
      "revision" => "feature-check-errors",
      "segments" => %{},
      "features" => %{
        "experiment" => %{
          "bucketBy" => "userId",
          "variations" => [%{"value" => "treatment"}],
          "traffic" => []
        }
      }
    }

    instance =
      Featurevisor.create_featurevisor(%{
        datafile: datafile,
        log_level: :error,
        on_diagnostic: TestChecks.diagnostic_handler(self(), ref),
        modules: [module]
      })

    result =
      try do
        TestChecks.evaluate_result(
          instance,
          datafile,
          [%{"feature" => "experiment", "enabled" => true, "variation" => "treatment"}],
          nil,
          ref
        )
      after
        Featurevisor.close(instance)
      end

    assert result.error
    assert hd(result.failures) =~ "variation getter reported evaluation_error"
    assert hd(result.failures) =~ ~s(feature "experiment")
    assert_receive {:feature_check_getter, :flag}
    assert_receive {:feature_check_getter, :variation}

    exception_result =
      TestChecks.evaluate_result(
        %{},
        datafile,
        [%{"feature" => "experiment", "enabled" => true}],
        nil,
        make_ref()
      )

    assert exception_result.error
    assert hd(exception_result.failures) =~ "enabled getter failed"
    assert hd(exception_result.failures) =~ ~s(feature "experiment")

    failure_instance = Featurevisor.create_featurevisor(%{datafile: datafile})

    failure_result =
      try do
        TestChecks.evaluate_result(
          failure_instance,
          datafile,
          [%{"feature" => "experiment", "enabled" => true, "variation" => "control"}],
          nil,
          make_ref()
        )
      after
        Featurevisor.close(failure_instance)
      end

    refute failure_result.passed
    refute failure_result.error
    assert hd(failure_result.failures) =~ ~s(feature "experiment")
    assert hd(failure_result.failures) =~ "expected enabled=true, actual enabled=false"
    assert hd(failure_result.failures) =~ ~s(expected variation="control", actual variation=null)
  end

  test "complete check syntax is validated before native getters run" do
    parent = self()
    ref = make_ref()

    module = %Featurevisor.Module{
      name: "feature-check-no-evaluation",
      before_evaluation: fn options ->
        send(parent, :unexpected_feature_getter)
        options
      end
    }

    datafile = %{
      "schemaVersion" => "2",
      "revision" => "feature-check-validation",
      "segments" => %{},
      "features" => %{"checkout" => %{"bucketBy" => "userId", "traffic" => []}}
    }

    instance = Featurevisor.create_featurevisor(%{datafile: datafile, modules: [module]})

    result =
      try do
        TestChecks.evaluate_result(
          instance,
          datafile,
          [
            %{"feature" => "checkout", "enabled" => false},
            %{"feature" => "checkout", "enabled" => "false"}
          ],
          nil,
          ref
        )
      after
        Featurevisor.close(instance)
      end

    assert result.error
    refute_receive :unexpected_feature_getter
  end

  test "named checks validate sibling keys and preserve failure evidence" do
    datafile = %{
      "schemaVersion" => "2",
      "revision" => "named-checks",
      "segments" => %{},
      "features" => %{},
      "variables" => %{
        "plan" => %{"type" => "string", "defaultValue" => "pro"},
        "settings" => %{"type" => "json", "defaultValue" => %{"nullable" => nil}}
      }
    }

    ref = make_ref()
    instance = Featurevisor.create_featurevisor(%{datafile: datafile, log_level: :fatal})

    try do
      result =
        TestChecks.evaluate_result(
          instance,
          datafile,
          [
            %{
              "key" => "entity checks[1]",
              "description" => "Plan is enterprise",
              "variable" => "plan",
              "operator" => "equals",
              "value" => "free"
            }
          ],
          nil,
          ref
        )

      refute result.passed
      assert hd(result.failures) =~ ~s(key="entity checks[1]")
      assert hd(result.failures) =~ ~s(description="Plan is enterprise")
      assert hd(result.failures) =~ ~s(left="pro")
      failure = hd(result.report_failures)
      assert failure.check_key == "entity checks[1]"
      assert failure.expected == true
      assert failure.actual == false
      assert hd(failure.evaluated)["path"] == [0]
      assert hd(failure.evaluated)["reference"] == %{"variable" => "plan"}
      assert hd(failure.evaluated)["expected"] == "free"
      assert hd(failure.evaluated)["actual"] == "pro"

      nullable =
        TestChecks.evaluate_result(
          instance,
          datafile,
          [%{"variable" => "settings", "path" => "nullable", "operator" => "isNull"}],
          nil,
          ref
        )

      assert nullable.passed

      missing =
        TestChecks.evaluate_result(
          instance,
          datafile,
          [%{"variable" => "settings", "path" => "absent", "operator" => "isNull"}],
          nil,
          ref
        )

      missing_leaf = hd(hd(missing.report_failures).evaluated)
      assert missing_leaf["actualMissing"] == true
      assert missing_leaf["actual"] == %{"$type" => "undefined"}

      duplicate =
        TestChecks.evaluate_result(
          instance,
          datafile,
          [
            %{
              "and" => [
                %{"key" => "same", "variable" => "plan", "operator" => "exists"},
                %{"key" => "same", "variable" => "plan", "operator" => "exists"}
              ]
            }
          ],
          nil,
          ref
        )

      assert duplicate.error
      assert hd(duplicate.failures) =~ "duplicate sibling check key"

      for checks <- [
            [%{"key" => "", "variable" => "plan", "operator" => "exists"}],
            [%{"description" => 1, "variable" => "plan", "operator" => "exists"}]
          ] do
        assert TestChecks.evaluate_result(instance, datafile, checks, nil, ref).error
      end
    after
      Featurevisor.close(instance)
    end
  end

  test "empty check operators validate and compare supported values" do
    datafile = %{
      "schemaVersion" => "2",
      "revision" => "empty-checks",
      "segments" => %{},
      "features" => %{},
      "variables" => %{
        "emptyString" => %{"type" => "string", "defaultValue" => ""},
        "space" => %{"type" => "string", "defaultValue" => " "},
        "emptyArray" => %{"type" => "array", "defaultValue" => []},
        "arrayWithNull" => %{"type" => "array", "defaultValue" => [nil]},
        "emptyObject" => %{"type" => "object", "defaultValue" => %{}},
        "objectWithNull" => %{
          "type" => "object",
          "defaultValue" => %{"value" => nil, "nested" => []}
        },
        "null" => %{"type" => "object", "defaultValue" => nil},
        "number" => %{"type" => "integer", "defaultValue" => 0}
      }
    }

    instance = Featurevisor.create_featurevisor(%{datafile: datafile, log_level: :fatal})
    ref = make_ref()

    try do
      passing = [
        %{"variable" => "emptyString", "operator" => "empty"},
        %{"variable" => "space", "operator" => "notEmpty"},
        %{"variable" => "emptyArray", "operator" => "empty"},
        %{"variable" => "arrayWithNull", "operator" => "notEmpty"},
        %{"variable" => "emptyObject", "operator" => "empty"},
        %{"variable" => "objectWithNull", "operator" => "notEmpty"},
        %{
          "variable" => "objectWithNull",
          "path" => ["nested"],
          "operator" => "empty"
        }
      ]

      assert TestChecks.evaluate_result(instance, datafile, passing, nil, ref).passed

      for check <- [
            %{"variable" => "null", "operator" => "empty"},
            %{"variable" => "null", "operator" => "notEmpty"},
            %{"variable" => "objectWithNull", "path" => ["missing"], "operator" => "empty"},
            %{
              "variable" => "objectWithNull",
              "path" => ["missing"],
              "operator" => "notEmpty"
            }
          ] do
        result = TestChecks.evaluate_result(instance, datafile, [check], nil, ref)
        refute result.passed
        refute result.error
      end

      for checks <- [
            [%{"variable" => "number", "operator" => "empty"}],
            [
              %{
                "or" => [
                  %{"variable" => "number", "operator" => "notEmpty"},
                  %{"variable" => "emptyString", "operator" => "empty"}
                ]
              }
            ],
            [%{"not" => [%{"variable" => "number", "operator" => "empty"}]}]
          ] do
        result = TestChecks.evaluate_result(instance, datafile, checks, nil, ref)
        refute result.passed
        assert result.error
        assert hd(result.failures) =~ "requires a string, array, or object operand"
      end

      for invalid <- [
            %{"variable" => "emptyString", "operator" => "empty", "value" => nil},
            %{
              "variable" => "emptyString",
              "operator" => "notEmpty",
              "compareTo" => %{"variable" => "space"}
            },
            %{"variable" => "emptyString", "operator" => "empty", "regexFlags" => "i"}
          ] do
        result =
          TestChecks.preflight(
            datafile,
            [
              %{
                "or" => [
                  %{"variable" => "emptyString", "operator" => "empty"},
                  invalid
                ]
              }
            ],
            nil
          )

        assert result.error
      end
    after
      Featurevisor.close(instance)
    end
  end

  test "segment checks validate nesting and preserve boolean evidence" do
    datafile = %{
      "schemaVersion" => "2",
      "revision" => "checks",
      "segments" => %{},
      "features" => %{}
    }

    definitions = %{
      "adult" => %{
        "conditions" => %{
          "attribute" => "age",
          "operator" => "greaterThanOrEquals",
          "value" => 18
        }
      },
      "nl" => %{
        "conditions" => %{"attribute" => "country", "operator" => "equals", "value" => "nl"}
      },
      "vip" => %{
        "conditions" => %{"attribute" => "plan", "operator" => "equals", "value" => "vip"}
      }
    }

    {datafile, keys} = Segments.prepare(datafile, definitions)
    context = %{"age" => 21, "country" => "nl", "plan" => "free"}
    instance = Featurevisor.create_featurevisor(%{datafile: datafile, context: context})
    segment_checks = %{keys: keys, definitions: definitions}

    try do
      passing =
        TestChecks.evaluate_result(
          instance,
          datafile,
          [
            %{"segment" => "adult", "matches" => true},
            %{"segment" => "vip", "matches" => false},
            %{
              "and" => [
                %{"segment" => "adult", "matches" => true},
                %{
                  "or" => [
                    %{"segment" => "vip", "matches" => true},
                    %{"not" => [%{"segment" => "nl", "matches" => false}]}
                  ]
                }
              ]
            }
          ],
          nil,
          make_ref(),
          "checks",
          segment_checks
        )

      assert passing.passed

      failing =
        TestChecks.evaluate_result(
          instance,
          datafile,
          [%{"key" => "adult-check", "segment" => "adult", "matches" => false}],
          nil,
          make_ref(),
          "checks",
          segment_checks
        )

      refute failing.passed
      refute failing.error
      assert hd(failing.failures) =~ ~s(segment "adult")
      evidence = hd(hd(failing.report_failures).evaluated)
      assert evidence["reference"] == %{"segment" => "adult"}
      assert evidence["property"] == "matches"
      assert evidence["operator"] == "equals"
      assert evidence["expected"] == false
      assert evidence["actual"] == true

      missing =
        TestChecks.evaluate_result(
          instance,
          datafile,
          [
            %{
              "or" => [
                %{"segment" => "adult", "matches" => true},
                %{"segment" => "missing", "matches" => false}
              ]
            }
          ],
          nil,
          make_ref(),
          "checks",
          segment_checks
        )

      assert missing.error
      assert hd(missing.failures) =~ ~s(Segment "missing")

      for leaf <- [
            %{"segment" => "", "matches" => true},
            %{"segment" => "adult"},
            %{"segment" => "adult", "matches" => "true"},
            %{"matches" => false},
            %{"segment" => "adult", "matches" => true, "feature" => "checkout"},
            %{"segment" => "adult", "matches" => true, "operator" => "equals", "value" => true}
          ] do
        invalid =
          TestChecks.evaluate_result(
            instance,
            datafile,
            [
              %{
                "or" => [
                  %{"segment" => "adult", "matches" => true},
                  leaf
                ]
              }
            ],
            nil,
            make_ref(),
            "checks",
            segment_checks
          )

        assert invalid.error
      end
    after
      Featurevisor.close(instance)
    end
  end

  test "native CLI process runs scenario children and preserves filter and failure exit" do
    directory =
      Path.join(
        System.tmp_dir!(),
        "featurevisor-elixir-cli-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    npx = Path.join(directory, "npx")
    log = Path.join(directory, "calls.log")

    datafile = %{
      "schemaVersion" => "2",
      "revision" => "runner",
      "segments" => %{},
      "features" => %{
        "checkout" => %{
          "bucketBy" => "userId",
          "traffic" => [
            %{"key" => "all", "segments" => "*", "percentage" => 100_000, "enabled" => true}
          ]
        }
      },
      "variables" => %{
        "message" => %{
          "type" => "string",
          "defaultValue" => "parent",
          "overrides" => [
            %{
              "key" => "child",
              "segments" => "*",
              "conditions" => %{"attribute" => "mode", "operator" => "equals", "value" => "child"},
              "value" => "child"
            }
          ]
        }
      }
    }

    passing = [
      %{
        "key" => "scenarios/context.spec",
        "scenario" => "context",
        "_segments" => %{
          "root-context" => %{
            "conditions" => %{
              "attribute" => "custom",
              "operator" => "equals",
              "value" => "literal custom value"
            }
          },
          "merged-child" => %{
            "conditions" => %{
              "and" => [
                %{
                  "attribute" => "custom",
                  "operator" => "equals",
                  "value" => "literal custom value"
                },
                %{"attribute" => "mode", "operator" => "equals", "value" => "child"}
              ]
            }
          }
        },
        "_test" => %{
          "source" => "sets/staging/tests/scenarios/context.spec.yml",
          "set" => "staging",
          "entityType" => "scenario"
        },
        "assertions" => [
          %{
            "description" => "matrix expanded scenario",
            "context" => %{
              "custom" => "literal custom value",
              "checks" => "literal check value"
            },
            "_case" => %{
              "id" => "case-context",
              "assertionIndex" => 0,
              "matrixIndex" => 0,
              "matrixValues" => %{"mode" => "parent"}
            },
            "checks" => [
              %{
                "key" => "parent-message",
                "description" => "Parent message is selected",
                "variable" => "message",
                "operator" => "equals",
                "value" => "parent"
              },
              %{"key" => "checkout-ready", "feature" => "checkout", "enabled" => true},
              %{"key" => "root-segment", "segment" => "root-context", "matches" => true}
            ],
            "children" => [
              %{
                "context" => %{"mode" => "child"},
                "checks" => [
                  %{"variable" => "message", "operator" => "equals", "value" => "child"},
                  %{"segment" => "merged-child", "matches" => true}
                ]
              }
            ]
          }
        ]
      }
    ]

    failing = [
      %{
        "key" => "scenarios/failure.spec",
        "scenario" => "failure",
        "_segments" => %{
          "root-context" => %{
            "conditions" => %{
              "attribute" => "custom",
              "operator" => "equals",
              "value" => "literal custom value"
            }
          }
        },
        "_test" => %{
          "source" => "sets/staging/tests/scenarios/failure.spec.yml",
          "set" => "staging",
          "entityType" => "scenario"
        },
        "assertions" => [
          %{
            "description" => "failing scenario Café 東京 🧪",
            "context" => %{"custom" => "literal custom value", "caption" => "Café 東京 🧪"},
            "_case" => %{
              "id" => "case-failure",
              "assertionIndex" => 0,
              "matrixIndex" => nil,
              "matrixValues" => %{}
            },
            "checks" => [
              %{
                "key" => "wrong-segment",
                "description" => "Reports segment evidence Café 東京 🧪",
                "segment" => "root-context",
                "matches" => false
              }
            ]
          }
        ]
      }
    ]

    malformed = [
      %{
        "key" => "scenarios/hybrid.spec",
        "scenario" => "hybrid",
        "variable" => "message",
        "_test" => %{
          "source" => "sets/staging/tests/scenarios/hybrid.spec.yml",
          "set" => "staging",
          "entityType" => "scenario"
        },
        "assertions" => [
          %{
            "description" => "hybrid",
            "_case" => %{
              "id" => "case-hybrid",
              "assertionIndex" => 0,
              "matrixIndex" => nil,
              "matrixValues" => %{}
            },
            "checks" => [%{"variable" => "message", "operator" => "exists"}]
          }
        ]
      }
    ]

    variable_checks = [
      %{
        "key" => "variables.message.spec",
        "variable" => "message",
        "_segments" => hd(passing)["_segments"],
        "_test" => %{
          "source" => "sets/staging/tests/message.yml",
          "set" => "staging",
          "entityType" => "variable"
        },
        "assertions" => [
          %{
            "target" => "checkout",
            "context" => %{"custom" => "literal custom value"},
            "_case" => %{
              "id" => "case-variable-segments",
              "assertionIndex" => 0,
              "matrixIndex" => nil,
              "matrixValues" => %{}
            },
            "checks" => [%{"segment" => "root-context", "matches" => true}],
            "children" => [
              %{
                "context" => %{"mode" => "child"},
                "checks" => [%{"segment" => "merged-child", "matches" => true}]
              }
            ]
          }
        ]
      }
    ]

    preflight = [
      %{
        "key" => "scenarios/preflight.spec",
        "scenario" => "preflight",
        "_segments" => %{},
        "_test" => %{
          "source" => "sets/staging/tests/scenarios/preflight.spec.yml",
          "set" => "staging",
          "entityType" => "scenario"
        },
        "assertions" => [
          %{
            "description" => "valid root invalid child without target",
            "_case" => %{
              "id" => "preflight-child",
              "assertionIndex" => 0,
              "matrixIndex" => nil,
              "matrixValues" => %{}
            },
            "checks" => [%{"variable" => "message", "operator" => "exists"}],
            "children" => [
              %{"checks" => [%{"feature" => "missing", "enabled" => false}]}
            ]
          },
          %{
            "description" => "malformed children",
            "_case" => %{
              "id" => "preflight-malformed-child",
              "assertionIndex" => 1,
              "matrixIndex" => nil,
              "matrixValues" => %{}
            },
            "checks" => [%{"variable" => "message", "operator" => "exists"}],
            "children" => "malformed"
          },
          %{
            "description" => "skipped branch reference",
            "_case" => %{
              "id" => "preflight-skipped",
              "assertionIndex" => 2,
              "matrixIndex" => nil,
              "matrixValues" => %{}
            },
            "checks" => [
              %{
                "or" => [
                  %{"variable" => "message", "operator" => "exists"},
                  %{"feature" => "missing", "enabled" => false}
                ]
              }
            ]
          }
        ]
      }
    ]

    variable_preflight = [
      %{
        "key" => "message",
        "variable" => "message",
        "_segments" => %{},
        "_test" => %{
          "source" => "sets/staging/tests/message.yml",
          "set" => "staging",
          "entityType" => "variable"
        },
        "assertions" => [
          %{
            "description" => "owner value waits for child preflight",
            "expectedValue" => 5,
            "_case" => %{
              "id" => "preflight-owned-variable",
              "assertionIndex" => 0,
              "matrixIndex" => nil,
              "matrixValues" => %{}
            },
            "children" => [
              %{"checks" => [%{"feature" => "missing", "enabled" => false}]}
            ]
          }
        ]
      }
    ]

    File.write!(
      npx,
      """
      #!/usr/bin/env python3
      import json, os, sys
      with open(os.environ["FAKE_NPX_LOG"], "a", encoding="utf-8") as log:
          log.write(" ".join(sys.argv[1:]) + "\\n")
      args = sys.argv[2:]
      if args == ["config", "--json"]: value = {"environments": False}
      elif args[:2] == ["list", "--targets"]: value = [{"key": "checkout"}]
      elif args[:2] == ["list", "--segments"]: value = []
      elif args[:3] == ["list", "--features", "--without-tests"]: value = [{"key": "unused"}]
      elif args[:3] == ["list", "--variables", "--without-tests"]: value = [{"key": "unusedValue"}]
      elif args[:2] == ["list", "--tests"]:
          if os.environ["FAKE_MODE"] == "protocol": value = []
          else:
              fixture = "FAKE_VARIABLE_PREFLIGHT" if os.environ["FAKE_MODE"] == "variable-preflight" else ("FAKE_VARIABLE" if os.environ["FAKE_MODE"] == "variable" else ("FAKE_PREFLIGHT" if os.environ["FAKE_MODE"] == "preflight" else ("FAKE_PASSING" if os.environ["FAKE_MODE"] == "pass" else ("FAKE_MALFORMED" if os.environ["FAKE_MODE"] == "malformed" else "FAKE_FAILING"))))
              value = {"kind": "featurevisor.test-execution", "schemaVersion": 1, "tests": json.loads(os.environ[fixture])}
      elif args and args[0] == "build": value = json.loads(os.environ["FAKE_DATAFILE"])
      else: raise SystemExit("unexpected arguments: " + repr(args))
      print(json.dumps(value))
      """
    )

    File.chmod!(npx, 0o755)

    base_env = [
      {"MIX_ENV", "test"},
      {"PATH", directory <> ":" <> System.get_env("PATH")},
      {"FAKE_NPX_LOG", log},
      {"FAKE_DATAFILE", Jason.encode!(datafile)},
      {"FAKE_PASSING", Jason.encode!(passing)},
      {"FAKE_FAILING", Jason.encode!(failing)},
      {"FAKE_MALFORMED", Jason.encode!(malformed)},
      {"FAKE_VARIABLE", Jason.encode!(variable_checks)},
      {"FAKE_PREFLIGHT", Jason.encode!(preflight)},
      {"FAKE_VARIABLE_PREFLIGHT", Jason.encode!(variable_preflight)}
    ]

    try do
      {output, status} = run_cli_process(directory, [{"FAKE_MODE", "pass"} | base_env])
      assert status == 0, output
      assert output =~ "Total cases: 1 passed, 0 failed"

      assert File.read!(log) =~ "--entityType=scenario"
      assert File.read!(log) =~ "--set=staging"

      {output, status} =
        run_cli_process(directory, [{"FAKE_MODE", "variable"} | base_env], [], "variable")

      assert status == 0, output
      assert output =~ "Total cases: 1 passed, 0 failed"

      {output, status} =
        run_cli_process(
          directory,
          [{"FAKE_MODE", "variable"} | base_env],
          ["--keyPattern=^message$", "--json"],
          "variable"
        )

      assert status == 0, output
      report = Jason.decode!(output)
      assert get_in(report, ["summary", "specs", "passed"]) == 1
      assert hd(report["results"])["key"] == "message"

      {output, status} = run_cli_process(directory, [{"FAKE_MODE", "fail"} | base_env])
      assert status == 1, output
      assert output =~ "check 1"
      assert output =~ ~s(segment "root-context")
      assert output =~ "wrong-segment"
      assert output =~ " check: "

      assert output =~
               "Rerun (POSIX shell): ./featurevisor test --case=case-failure --projectDirectoryPath=#{directory} --set=staging"

      {output, status} =
        run_cli_process(
          directory,
          [{"FAKE_MODE", "fail"} | base_env],
          ["--json"]
        )

      assert status == 1, output
      failed_report = output |> String.split("\n", trim: true) |> hd() |> Jason.decode!()
      failed_case = get_in(failed_report, ["results", Access.at(0), "cases", Access.at(0)])
      failed_error = get_in(failed_case, ["errors", Access.at(0)])
      assert failed_error["path"] == ["checks", 0]
      assert get_in(failed_error, ["details", "evaluated", Access.at(0), "path"]) == ["checks", 0]
      assert get_in(failed_error, ["details", "checkKey"]) == "wrong-segment"
      evidence = get_in(failed_error, ["details", "evaluated", Access.at(0)])
      assert evidence["reference"] == %{"segment" => "root-context"}
      assert evidence["property"] == "matches"
      assert evidence["operator"] == "equals"
      assert evidence["expected"] == false
      assert evidence["actual"] == true

      {c_locale_output, c_locale_status} =
        run_cli_process(
          directory,
          [{"LC_ALL", "C"}, {"LC_CTYPE", "C"}, {"LANG", "C"}, {"FAKE_MODE", "fail"} | base_env],
          ["--json"]
        )

      assert c_locale_status == 1, c_locale_output

      c_locale_report =
        c_locale_output |> String.split("\n", trim: true) |> hd() |> Jason.decode!()

      assert c_locale_report == failed_report

      assert get_in(c_locale_report, [
               "results",
               Access.at(0),
               "cases",
               Access.at(0),
               "context",
               "caption"
             ]) ==
               "Café 東京 🧪"

      assert c_locale_output =~ "\\u00E9"
      refute c_locale_output =~ "�"

      {human_output, human_status} =
        run_cli_process(
          directory,
          [{"LC_ALL", "C"}, {"LC_CTYPE", "C"}, {"LANG", "C"}, {"FAKE_MODE", "fail"} | base_env]
        )

      assert human_status == 1, human_output
      assert human_output =~ "failing scenario Café 東京 🧪"
      assert human_output =~ "Reports segment evidence Café 東京 🧪"
      refute human_output =~ "�"

      {output, status} = run_cli_process(directory, [{"FAKE_MODE", "malformed"} | base_env])
      assert status == 1, output
      assert output =~ "requires exactly one of feature, variable, segment or scenario"

      File.write!(log, "")

      {output, status} =
        run_cli_process(
          directory,
          [{"FAKE_MODE", "protocol"} | base_env],
          ["--json", "--coverage"]
        )

      assert status == 1, output
      assert output =~ "Invalid test execution protocol envelope"
      refute File.read!(log) =~ "build"

      {output, status} =
        run_cli_process(
          directory,
          [{"FAKE_MODE", "preflight"} | base_env],
          ["--json", "--coverage"]
        )

      assert status == 1, output
      preflight_report = output |> String.split("\n", trim: true) |> hd() |> Jason.decode!()
      assert preflight_report["coverage"]["selections"] == []
      assert get_in(preflight_report, ["summary", "scenarioCases", "failed"]) == 3

      {output, status} =
        run_cli_process(
          directory,
          [{"FAKE_MODE", "variable-preflight"} | base_env],
          ["--json", "--coverage"],
          "variable"
        )

      assert status == 1, output
      variable_report = output |> String.split("\n", trim: true) |> hd() |> Jason.decode!()
      assert variable_report["coverage"]["selections"] == []
      assert get_in(variable_report, ["summary", "entityAssertions", "failed"]) == 1

      {output, status} =
        run_cli_process(
          directory,
          [{"FAKE_MODE", "pass"} | base_env],
          [
            "--case=case-context",
            "--json",
            "--pretty",
            "--coverage",
            "--uncovered"
          ]
        )

      assert status == 0, output
      report = Jason.decode!(output)
      assert report["schemaVersion"] == 1
      assert report["runner"] == "elixir"
      assert report["summary"]["scenarioCases"] == %{"passed" => 1, "failed" => 0}

      assert get_in(report, ["results", Access.at(0), "cases", Access.at(0), "context"]) == %{
               "custom" => "literal custom value",
               "checks" => "literal check value"
             }

      assert get_in(report, ["results", Access.at(0), "cases", Access.at(0), "id"]) ==
               "case-context"

      assert "--projectDirectoryPath=#{directory}" in get_in(report, [
               "results",
               Access.at(0),
               "cases",
               Access.at(0),
               "rerun",
               "args"
             ])

      assert report["uncovered"] == [
               %{"set" => "staging", "features" => ["unused"], "variables" => ["unusedValue"]}
             ]

      assert Enum.any?(report["coverage"]["selections"], fn selection ->
               selection["featureKey"] == "checkout" and selection["ruleKey"] == "all"
             end)

      calls = File.read!(log)
      assert calls =~ "--execution-protocol"
      assert calls =~ "--execution-metadata"
      assert calls =~ "--case=case-context"
    after
      File.rm_rf!(directory)
    end
  end

  defp run_cli_process(project, env, extra_args \\ [], entity_type \\ "scenario") do
    System.cmd(
      "mix",
      [
        "run",
        "--no-compile",
        "--no-deps-check",
        "-e",
        "Featurevisor.CLI.main(System.argv())",
        "--",
        "test",
        "--projectDirectoryPath=#{project}",
        "--set=staging",
        "--entityType=#{entity_type}",
        "--onlyFailures"
        | extra_args
      ],
      cd: Path.expand("..", __DIR__),
      env: env,
      stderr_to_stdout: true
    )
  end
end
