defmodule Featurevisor.PartialSnapshotScalingTest do
  use ExUnit.Case, async: false

  alias Featurevisor.{DatafileStore, Dependencies, Normalize, Server}

  test "partial messages contain only prepared input regardless of retained project size" do
    for version <- ["2", "4"] do
      sizes =
        for size <- [1, 1500] do
          retained = Map.new(1..size, &{"f#{&1}", Map.put(feature(), "hash", "retained")})

          sdk =
            Featurevisor.create_featurevisor(%{
              datafile: %{datafile(version) | "features" => retained},
              log_level: :fatal
            })

          store = :sys.get_state(sdk.pid).store
          server = sdk.pid
          previous = Server.snapshot(sdk.table).regex_cache

          incoming =
            put_in(
              patch(version, 1),
              ["features", "changed"],
              Map.put(
                feature(),
                "conditions",
                "{\"attribute\":\"id\",\"operator\":\"equals\",\"value\":1}"
              )
            )

          {prepared, []} = Normalize.datafile(incoming)
          :erlang.trace(store, true, [:receive, {:tracer, self()}])
          :erlang.trace(server, true, [:receive, {:tracer, self()}])

          try do
            assert Featurevisor.set_datafile(sdk, incoming)

            assert_receive {:trace, ^server, :receive,
                            {:"$gen_call", _, {:set_datafile, ^prepared, false}}}

            assert_receive {:trace, ^store, :receive,
                            {:"$gen_call", _, {:create, ^prepared, ^previous} = request}}

            assert Featurevisor.get_feature(sdk, "changed")["conditions"] == %{
                     "attribute" => "id",
                     "operator" => "equals",
                     "value" => 1
                   }

            assert Featurevisor.set_datafile(sdk, incoming, true)

            assert_receive {:trace, ^store, :receive,
                            {:"$gen_call", _, {:create, ^prepared, nil}}}

            assert Featurevisor.get_feature_keys(sdk) == ["changed"]
            :erts_debug.flat_size(request)
          after
            :erlang.trace(store, false, [:receive])
            :erlang.trace(server, false, [:receive])
            Featurevisor.close(sdk)
          end
        end

      assert Enum.at(sizes, 0) == Enum.at(sizes, 1)
    end
  end

  test "cached partial snapshots write and extract only incoming entities at both retained sizes" do
    Code.ensure_loaded!(DatafileStore)
    Code.ensure_loaded!(Dependencies)
    Code.ensure_loaded!(Server)

    targets = [
      {DatafileStore, :insert_entity, 3},
      {Dependencies, :entity, 2},
      {Server, :dependency_closure, 3}
    ]

    for target <- targets, do: assert(:erlang.trace_pattern(target, true, [:call_count]) == 1)

    try do
      for version <- ["2", "4"], size <- [100, 1500], dependent <- [false, true] do
        # Hashless roots are all announced, but leaves need no graph traversal.
        definition =
          if dependent,
            do:
              Map.put(feature(), "conditions", %{
                "variable" => "value",
                "operator" => "equals",
                "value" => 2
              }),
            else: feature()

        features = Map.new(1..size, &{"f#{&1}", definition})
        sdk = Featurevisor.create_featurevisor(%{log_level: :fatal})

        try do
          assert Featurevisor.set_datafile(sdk, %{datafile(version) | "features" => features})
          assert Featurevisor.set_datafile(sdk, patch(version, 1))
          parent = self()
          Featurevisor.on(sdk, :datafile_set, &send(parent, {:changed, &1}))

          for target <- targets, do: :erlang.trace_pattern(target, true, [:call_count])

          assert Featurevisor.set_datafile(sdk, patch(version, 2))
          assert :erlang.trace_info(Enum.at(targets, 0), :call_count) == {:call_count, 1}
          assert :erlang.trace_info(Enum.at(targets, 1), :call_count) == {:call_count, 1}

          assert :erlang.trace_info(Enum.at(targets, 2), :call_count) ==
                   {:call_count, if(dependent, do: 4, else: 2)}

          assert_receive {:changed, details}
          assert Enum.sort(details.features) == Enum.sort(Map.keys(features))
          assert details.variables == ["value"]

          snapshot = Server.snapshot(sdk.table)
          assert :ets.info(snapshot.regex_cache, :size) == 2
          store = :sys.get_state(sdk.pid).store
          state = :sys.get_state(store)
          assert map_size(state.current) == size + 1
          assert map_size(state.obsolete) <= 1
          send(store, :collect)
          state = :sys.get_state(store)
          assert state.obsolete == %{}
          assert :ets.info(state.entities, :size) == size + 1
          assert Featurevisor.get_global_variable(sdk, "value") == 2
          assert length(Featurevisor.get_feature_keys(sdk)) == size
        after
          Featurevisor.close(sdk)
        end
      end
    after
      for target <- targets, do: :erlang.trace_pattern(target, false, [:call_count])
    end
  end

  test "warm reads stay in the small ETS cache rather than rereading entity versions" do
    sdk =
      Featurevisor.create_featurevisor(%{
        datafile: put_in(patch("4", 7), ["features", "plain"], feature()),
        log_level: :fatal
      })

    on_exit(fn -> Featurevisor.close(sdk) end)
    assert Featurevisor.get_global_variable(sdk, "value") == 7
    assert Featurevisor.enabled?(sdk, "plain", %{"id" => "test"})

    targets = [{DatafileStore, :entity, 3}, {DatafileStore, :materialize, 2}]
    for target <- targets, do: assert(:erlang.trace_pattern(target, true, [:call_count]) == 1)

    try do
      for _ <- 1..50 do
        assert Featurevisor.get_global_variable(sdk, "value") == 7
        assert Featurevisor.enabled?(sdk, "plain", %{"id" => "test"})
      end

      for target <- targets,
          do: assert(:erlang.trace_info(target, :call_count) == {:call_count, 0})
    after
      for target <- targets, do: :erlang.trace_pattern(target, false, [:call_count])
    end
  end

  test "shutdown tasks capture modules rather than the complete owner snapshot" do
    target = {Task, :async, 1}
    assert :erlang.trace_pattern(target, true, [:local]) == 1

    try do
      for size <- [1, 1500] do
        parent = self()
        retained = Map.new(1..size, &{"f#{&1}", feature()})

        sdk =
          Featurevisor.create_featurevisor(%{
            datafile: %{datafile() | "features" => retained},
            log_level: :fatal,
            modules: [%Featurevisor.Module{close: fn -> send(parent, :closed_module) end}]
          })

        server = sdk.pid
        modules = Server.snapshot(sdk.table).modules
        :erlang.trace(server, true, [:call, {:tracer, self()}])
        GenServer.stop(server)
        assert_receive {:trace, ^server, :call, {Task, :async, [callback]}}, 1000
        assert :erlang.fun_info(callback, :env) == {:env, [modules]}
        assert_receive :closed_module
        refute_receive :closed_module
      end
    after
      :erlang.trace_pattern(target, false, [:local])
    end
  end

  test "retained cold slots share diagnostics across many updates and concurrent first reads" do
    parent = self()

    report = fn diagnostic ->
      if diagnostic.code == "conditions_parse_error", do: send(parent, :parse)
    end

    sdk =
      Featurevisor.create_featurevisor(%{
        datafile:
          put_in(datafile(), ["features", "broken"], Map.put(feature(), "conditions", "[")),
        log_level: :error,
        on_diagnostic: report
      })

    on_exit(fn -> Featurevisor.close(sdk) end)

    Server.with_snapshot(sdk.table, fn old ->
      for index <- 1..30, do: assert(Featurevisor.set_datafile(sdk, patch("4", index)))

      current = Server.snapshot(sdk.table)

      assert DatafileStore.entity(old.regex_cache, "features", "broken") ==
               DatafileStore.entity(current.regex_cache, "features", "broken")

      readers =
        for index <- 1..40 do
          Task.async(fn ->
            if rem(index, 2) == 0 do
              old.datafile
              |> Normalize.get("features", "broken", old.regex_cache, report)
              |> Normalize.public()
            else
              Featurevisor.get_feature(sdk, "broken")
            end
          end)
        end

      for value <- Task.await_many(readers, 10_000),
          do: assert(value["conditions"] == %{"or" => []})

      assert_receive :parse
      refute_receive :parse
    end)

    assert Featurevisor.set_datafile(sdk, %{
             datafile()
             | "features" => %{"broken" => Map.put(feature(), "conditions", "[")}
           })

    assert Featurevisor.get_feature(sdk, "broken")["conditions"] == %{"or" => []}
    assert_receive :parse
    refute_receive :parse
  end

  test "replacement boundaries and reclamation retain only versions needed by pinned readers" do
    sdk =
      Featurevisor.create_featurevisor(%{
        datafile: put_in(patch("4", 0), ["features", "old"], feature()),
        log_level: :fatal
      })

    store = :sys.get_state(sdk.pid).store
    %{entities: entities, normalized: normalized} = :sys.get_state(store)

    Server.with_snapshot(sdk.table, fn old ->
      for index <- 1..30 do
        assert Featurevisor.set_datafile(sdk, patch("4", index), rem(index, 5) == 0)
        assert Featurevisor.get_global_variable(sdk, "value") == index
      end

      send(store, :collect)
      :sys.get_state(store)
      assert :ets.info(entities, :size) == 3
      assert Featurevisor.get_feature_keys(sdk) == []
      assert Server.materialize_datafile(old.datafile)["features"] == %{"old" => feature()}

      assert Normalize.get(old.datafile, "variables", "value", old.regex_cache, fn _ -> :ok end)[
               "defaultValue"
             ] == 0
    end)

    send(store, :collect)
    :sys.get_state(store)
    assert :ets.info(entities, :size) == 1
    assert :ets.info(normalized, :size) == 1
    monitor = Process.monitor(store)
    Featurevisor.close(sdk)
    assert_receive {:DOWN, ^monitor, :process, ^store, :normal}, 2000
    assert :ets.info(entities) == :undefined
    assert :ets.info(normalized) == :undefined
  end

  defp feature,
    do: %{
      "bucketBy" => "id",
      "traffic" => [%{"key" => "all", "conditions" => "*", "percentage" => 100_000}]
    }

  defp patch(version, value),
    do:
      put_in(datafile(version), ["variables", "value"], %{
        "hash" => "#{value}",
        "type" => "integer",
        "defaultValue" => value
      })

  defp datafile(version \\ "4"),
    do: %{
      "schemaVersion" => version,
      "revision" => "snapshot",
      "features" => %{},
      "variables" => %{},
      "segments" => %{}
    }
end
