defmodule Featurevisor.FullRefreshOwnershipTest do
  use ExUnit.Case, async: false

  for schema <- ["2", "4"], replace <- [false, true] do
    test "nested values and pinned cold readers survive schema #{schema}, replace #{replace}" do
      schema = unquote(schema)
      replace = unquote(replace)
      parent = self()

      payload = %{
        "conditions" => %{"variable" => "ignored", "operator" => "notNull"},
        "rows" => [%{"label" => "old"}]
      }

      definition = %{
        "type" => "object",
        "hash" => "same",
        "defaultValue" => payload,
        "metadata" => %{"nested" => ["old"]}
      }

      source = %{
        "schemaVersion" => schema,
        "revision" => "initial",
        "segments" => %{},
        "features" => %{},
        "variables" => %{
          "value" => definition,
          "cold" => definition,
          "removed" => definition,
          "broken" => %{
            "type" => "boolean",
            "defaultValue" => true,
            "conditions" => "[",
            "hash" => "same"
          }
        }
      }

      sdk =
        Featurevisor.create_featurevisor(%{
          datafile: source,
          log_level: :error,
          on_diagnostic: fn item ->
            if item.code == "conditions_parse_error", do: send(parent, :parse_error)
          end
        })

      try do
        if schema == "2", do: assert_receive(:parse_error), else: refute_receive(:parse_error)
        for _ <- 1..2, do: assert(is_nil(Featurevisor.get_global_variable(sdk, "broken")))
        if schema == "4", do: assert_receive(:parse_error)
        refute_receive :parse_error
        assert Featurevisor.get_global_variable(sdk, "value") == payload

        reader =
          Task.async(fn ->
            Featurevisor.Server.with_snapshot(sdk.table, fn snapshot ->
              send(parent, :pinned)

              receive do
                :read ->
                  Featurevisor.Normalize.get(
                    snapshot.datafile,
                    "variables",
                    "cold",
                    snapshot.regex_cache,
                    fn _ -> :ok end
                  )
              end
            end)
          end)

        assert_receive :pinned

        updated =
          source
          |> Map.put("revision", "next")
          |> update_in(["variables"], &Map.delete(&1, "removed"))

        updated =
          Enum.reduce(["value", "cold"], updated, fn key, data ->
            data
            |> put_in(["variables", key, "defaultValue", "rows"], [%{"label" => "new"}])
            |> put_in(["variables", key, "metadata", "nested"], ["new"])
          end)

        assert Featurevisor.set_datafile(sdk, updated, replace)

        for key <- ["value", "cold"] do
          assert Featurevisor.get_global_variable(sdk, key)["rows"] == [%{"label" => "new"}]
        end

        Featurevisor.Server.with_snapshot(sdk.table, fn snapshot ->
          current =
            Featurevisor.Normalize.get(
              snapshot.datafile,
              "variables",
              "cold",
              snapshot.regex_cache,
              fn _ -> :ok end
            )

          assert current["metadata"] == %{"nested" => ["new"]}
        end)

        for _ <- 1..2, do: assert(is_nil(Featurevisor.get_global_variable(sdk, "broken")))
        assert_receive :parse_error
        refute_receive :parse_error
        assert "removed" in Featurevisor.get_global_variable_keys(sdk) == not replace

        Featurevisor.on(sdk, :datafile_set, &send(parent, {:change, &1}))

        assert Featurevisor.set_datafile(sdk, %{
                 source
                 | "revision" => "payload",
                   "variables" => %{
                     "ignored" => %{"type" => "integer", "defaultValue" => 1, "hash" => "new"}
                   }
               })

        assert_receive {:change, %{variables: ["ignored"]}}

        assert Featurevisor.set_datafile(
                 sdk,
                 %{source | "revision" => "empty", "variables" => %{}},
                 true
               )

        assert Featurevisor.get_global_variable_keys(sdk) == []
        send(reader.pid, :read)
        old = Task.await(reader)
        assert old["metadata"] == %{"nested" => ["old"]}
        assert old["defaultValue"] == payload
      after
        Featurevisor.close(sdk)
      end
    end
  end
end
