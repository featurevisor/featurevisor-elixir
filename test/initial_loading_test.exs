defmodule Featurevisor.InitialLoadingTest do
  use ExUnit.Case, async: false

  defp datafile do
    %{
      "schemaVersion" => "4",
      "revision" => "one",
      "features" => %{},
      "variables" => %{},
      "segments" => %{}
    }
  end

  defp variable(hash, source) do
    %{"hash" => hash, "type" => "integer", "compose" => source}
  end

  defp feature(hash, conditions) do
    %{
      "hash" => hash,
      "bucketBy" => "id",
      "conditions" => conditions,
      "traffic" => [%{"key" => "all", "conditions" => "*", "percentage" => 100_000}]
    }
  end

  defp trace_dependencies(f) do
    Code.ensure_loaded!(Featurevisor.Dependencies)
    :erlang.trace_pattern({Featurevisor.Dependencies, :entity, 2}, true, [])
    :erlang.trace(f.pid, true, [:call])

    on_exit(fn ->
      :erlang.trace_pattern({Featurevisor.Dependencies, :entity, 2}, false, [])
      Featurevisor.close(f)
    end)
  end

  defp flush_trace(f) do
    ref = :erlang.trace_delivered(f.pid)
    assert_receive {:trace_delivered, _, ^ref}
  end

  for replace <- [false, true] do
    @replace replace
    test "initial load skips dependency indexing then partial updates retain current dependencies replace=#{replace}" do
      parent = self()

      f =
        Featurevisor.create_featurevisor(%{
          on_diagnostic: fn diagnostic -> send(parent, {:diagnostic, diagnostic}) end
        })

      trace_dependencies(f)
      Featurevisor.on(f, :datafile_set, fn details -> send(parent, {:set, details}) end)

      initial = %{
        datafile()
        | "features" => %{
            "watcher" =>
              feature("watcher", ~s({"variable":"final","operator":"equals","value":3}))
          },
          "variables" => %{
            "source" => %{"hash" => "one", "type" => "integer", "defaultValue" => 1},
            "middle" => variable("middle", "unused"),
            "tail" => variable("tail", "middle"),
            "final" => variable("final", "unused"),
            "unused" => %{"hash" => "unused", "type" => "integer", "defaultValue" => 0}
          }
      }

      assert Featurevisor.set_datafile(f, initial, @replace)
      flush_trace(f)
      refute_received {:trace, _, :call, {Featurevisor.Dependencies, :entity, _}}

      assert_receive {:set,
                      %{
                        features: ["watcher"],
                        variables: ["final", "middle", "source", "tail", "unused"],
                        replaced: @replace
                      }}

      update = %{
        datafile()
        | "revision" => "two",
          "variables" => %{
            "source" => %{"hash" => "two", "type" => "integer", "defaultValue" => 2},
            "middle" => variable("middle-two", "source"),
            "tail" => %{"hash" => "tail-two", "type" => "integer", "defaultValue" => 3},
            "final" => variable("final-two", "tail")
          }
      }

      assert Featurevisor.set_datafile(f, update)
      flush_trace(f)
      assert_received {:trace, _, :call, {Featurevisor.Dependencies, :entity, _}}

      assert_receive {:set,
                      %{
                        features: ["watcher"],
                        variables: ["final", "middle", "source", "tail"]
                      }}

      Featurevisor.Server.with_snapshot(f.table, fn snapshot ->
        assert :ets.match_object(snapshot.regex_cache, {{:normalized, :_, :_}, :_}) == []
      end)

      refute_received {:diagnostic, %{code: "conditions_parse_error"}}

      third = put_in(datafile(), ["variables", "source"], update["variables"]["source"])
      third = put_in(third, ["variables", "source", "hash"], "three")
      third = put_in(third, ["variables", "source", "defaultValue"], 4)
      assert Featurevisor.set_datafile(f, third)
      assert_receive {:set, %{features: [], variables: ["middle", "source"]}}
      assert Featurevisor.get_global_variable(f, "middle") == 4
      assert Featurevisor.get_global_variable(f, "final") == 3
      assert Featurevisor.enabled?(f, "watcher")
    end

    test "a previous segment alone prevents the initial shortcut replace=#{replace}" do
      f = Featurevisor.create_featurevisor(%{log_level: :fatal})
      trace_dependencies(f)
      initial = put_in(datafile(), ["segments", "retained"], %{"conditions" => "*"})
      assert Featurevisor.set_datafile(f, initial)
      flush_trace(f)
      refute_received {:trace, _, :call, {Featurevisor.Dependencies, :entity, _}}

      next =
        initial
        |> put_in(["features", "watcher"], feature("watcher", "retained"))

      assert Featurevisor.set_datafile(f, next, @replace)
      flush_trace(f)
      assert_received {:trace, _, :call, {Featurevisor.Dependencies, :entity, _}}
    end

    test "raw indexing keeps malformed selector caches and diagnostics cold replace=#{replace}" do
      parent = self()

      f =
        Featurevisor.create_featurevisor(%{
          on_diagnostic: fn diagnostic -> send(parent, {:diagnostic, diagnostic}) end
        })

      on_exit(fn -> Featurevisor.close(f) end)

      input =
        datafile()
        |> put_in(["features", "broken"], feature("broken", "["))
        |> put_in(["segments", "broken"], %{"conditions" => "["})

      assert Featurevisor.set_datafile(f, input, @replace)

      assert Featurevisor.set_datafile(
               f,
               put_in(datafile(), ["variables", "source"], %{
                 "hash" => "source",
                 "type" => "integer",
                 "defaultValue" => 1
               })
             )

      Featurevisor.Server.with_snapshot(f.table, fn snapshot ->
        assert :ets.match_object(snapshot.regex_cache, {{:normalized, :_, :_}, :_}) == []
      end)

      refute_received {:diagnostic, %{code: "conditions_parse_error"}}
      assert Featurevisor.get_feature(f, "broken")["conditions"] == %{"or" => []}
      assert_receive {:diagnostic, %{code: "conditions_parse_error"}}
      Featurevisor.get_feature(f, "broken")
      refute_received {:diagnostic, %{code: "conditions_parse_error"}}
      Featurevisor.get_segment(f, "broken")
      assert_receive {:diagnostic, %{code: "conditions_parse_error"}}
      assert input["features"]["broken"]["conditions"] == "["
    end
  end
end
