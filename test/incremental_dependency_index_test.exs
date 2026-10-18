defmodule Featurevisor.IncrementalDependencyIndexTest do
  use ExUnit.Case, async: false

  test "identical full merges and replacements reuse edges but still announce hashless entities" do
    target = {Featurevisor.Dependencies, :entity, 2}
    Code.ensure_loaded!(Featurevisor.Dependencies)
    :erlang.trace_pattern(target, true, [:call_count])

    try do
      for replace <- [false, true] do
        :erlang.trace_pattern(target, true, [:call_count])

        source = %{
          datafile()
          | "features" => %{
              "root" => %{"hash" => "same", "conditions" => "gate"},
              "hashless" => %{"conditions" => "*"}
            },
            "segments" => %{"gate" => %{"conditions" => "*"}},
            "variables" => %{
              "source" => %{"hash" => "1", "type" => "integer", "defaultValue" => 1},
              "alias" => %{"hash" => "same", "type" => "integer", "compose" => "source"}
            }
        }

        sdk = Featurevisor.create_featurevisor(%{log_level: :fatal, datafile: source})
        parent = self()
        Featurevisor.on(sdk, :datafile_set, &send(parent, {:change, &1}))

        try do
          for revision <- ["first", "second"] do
            assert Featurevisor.set_datafile(sdk, %{source | "revision" => revision}, replace)
            assert_receive {:change, %{features: ["hashless"], variables: [], replaced: ^replace}}
            assert :erlang.trace_info(target, :call_count) == {:call_count, 5}
          end
        after
          Featurevisor.close(sdk)
        end
      end
    after
      :erlang.trace_pattern(target, false, [:call_count])
    end
  end

  test "full updates refresh same hash edges and replacement removes obsolete owners" do
    for replace <- [false, true] do
      source = %{
        datafile()
        | "features" => %{"root" => %{"hash" => "same", "conditions" => "gate"}},
          "segments" => %{
            "gate" => %{"conditions" => %{"variable" => "source", "operator" => "notNull"}}
          },
          "variables" => %{
            "source" => %{"hash" => "1", "type" => "integer", "defaultValue" => 1},
            "alias" => %{"hash" => "same", "type" => "integer", "compose" => "source"}
          }
      }

      sdk = Featurevisor.create_featurevisor(%{log_level: :fatal, datafile: source})
      parent = self()
      Featurevisor.on(sdk, :datafile_set, &send(parent, {:change, &1}))

      try do
        assert Featurevisor.set_datafile(sdk, source, replace)
        assert_receive {:change, %{features: [], variables: []}}

        changed = %{
          source
          | "segments" => %{"gate" => %{"conditions" => "*"}},
            "variables" => %{
              "source" => source["variables"]["source"],
              "alias" => %{"hash" => "same", "type" => "integer", "compose" => "other"}
            }
        }

        assert Featurevisor.set_datafile(sdk, changed, replace)
        assert_receive {:change, %{features: ["root"], variables: []}}

        patch = %{
          datafile()
          | "variables" => %{
              "source" => %{"hash" => "2", "type" => "integer", "defaultValue" => 2}
            }
        }

        assert Featurevisor.set_datafile(sdk, patch)
        assert_receive {:change, %{features: [], variables: ["source"]}}

        patch = %{
          datafile()
          | "variables" => %{
              "other" => %{"hash" => "3", "type" => "integer", "defaultValue" => 3}
            }
        }

        assert Featurevisor.set_datafile(sdk, patch)
        assert_receive {:change, %{features: [], variables: ["alias", "other"]}}
        assert Featurevisor.set_datafile(sdk, datafile(), true)
        assert_receive {:change, %{features: ["root"], variables: ["alias", "other", "source"]}}
        assert :sys.get_state(sdk.pid).dependency_index == %{reverse: %{}, owners: %{}}
      after
        Featurevisor.close(sdk)
      end
    end
  end

  test "construction is lazy and cached updates only extract incoming entities" do
    target = {Featurevisor.Dependencies, :entity, 2}
    Code.ensure_loaded!(Featurevisor.Dependencies)
    assert :erlang.trace_pattern(target, true, [:call_count]) == 1

    try do
      for size <- [10, 500] do
        :erlang.trace_pattern(target, true, [:call_count])
        datafile = datafile()

        features =
          Map.new(
            1..size,
            &{"f#{&1}",
             %{
               "hash" => "f",
               "conditions" => "{\"variable\":\"source\",\"operator\":\"equals\",\"value\":1}"
             }}
          )

        segments =
          Map.new(
            1..size,
            &{"s#{&1}",
             %{"conditions" => "{\"attribute\":\"id\",\"operator\":\"equals\",\"value\":1}"}}
          )

        sdk =
          Featurevisor.create_featurevisor(%{
            log_level: :fatal,
            datafile: %{datafile | "features" => features, "segments" => segments}
          })

        assert :erlang.trace_info(target, :call_count) == {:call_count, 0}

        for revision <- 1..2 do
          patch = %{
            datafile
            | "revision" => "#{revision}",
              "variables" => %{
                "source" => %{
                  "hash" => "#{revision}",
                  "type" => "integer",
                  "defaultValue" => revision
                }
              }
          }

          assert Featurevisor.set_datafile(sdk, patch)
          expected = 2 * size + revision
          assert :erlang.trace_info(target, :call_count) == {:call_count, expected}
        end

        Featurevisor.close(sdk)
      end
    after
      :erlang.trace_pattern(target, false, [:call_count])
    end
  end

  test "replacement removes owners and the index is never published to readers" do
    sdk =
      Featurevisor.create_featurevisor(%{
        log_level: :fatal,
        datafile: %{
          datafile()
          | "variables" => %{
              "alias" => %{"hash" => "a", "type" => "integer", "compose" => "source"}
            }
        }
      })

    assert Featurevisor.set_datafile(sdk, %{
             datafile()
             | "variables" => %{
                 "source" => %{"hash" => "b", "type" => "integer", "defaultValue" => 2}
               }
           })

    refute Map.has_key?(Featurevisor.Server.snapshot(sdk.table), :dependency_index)
    assert Featurevisor.set_datafile(sdk, datafile(), true)
    assert :sys.get_state(sdk.pid).dependency_index == %{reverse: %{}, owners: %{}}
    Featurevisor.close(sdk)
  end

  test "old then new traversal never follows a new edge back into the old graph" do
    previous = %{
      datafile()
      | "features" => %{
          "bridge" => %{"hash" => "same", "conditions" => "*"},
          "unaffected" => %{"hash" => "same", "conditions" => %{"feature" => "bridge"}}
        }
    }

    incoming = %{
      datafile()
      | "features" => %{
          "bridge" => %{
            "hash" => "same",
            "conditions" => %{"variable" => "source", "operator" => "equals", "value" => 1}
          },
          "unaffected" => %{"hash" => "same", "conditions" => "*"}
        },
        "variables" => %{"source" => %{"hash" => "new", "type" => "integer", "defaultValue" => 1}}
    }

    sdk = Featurevisor.create_featurevisor(%{log_level: :fatal, datafile: previous})
    parent = self()
    Featurevisor.on(sdk, :datafile_set, &send(parent, {:change, &1}))
    assert Featurevisor.set_datafile(sdk, incoming)
    assert_receive {:change, %{features: ["bridge"], variables: ["source"]}}
    Featurevisor.close(sdk)
  end

  test "concurrent writers serialize graph updates and preserve retained normalization slots" do
    parent = self()

    input = %{
      datafile()
      | "features" => %{"broken" => %{"hash" => "broken", "conditions" => "[broken"}},
        "variables" => %{
          "alias" => %{"hash" => "alias", "type" => "integer", "compose" => "source"}
        }
    }

    sdk =
      Featurevisor.create_featurevisor(%{
        log_level: :error,
        datafile: input,
        on_diagnostic: fn diagnostic ->
          if diagnostic.code == "conditions_parse_error", do: send(parent, :parse)
        end
      })

    assert Featurevisor.evaluate_flag(sdk, "broken").reason == :conditions_unmet
    assert_receive :parse

    writers =
      for index <- 1..30 do
        Task.async(fn ->
          patch = %{
            datafile()
            | "revision" => "#{index}",
              "variables" => %{
                "v#{index}" => %{"hash" => "#{index}", "type" => "integer", "compose" => "source"}
              }
          }

          Featurevisor.set_datafile(sdk, patch)
        end)
      end

    assert Enum.all?(Task.await_many(writers, 10_000))
    for index <- 1..30, do: assert("v#{index}" in Featurevisor.get_global_variable_keys(sdk))
    assert Featurevisor.evaluate_flag(sdk, "broken").reason == :conditions_unmet
    refute_receive :parse

    Featurevisor.on(sdk, :datafile_set, &send(parent, {:change, &1}))

    source = %{
      datafile()
      | "variables" => %{
          "source" => %{"hash" => "source", "type" => "integer", "defaultValue" => 7}
        }
    }

    assert Featurevisor.set_datafile(sdk, source)
    assert_receive {:change, details}

    assert Enum.sort(details.variables) ==
             Enum.sort(["source", "alias" | Enum.map(1..30, &"v#{&1}")])

    for key <- details.variables, do: assert(Featurevisor.get_global_variable(sdk, key) == 7)
    refute_receive :parse
    Featurevisor.close(sdk)
  end

  defp datafile do
    %{
      "schemaVersion" => "4",
      "revision" => "test",
      "features" => %{},
      "variables" => %{},
      "segments" => %{}
    }
  end
end
