defmodule Featurevisor.NormalizationAndCompositionTest do
  use ExUnit.Case, async: true
  alias Featurevisor.{Child, Module}

  defp datafile(version \\ "4"),
    do: %{
      "schemaVersion" => version,
      "revision" => "one",
      "segments" => %{},
      "features" => %{},
      "variables" => %{}
    }

  defp feature(conditions),
    do: %{
      "bucketBy" => "id",
      "conditions" => conditions,
      "traffic" => [%{"key" => "all", "conditions" => "*", "percentage" => 100_000}]
    }

  defp variable(value), do: %{"type" => "object", "defaultValue" => value}

  test "normalization diagnoses once per entity load, caches before callbacks and retains unrelated caches" do
    for version <- ["2", "4"] do
      parent = self()
      handle = :ets.new(:handle, [:set, :public])

      f =
        Featurevisor.create_featurevisor(%{
          log_level: :error,
          on_diagnostic: fn diagnostic ->
            if diagnostic.code == "conditions_parse_error" do
              [{_, f}] = :ets.lookup(handle, :instance)
              assert Featurevisor.get_revision(f) == "one"
              assert Featurevisor.evaluate_flag(f, "broken").reason == :conditions_unmet
              send(parent, {:parse, diagnostic})
            end
          end
        })

      :ets.insert(handle, {:instance, f})
      input = datafile(version) |> put_in(["features", "broken"], feature("["))
      assert Featurevisor.set_datafile(f, input)
      if version == "4", do: refute_receive({:parse, _})
      assert Featurevisor.evaluate_flag(f, "broken").reason == :conditions_unmet
      assert_receive {:parse, diagnostic}
      assert diagnostic.level == :error
      assert diagnostic.details == %{conditions: "[", entityType: "feature", entityKey: "broken"}
      assert Featurevisor.evaluate_flag(f, "broken").reason == :conditions_unmet
      refute_receive {:parse, _}
      assert Featurevisor.set_datafile(f, datafile("4"))
      Featurevisor.evaluate_flag(f, "broken")
      refute_receive {:parse, _}
      assert Featurevisor.set_datafile(f, input)
      Featurevisor.evaluate_flag(f, "broken")
      assert_receive {:parse, _}
      assert Featurevisor.set_datafile(f, input, true)
      Featurevisor.evaluate_flag(f, "broken")
      assert_receive {:parse, _}
      assert input["features"]["broken"]["conditions"] == "["
      Featurevisor.close(f)
    end
  end

  test "mixed selector arrays have the exact public flattened shape and invalid roots are ordinary wire shapes" do
    expression = %{"attribute" => "country", "operator" => "equals", "value" => "nl"}

    for version <- ["2", "3", "4"] do
      input =
        datafile(version)
        |> put_in(
          ["features", "mixed"],
          Map.merge(feature([expression]), %{
            "segments" => ["unknown"],
            "requiredFeatures" => ["gate"]
          })
        )
        |> put_in(["features", "empty"], Map.put(feature([]), "segments", "*"))
        |> put_in(["features", "broken"], feature("["))
        |> put_in(["variables", "broken"], Map.put(variable("default"), "conditions", "["))

      f = Featurevisor.create_featurevisor(%{datafile: input, log_level: :fatal})

      assert Featurevisor.evaluate_flag(f, "mixed").conditions == [
               expression,
               "unknown",
               %{"feature" => "gate"}
             ]

      assert Featurevisor.evaluate_flag(f, "empty").conditions == [%{"and" => []}, "*"]
      assert Featurevisor.evaluate_flag(f, "broken").conditions == %{"or" => []}
      assert Featurevisor.evaluate_global_variable(f, "broken").conditions == %{"or" => []}
      assert Featurevisor.get_feature(f, "broken")["conditions"] == %{"or" => []}
      Featurevisor.close(f)
    end
  end

  test "a cold lazy read retained across a partial update diagnoses only once for that entity load" do
    alias Featurevisor.{Normalize, Server}
    parent = self()
    input = datafile() |> put_in(["features", "broken"], feature("["))

    report = fn diagnostic ->
      if diagnostic.code == "conditions_parse_error", do: send(parent, :parse)
    end

    f =
      Featurevisor.create_featurevisor(%{
        datafile: input,
        log_level: :error,
        on_diagnostic: report
      })

    Server.with_snapshot(f.table, fn previous ->
      assert Featurevisor.set_datafile(
               f,
               datafile() |> put_in(["variables", "unrelated"], variable(true))
             )

      Normalize.get(previous.datafile, "features", "broken", previous.regex_cache, report)
      assert_receive :parse
      assert Featurevisor.evaluate_flag(f, "broken").reason == :conditions_unmet
      refute_receive :parse
    end)

    assert Featurevisor.set_datafile(f, input)
    assert Featurevisor.evaluate_flag(f, "broken").reason == :conditions_unmet
    assert_receive :parse
    Featurevisor.close(f)
  end

  test "invalid segment aliases cannot be inverted and malformed selectors stay local" do
    for version <- ["2", "4"] do
      input =
        datafile(version)
        |> put_in(["segments", "broken"], %{"conditions" => "["})
        |> put_in(["segments", "alias"], %{"conditions" => "broken"})
        |> put_in(["features", "broken"], feature(%{"not" => ["alias"]}))
        |> put_in(["features", "healthy"], feature("*"))

      f = Featurevisor.create_featurevisor(%{datafile: input, log_level: :fatal})
      assert Featurevisor.evaluate_flag(f, "broken").reason == :conditions_unmet
      assert Featurevisor.enabled?(f, "healthy")
      Featurevisor.close(f)
    end
  end

  test "mixed version partial merges retain eager legacy semantics without per entity provenance" do
    legacy =
      datafile("2")
      |> put_in(["features", "legacy"], %{
        "bucketBy" => "id",
        "force" => [%{"conditions" => [], "enabled" => true}]
      })
      |> put_in(
        ["variables", "legacy"],
        Map.put(variable("legacy"), "overrides", [%{"conditions" => [], "value" => "old"}])
      )

    modern = datafile("4") |> put_in(["features", "modern"], feature([]))
    f = Featurevisor.create_featurevisor(%{datafile: legacy, log_level: :fatal})
    assert Featurevisor.set_datafile(f, modern)
    assert Featurevisor.get_schema_version(f) == "4"
    assert Featurevisor.enabled?(f, "legacy")
    refute Featurevisor.enabled?(f, "modern")
    assert Featurevisor.get_global_variable(f, "legacy") == "old"
    assert Featurevisor.set_datafile(f, datafile("2"))
    refute Featurevisor.enabled?(f, "modern")
    assert Featurevisor.set_datafile(f, modern, true)
    refute Featurevisor.enabled?(f, "legacy")
    assert legacy["features"]["legacy"]["force"] |> hd() |> Map.fetch!("conditions") == []
    Featurevisor.close(f)
  end

  test "removed unreleased requirement selectors are ignored, not retained as evaluation mechanisms" do
    input =
      datafile()
      |> put_in(
        ["features", "subject"],
        Map.merge(feature("*"), %{
          "required" => ["missing"],
          "requiredVariables" => [%{"variable" => "subject", "operator" => "isNull"}]
        })
      )
      |> put_in(
        ["variables", "subject"],
        Map.merge(variable(true), %{
          "requiredVariables" => [%{"variable" => "subject", "operator" => "isNull"}]
        })
      )

    f = Featurevisor.create_featurevisor(%{datafile: input, log_level: :fatal})
    assert Featurevisor.enabled?(f, "subject")
    assert Featurevisor.get_global_variable(f, "subject") == true
    refute Map.has_key?(Featurevisor.get_feature(f, "subject"), "requiredVariables")
    Featurevisor.close(f)
  end

  test "historical empty expressions are limited to released selector sites" do
    for version <- ["2", "4"] do
      input =
        datafile(version)
        |> put_in(["segments", "empty"], %{"conditions" => []})
        |> put_in(["features", "segment"], feature("empty"))
        |> put_in(["features", "root"], feature([]))
        |> put_in(["features", "mixed"], Map.put(feature([]), "segments", "*"))
        |> put_in(["features", "traffic"], %{
          "bucketBy" => "id",
          "traffic" => [%{"conditions" => [], "percentage" => 100_000}]
        })
        |> put_in(
          ["variables", "program"],
          Map.put(variable("default"), "overrideProgram", [
            %{
              "conditions" => [],
              "operations" => [%{"op" => "set", "path" => [], "value" => "wrong"}],
              "onMatch" => 1,
              "onMiss" => 1
            }
          ])
        )

      f = Featurevisor.create_featurevisor(%{datafile: input, log_level: :fatal})
      assert Featurevisor.enabled?(f, "segment") == (version == "2")
      for key <- ["root", "mixed", "traffic"], do: refute(Featurevisor.enabled?(f, key))
      assert Featurevisor.get_global_variable(f, "program") == "default"
      Featurevisor.close(f)
    end
  end

  test "conditions and compositions use separate purpose memo entries and private sessions" do
    parent = self()

    input =
      datafile()
      |> put_in(["variables", "source"], %{"type" => "json", "defaultValue" => "\"null\""})
      |> put_in(["variables", "alias"], %{"type" => "json", "compose" => "source"})
      |> put_in(["variables", "view"], %{
        "type" => "object",
        "conditions" => %{"variable" => "alias", "operator" => "equals", "value" => "null"},
        "compose" => [
          %{"key" => "one", "variable" => "alias"},
          %{"key" => "two", "variable" => "alias"}
        ]
      })

    module = %Module{
      before_evaluation: fn options ->
        refute Map.has_key?(options, :session)
        refute Map.has_key?(options, :__session)

        if options[:dependency_purpose] do
          send(
            parent,
            {:read, options.variable_key, options.dependency_purpose, options.dependency_of}
          )
        else
          refute Map.has_key?(options, :dependency_of)
          refute Map.has_key?(options, :dependency_purpose)
        end

        options
      end
    }

    f = Featurevisor.create_featurevisor(%{datafile: input, modules: [module], log_level: :fatal})

    for _ <- 1..2 do
      assert Featurevisor.get_global_variable(f, "view") == %{"one" => "null", "two" => "null"}
      assert_receive {:read, "alias", :condition, %{type: :variable, variable_key: "view"}}
      assert_receive {:read, "alias", :composition, %{type: :variable, variable_key: "view"}}
      refute_receive {:read, "alias", _, _}

      assert_receive {:read, "source", :composition, %{type: :variable, variable_key: "alias"}}
    end

    Featurevisor.close(f)
  end

  test "composed sources use child context, modules and isolated sticky state without inheriting defaults" do
    source = %{"nested" => %{"limit" => 5}, "list" => ["card"]}

    input =
      datafile()
      |> put_in(["variables", "source"], variable(source))
      |> put_in(["variables", "alias"], %{"type" => "object", "compose" => "source"})
      |> put_in(["variables", "view"], %{
        "type" => "object",
        "compose" => [
          %{"key" => "one", "variable" => "source"},
          %{"key" => "two", "variable" => "source"}
        ],
        "overrideProgram" => [
          %{
            "key" => "edit",
            "conditions" => "*",
            "operations" => [
              %{"op" => "set", "path" => ["one", "nested", "limit"], "value" => 10}
            ],
            "onMatch" => 1,
            "onMiss" => 1
          }
        ]
      })
      |> put_in(["variables", "missing"], %{"type" => "object", "compose" => "absent"})
      |> put_in(["variables", "gated"], %{
        "type" => "object",
        "compose" => "source",
        "conditions" => []
      })

    module = %Module{
      after_evaluation: fn evaluation, options ->
        if options[:variable_key] == "source" and options.context["mode"] == "module",
          do: %{evaluation | variable_value: source |> put_in(["nested", "limit"], 7)},
          else: evaluation
      end
    }

    f = Featurevisor.create_featurevisor(%{datafile: input, log_level: :fatal, modules: [module]})

    child =
      Featurevisor.spawn(f, %{"mode" => "module"}, %{sticky_variables: %{"source" => source}})

    assert Child.get_global_variable(child, "alias")["nested"]["limit"] == 7
    assert Featurevisor.get_global_variable(f, "view")["one"]["nested"]["limit"] == 10
    assert Featurevisor.get_global_variable(f, "view")["two"] == source
    assert Featurevisor.get_global_variable(f, "source") == source

    assert Featurevisor.get_global_variable(f, "missing", %{}, %{default_variable_value: "caller"}) ==
             nil

    assert Featurevisor.get_global_variable(f, "gated", %{}, %{default_variable_value: "caller"}) ==
             nil

    assert Featurevisor.evaluate_global_variable(f, "gated").reason == :conditions_unmet

    assert Child.set_sticky_variables(child, %{"view" => source}, true) == :ok
    assert Child.get_global_variable(child, "view") == source
    assert source["nested"]["limit"] == 5
    Child.close(child)
    Featurevisor.close(f)
  end

  test "closed detailed getters keep ordinary missing reasons and root dependency errors report diagnostics" do
    parent = self()
    input = datafile() |> put_in(["features", "loop"], feature(%{"feature" => "loop"}))

    f =
      Featurevisor.create_featurevisor(%{
        datafile: input,
        log_level: :error,
        on_diagnostic: fn diagnostic -> send(parent, {:diagnostic, diagnostic}) end
      })

    assert Featurevisor.evaluate_flag(f, "loop").reason == :error
    assert_receive {:diagnostic, %{code: "evaluation_error", level: :error}}
    Featurevisor.close(f)
    assert Featurevisor.evaluate_flag(f, "loop").reason == :feature_not_found
    assert Featurevisor.evaluate_global_variable(f, "missing").reason == :variable_not_found
    assert Featurevisor.get_feature(f, "loop") == nil
    assert Featurevisor.get_segment(f, "missing") == nil
  end

  test "composition memo values remain on the request heap and are released on every exit" do
    alias Featurevisor.{Evaluation, EvaluationSession}
    session = EvaluationSession.new()
    root = %{type: :variable, variable_key: "root", context: %{}}
    source = for index <- 1..5000, do: %{"nested" => [index, index + 1]}

    options = %{
      type: :variable,
      variable_key: "source",
      context: %{},
      dependency_purpose: :composition
    }

    EvaluationSession.run(session, root, false, fn _ ->
      for _ <- 1..2 do
        result =
          EvaluationSession.run(session, options, true, fn _ ->
            send(self(), :composed_source_read)
            %Evaluation{type: :variable, variable_value: source}
          end)

        assert result.variable_value == source
      end
    end)

    assert_receive :composed_source_read
    refute_receive :composed_source_read
    assert :ets.info(session, :memory) < 2000
    EvaluationSession.close(session)
    assert Process.get({EvaluationSession, session, :borrowed}) == nil
  end

  test "dependency events propagate raw stringified mixed graphs, additions and removals without warming caches" do
    parent = self()

    input =
      datafile()
      |> put_in(["variables", "source"], Map.put(variable(true), "hash", "source-one"))
      |> put_in(["segments", "leaf"], %{
        "conditions" =>
          Jason.encode!(%{"variable" => "source", "operator" => "equals", "value" => true})
      })
      |> put_in(["segments", "outer"], %{"conditions" => "leaf"})
      |> put_in(["features", "dependent"], Map.put(feature("outer"), "hash", "dependent"))
      |> put_in(["segments", "feature"], %{"conditions" => %{"feature" => "dependent"}})
      |> put_in(["variables", "alias"], %{
        "hash" => "alias",
        "type" => "object",
        "compose" => "source"
      })
      |> put_in(["variables", "view"], %{
        "hash" => "view",
        "type" => "object",
        "conditions" => "feature",
        "compose" => [%{"key" => "source", "variable" => "alias"}]
      })
      |> put_in(["features", "broken"], Map.put(feature("["), "hash", "broken"))

    f =
      Featurevisor.create_featurevisor(%{
        datafile: input,
        log_level: :error,
        on_diagnostic: fn diagnostic ->
          if diagnostic.code == "conditions_parse_error", do: send(parent, :parse)
        end
      })

    Featurevisor.on(f, :datafile_set, &send(parent, {:change, &1}))
    refute_receive :parse

    update =
      datafile()
      |> put_in(["variables", "source"], Map.put(variable(false), "hash", "source-two"))

    assert Featurevisor.set_datafile(f, update)
    assert_receive {:change, details}
    assert "dependent" in details.features
    for key <- ["source", "alias", "view"], do: assert(key in details.variables)
    refute_receive :parse

    removed =
      update
      |> Map.put("features", input["features"])
      |> Map.put("segments", input["segments"])
      |> Map.put("variables", Map.delete(input["variables"], "source"))

    assert Featurevisor.set_datafile(f, removed, true)
    assert_receive {:change, removed_details}
    assert "dependent" in removed_details.features
    for key <- ["source", "alias", "view"], do: assert(key in removed_details.variables)
    assert Featurevisor.set_datafile(f, input, true)
    assert_receive {:change, added_details}
    assert "dependent" in added_details.features
    for key <- ["source", "alias", "view"], do: assert(key in added_details.variables)
    refute_receive :parse
    assert Featurevisor.evaluate_flag(f, "broken").reason == :conditions_unmet
    assert_receive :parse
    Featurevisor.close(f)
  end

  test "mixed segment getter cycles and the combined depth limit fail whole evaluations and clean up" do
    input =
      datafile()
      |> put_in(["segments", "loop"], %{
        "conditions" => %{"variable" => "view", "operator" => "notNull"}
      })
      |> put_in(["variables", "view"], %{
        "type" => "object",
        "compose" => "source",
        "conditions" => %{"not" => ["loop"]}
      })
      |> put_in(["variables", "source"], variable("healthy"))

    f = Featurevisor.create_featurevisor(%{datafile: input, log_level: :fatal})

    for _ <- 1..2 do
      assert Featurevisor.evaluate_global_variable(f, "view").reason == :error
      assert Featurevisor.get_global_variable(f, "source") == "healthy"
    end

    deep =
      Enum.reduce(0..259, input, fn index, input ->
        input
        |> put_in(["segments", "s#{index}"], %{
          "conditions" => %{"variable" => "v#{index}", "operator" => "notNull"}
        })
        |> put_in(
          ["variables", "v#{index}"],
          Map.put(variable(true), "conditions", if(index == 259, do: "*", else: "s#{index + 1}"))
        )
      end)

    assert Featurevisor.set_datafile(f, deep, true)
    assert Featurevisor.evaluate_global_variable(f, "v0").reason == :error
    assert Featurevisor.get_global_variable(f, "source") == "healthy"
    Featurevisor.close(f)
  end
end
