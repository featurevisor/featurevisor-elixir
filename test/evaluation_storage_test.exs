defmodule Featurevisor.EvaluationStorageTest do
  use ExUnit.Case, async: true
  alias Featurevisor.{Conditions, Module, Server, StickyStore}

  defp datafile(value \\ "first") do
    %{
      "schemaVersion" => "2",
      "revision" => value,
      "features" => %{
        "flag" => %{
          "bucketBy" => "userId",
          "requiredFeatures" => [%{"feature" => "dependency", "variation" => value}],
          "traffic" => [%{"key" => "all", "segments" => "*", "percentage" => 100_000}]
        },
        "dependency" => %{
          "bucketBy" => "userId",
          "variations" => [%{"value" => value}],
          "force" => [%{"conditions" => "*", "enabled" => true, "variation" => value}]
        }
      },
      "segments" => %{
        "nl" => %{
          "conditions" =>
            Jason.encode!(%{"attribute" => "country", "operator" => "equals", "value" => "nl"})
        }
      },
      "variables" => %{
        "value" => %{
          "type" => "string",
          "defaultValue" => value,
          "overrides" => [%{"key" => "local", "segments" => "nl", "value" => "local"}]
        }
      }
    }
  end

  defp instance(input \\ datafile()) do
    f = Featurevisor.create_featurevisor(datafile: input, log_level: :fatal)
    on_exit(fn -> Featurevisor.close(f) end)
    f
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    unless fun.() do
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  test "snapshot size does not grow with unrelated project entities" do
    source = datafile()

    features =
      Enum.reduce(1..500, source["features"], fn n, features ->
        Map.put(features, "padding#{n}", %{"unused" => Enum.to_list(1..1000)})
      end)

    f = instance(%{source | "features" => features})
    snap = Server.snapshot(f.table)
    assert :erts_debug.flat_size(snap) < 1000
    assert length(Featurevisor.get_feature_keys(f)) == 502
    assert Featurevisor.get_global_variable_keys(f) == ["value"]
    assert Featurevisor.enabled?(f, "flag")
  end

  test "primary and child sticky handoffs stay bounded while modules receive ordinary maps" do
    sticky = Map.new(1..5_000, &{"padding#{&1}", %{"enabled" => true}})
    sticky = Map.put(sticky, "flag", %{"enabled" => true})
    values = Map.new(1..5_000, &{"padding#{&1}", &1})
    values = Map.put(values, "value", "sticky")

    f =
      Featurevisor.create_featurevisor(%{
        datafile: datafile(),
        sticky_features: sticky,
        sticky_variables: values,
        log_level: :fatal
      })

    on_exit(fn -> Featurevisor.close(f) end)
    child = Featurevisor.spawn(f, %{}, %{sticky_features: sticky, sticky_variables: values})
    on_exit(fn -> Featurevisor.Child.close(child) end)

    assert :erts_debug.flat_size(Server.snapshot(f.table)) < 300

    child_handoff =
      Agent.get(child.agent, &Map.take(&1, [:generation, :sticky_table]))

    assert :erts_debug.flat_size(child_handoff) < 30
    assert Featurevisor.get_global_variable(f, "value") == "sticky"
    assert Featurevisor.Child.get_global_variable(child, "value") == "sticky"
    assert Featurevisor.enabled?(f, "flag")
    assert Featurevisor.Child.enabled?(child, "flag")

    module = %Module{
      before_evaluation: fn options ->
        assert is_map(options.sticky_features)
        refute is_struct(options.sticky_features)
        assert map_size(options.sticky_features) == 5_001
        assert is_map(options.sticky_variables)
        refute is_struct(options.sticky_variables)
        assert map_size(options.sticky_variables) == 5_001
        options
      end
    }

    unsubscribe = Featurevisor.add_module(f, module)
    assert Featurevisor.get_global_variable(f, "value") == "sticky"
    assert Featurevisor.Child.get_global_variable(child, "value") == "sticky"
    assert Featurevisor.enabled?(f, "flag")
    assert Featurevisor.Child.enabled?(child, "flag")
    unsubscribe.()
  end

  test "sticky generations survive replacement and close while a reader is pinned" do
    f =
      Featurevisor.create_featurevisor(%{
        datafile: datafile(),
        sticky_variables: %{"value" => "old"},
        log_level: :fatal
      })

    on_exit(fn -> Featurevisor.close(f) end)
    parent = self()

    reader =
      Task.async(fn ->
        Server.with_snapshot(f.table, fn snap ->
          old = snap.sticky_variables
          send(parent, {:sticky_pinned, old.table})

          receive do
            :continue -> old["value"]
          end
        end)
      end)

    assert_receive {:sticky_pinned, table}
    Featurevisor.set_sticky_variables(f, %{"value" => "new"}, true)
    Featurevisor.close(f)
    assert :ets.info(table) != :undefined
    send(reader.pid, :continue)
    assert Task.await(reader) == "old"
    eventually(fn -> :ets.info(table) == :undefined end)
    refute StickyStore.has_key?(Server.snapshot(f.table).sticky_variables, "value")
  end

  test "an outer snapshot pin protects a retired generation when cache seeding cannot repin" do
    f =
      Featurevisor.create_featurevisor(%{
        datafile: datafile(),
        sticky_variables: %{"value" => "old"},
        log_level: :fatal
      })

    on_exit(fn -> Featurevisor.close(f) end)
    store = :sys.get_state(f.pid).sticky_store

    Server.with_snapshot(f.table, fn snap ->
      Featurevisor.set_sticky_variables(f, %{"value" => "new"}, true)
      :sys.get_state(store)
      refute StickyStore.pin(snap.sticky_table)

      Server.with_request_cache(fn ->
        Server.seed_request_cache(f.table, snap)
        assert snap.sticky_variables["value"] == "old"
        assert Server.snapshot(f.table).sticky_variables["value"] == "new"
      end)
    end)
  end

  test "retired sticky tables reject new pins before reclamation" do
    {:ok, store} = StickyStore.start(self())
    generation = StickyStore.create(store, %{"flag" => %{"enabled" => true}}, %{})
    assert StickyStore.pin(generation)
    assert StickyStore.view(generation, :features)["flag"] == %{"enabled" => true}

    StickyStore.retire(store, generation)
    :sys.get_state(store)
    refute StickyStore.pin(generation)
    send(store, :collect)
    :sys.get_state(store)
    assert :ets.info(generation.table) != :undefined

    StickyStore.unpin(generation)
    eventually(fn -> :ets.info(generation.table) == :undefined end)
    refute StickyStore.pin(generation)
  end

  test "a killed sticky reader releases its fixation and the retired table" do
    {:ok, store} = StickyStore.start(self())
    generation = StickyStore.create(store, %{"flag" => %{"enabled" => true}}, %{})
    parent = self()

    reader =
      spawn(fn ->
        assert StickyStore.pin(generation)
        send(parent, :sticky_reader_pinned)

        receive do
          :never -> :ok
        end
      end)

    assert_receive :sticky_reader_pinned
    StickyStore.retire(store, generation)
    :sys.get_state(store)
    assert :ets.info(generation.table) != :undefined
    Process.exit(reader, :kill)
    eventually(fn -> :ets.info(generation.table) == :undefined end)
  end

  test "primary and child sticky updates reclaim old generations" do
    f = instance()
    child = Featurevisor.spawn(f)
    on_exit(fn -> Featurevisor.Child.close(child) end)

    primary_old =
      for n <- 1..30 do
        table = Server.snapshot(f.table).sticky_table.table
        Featurevisor.set_sticky_variables(f, %{"value" => n}, true)
        table
      end

    child_old =
      for n <- 1..30 do
        table = Agent.get(child.agent, & &1.sticky_table.table)
        Featurevisor.Child.set_sticky_variables(child, %{"value" => n}, true)
        table
      end

    eventually(fn -> Enum.all?(primary_old ++ child_old, &(:ets.info(&1) == :undefined)) end)
    assert Featurevisor.get_global_variable(f, "value") == 30
    assert Featurevisor.Child.get_global_variable(child, "value") == 30
  end

  test "child close retains a pinned sticky generation until its reader exits" do
    f = instance()
    child = Featurevisor.spawn(f, %{}, %{sticky_variables: %{"value" => "child"}})

    snapshot =
      Agent.get(child.agent, fn state ->
        %{generation: state.generation, sticky_table: state.sticky_table}
      end)

    store = Agent.get(child.agent, & &1.sticky_store)
    parent = self()

    reader =
      Task.async(fn ->
        Featurevisor.Child.with_request_cache({child.agent, snapshot}, fn ->
          send(parent, :child_sticky_pinned)

          receive do
            :continue -> StickyStore.view(snapshot.sticky_table, :variables)["value"]
          end
        end)
      end)

    assert_receive :child_sticky_pinned
    Featurevisor.Child.close(child)
    :sys.get_state(store)
    assert :ets.info(snapshot.sticky_table.table) != :undefined
    send(reader.pid, :continue)
    assert Task.await(reader) == "child"
    eventually(fn -> :ets.info(snapshot.sticky_table.table) == :undefined end)
    eventually(fn -> not Process.alive?(store) end)
  end

  test "readers retain their generation across replacement, merge, and close" do
    for action <- [:replace, :merge, :close] do
      f = instance()
      parent = self()

      reader =
        Task.async(fn ->
          Server.with_snapshot(f.table, fn snap ->
            send(parent, {:pinned, snap.regex_cache})

            receive do
              :continue -> get_in(snap.datafile, ["variables", "value", "defaultValue"])
            end
          end)
        end)

      assert_receive {:pinned, old}

      if action == :close,
        do: Featurevisor.close(f),
        else: Featurevisor.set_datafile(f, datafile("next"), action == :replace)

      Process.sleep(150)
      assert :ets.info(old) != :undefined
      send(reader.pid, :continue)
      assert Task.await(reader) == "first"
      eventually(fn -> :ets.info(old) == :undefined end)
    end
  end

  test "dead readers release retired generations automatically" do
    f = instance()
    parent = self()

    reader =
      spawn(fn ->
        Server.with_snapshot(f.table, fn snap ->
          send(parent, {:pinned, snap.regex_cache})

          receive do
            :never -> :ok
          end
        end)
      end)

    assert_receive {:pinned, old}
    Featurevisor.set_datafile(f, datafile("next"), true)
    Process.exit(reader, :kill)
    eventually(fn -> :ets.info(old) == :undefined end)
    assert Featurevisor.get_global_variable(f, "value") == "next"
  end

  test "owner failure cleans up the store and its current generation" do
    f = instance()
    state = :sys.get_state(f.pid)
    store = state.store
    sticky_store = state.sticky_store
    table = Server.snapshot(f.table).regex_cache
    sticky_table = Server.snapshot(f.table).sticky_table.table
    Process.exit(f.pid, :kill)
    eventually(fn -> not Process.alive?(store) end)
    eventually(fn -> not Process.alive?(sticky_store) end)
    assert :ets.info(table) == :undefined
    assert :ets.info(sticky_table) == :undefined
    assert Featurevisor.get_global_variable(f, "value") == nil
  end

  test "an exception releases the caller's generation pin" do
    f = instance()
    table = Server.snapshot(f.table).regex_cache

    assert_raise RuntimeError, fn ->
      Server.with_snapshot(f.table, fn _ -> raise "test failure" end)
    end

    assert :ets.info(table, :safe_fixed) == false
  end

  @tag capture_log: true
  test "store failure terminates its owner instead of leaving a broken instance" do
    f = instance()
    store = :sys.get_state(f.pid).store
    Process.exit(store, :kill)
    eventually(fn -> not Process.alive?(f.pid) end)
    assert Featurevisor.get_global_variable(f, "value") == nil
    refute Featurevisor.enabled?(f, "flag")
  end

  @tag capture_log: true
  test "sticky store failure terminates its owner instead of exposing stale handles" do
    f = instance()
    store = :sys.get_state(f.pid).sticky_store
    Process.exit(store, :kill)
    eventually(fn -> not Process.alive?(f.pid) end)
    assert Featurevisor.get_global_variable(f, "value") == nil
  end

  @tag capture_log: true
  test "child sticky store failure gives closed child fallbacks without affecting its parent" do
    f = instance()

    child =
      Featurevisor.spawn(f, %{"country" => "nl"}, %{sticky_variables: %{"value" => "child"}})

    assert Featurevisor.Child.get_global_variable(child, "value") == "child"
    caller = self()
    Featurevisor.Child.on(child, :datafile_set, fn _ -> send(caller, :delegated_datafile) end)
    assert length(Server.snapshot(f.table).listeners[:datafile_set]) == 1
    store = child.sticky_store
    table = Agent.get(child.agent, & &1.sticky_table.table)

    Process.exit(store, :kill)
    assert Featurevisor.Child.set_sticky_variables(child, %{"value" => "other"}) == :ok
    eventually(fn -> not Process.alive?(child.agent) end)
    eventually(fn -> Server.snapshot(f.table).listeners[:datafile_set] in [nil, []] end)
    assert :ets.info(table) == :undefined
    assert Featurevisor.Child.get_global_variable(child, "value") == "first"
    assert Featurevisor.Child.get_context(child)["country"] == nil
    assert Featurevisor.Child.set_context(child, %{"country" => "de"}) == :ok
    assert Featurevisor.Child.set_sticky_features(child, %{"flag" => %{"enabled" => true}}) == :ok
    assert Featurevisor.Child.set_sticky_variables(child, %{"value" => "other"}) == :ok
    unsubscribe = Featurevisor.Child.on(child, :context_set, fn _ -> :ok end)
    assert unsubscribe.() == :ok
    assert Featurevisor.Child.close(child) == :ok
    assert Featurevisor.get_global_variable(f, "value") == "first"
    Featurevisor.set_datafile(f, datafile("next"), true)
    refute_receive :delegated_datafile
  end

  test "variable requirement comparisons tolerate concurrent cache replacement" do
    source = datafile()

    dependent = %{
      "type" => "string",
      "defaultValue" => "matched",
      "conditions" => [
        %{"variable" => "value", "operator" => "matches", "value" => "^first$"}
      ]
    }

    source = put_in(source, ["variables", "dependent"], dependent)
    f = instance(source)

    readers =
      for _ <- 1..8 do
        Task.async(fn ->
          Enum.each(1..200, fn _ ->
            assert Featurevisor.get_global_variable(f, "dependent") == "matched"
          end)
        end)
      end

    Enum.each(1..30, fn n ->
      Featurevisor.set_datafile(f, %{source | "revision" => "version#{n}"}, true)
    end)

    Enum.each(readers, &Task.await(&1, 10_000))
  end

  test "concurrent dependency reads use complete accepted states and tolerate generation changes" do
    f = instance()

    unsubscribe =
      Featurevisor.add_module(f, %Module{
        before_evaluation: fn options ->
          datafile = options.datafile
          revision = datafile["revision"]

          assert get_in(datafile, ["features", "dependency", "variations", Access.at(0), "value"]) ==
                   revision

          assert get_in(datafile, ["features", "flag", "conditions"]) == [
                   %{"feature" => "dependency", "variation" => revision}
                 ]

          options
        end
      })

    readers =
      for _ <- 1..8 do
        Task.async(fn ->
          Enum.each(1..200, fn _ ->
            evaluation = Featurevisor.evaluate_flag(f, "flag")
            assert evaluation.reason in [:rule, :conditions_unmet]
            assert evaluation.enabled == (evaluation.reason == :rule)
          end)
        end)
      end

    Enum.each(1..30, fn n -> Featurevisor.set_datafile(f, datafile("version#{n}"), true) end)
    Enum.each(readers, &Task.await(&1, 10_000))
    assert Featurevisor.enabled?(f, "flag")
    assert Featurevisor.get_variation(f, "dependency") == "version30"
    unsubscribe.()
    assert Featurevisor.get_global_variable(f, "value") == "version30"
  end

  test "module callback options still contain full maps and keep their starting datafile" do
    f = instance()
    parent = self()

    unsubscribe =
      Featurevisor.add_module(f, %Module{
        before_evaluation: fn options ->
          assert is_map(options.datafile["features"])
          refute is_struct(options.datafile["features"])
          assert Map.keys(options.datafile["features"]) |> Enum.sort() == ["dependency", "flag"]
          refute Map.has_key?(options, :entity_source)
          before = options.datafile

          send(
            parent,
            {:callback_revision, options.feature_key, options.type, before["revision"]}
          )

          Featurevisor.set_datafile(f, datafile("next"), true)
          assert options.datafile == before
          options
        end
      })

    assert Featurevisor.enabled?(f, "flag")
    assert_receive {:callback_revision, "flag", :flag, "first"}
    assert_receive {:callback_revision, "dependency", :flag, "next"}
    assert_receive {:callback_revision, "dependency", :variation, "next"}
    refute_receive {:callback_revision, _, _, _}
    unsubscribe.()
    assert Featurevisor.get_global_variable(f, "value") == "next"
  end

  test "closing callbacks retain selected definitions but prevent later definition reads" do
    for phase <- [:before, :after] do
      f = instance()

      module =
        if phase == :before do
          %Module{
            before_evaluation: fn options ->
              Featurevisor.close(f)
              options
            end
          }
        else
          %Module{
            after_evaluation: fn evaluation, _options ->
              Featurevisor.close(f)
              evaluation
            end
          }
        end

      Featurevisor.add_module(f, module)

      assert Featurevisor.get_global_variable(f, "value") ==
               if(phase == :before, do: nil, else: "first")

      assert Featurevisor.get_global_variable(f, "value") == nil
    end
  end

  test "parsed expressions cache null and false but never context decisions" do
    f = instance()
    table = Server.snapshot(f.table).regex_cache

    for source <- ["null", "false"] do
      expected = Jason.decode!(source)
      assert Conditions.parse_conditions(source, fn _ -> :ok end, table) == expected
      assert :ets.lookup(table, {:expression, source}) == [{{:expression, source}, expected}]
    end

    for _ <- 1..10 do
      assert Featurevisor.get_global_variable(f, "value", %{"country" => "nl"}) == "local"
      assert Featurevisor.get_global_variable(f, "value", %{"country" => "de"}) == "first"
    end

    assert Featurevisor.get_segment(f, "nl")["conditions"]["attribute"] == "country"
  end

  test "parse failures repeat their diagnostics and invalid updates keep the current generation" do
    f = instance()
    table = Server.snapshot(f.table).regex_cache
    parent = self()

    for _ <- 1..2 do
      assert Conditions.parse_conditions("bad JSON", &send(parent, {:diagnostic, &1}), table) ==
               "bad JSON"

      assert_receive {:diagnostic, %{code: "conditions_parse_error"}}
      assert_raise Jason.DecodeError, fn -> Conditions.parse_segments("[", table) end
    end

    assert :ets.lookup(table, {:expression, "bad JSON"}) == []
    Featurevisor.set_datafile(f, "bad JSON", true)
    assert Server.snapshot(f.table).regex_cache == table
    assert Featurevisor.enabled?(f, "flag")
  end

  test "repeated updates reclaim generations and close releases the remaining tables" do
    f = instance()
    state = :sys.get_state(f.pid)
    store = state.store
    sticky_store = state.sticky_store

    old =
      for n <- 1..30 do
        table = Server.snapshot(f.table).regex_cache
        Featurevisor.set_datafile(f, datafile("version#{n}"), true)
        table
      end

    eventually(fn -> Enum.all?(old, &(:ets.info(&1) == :undefined)) end)
    current = Server.snapshot(f.table).regex_cache
    sticky_table = Server.snapshot(f.table).sticky_table.table
    Featurevisor.close(f)
    Featurevisor.close(f)
    eventually(fn -> not Process.alive?(store) end)
    eventually(fn -> not Process.alive?(sticky_store) end)
    assert :ets.info(current) == :undefined
    assert :ets.info(sticky_table) == :undefined
  end
end
