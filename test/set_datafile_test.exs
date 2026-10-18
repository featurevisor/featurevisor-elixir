defmodule Featurevisor.SetDatafileTest do
  use ExUnit.Case, async: true

  defp datafile(revision, key) do
    %{
      "schemaVersion" => "2",
      "revision" => revision,
      "features" => %{key => %{"hash" => key, "bucketBy" => "id", "traffic" => []}},
      "segments" => %{key => %{"conditions" => "*"}},
      "variables" => %{key => %{"hash" => key, "type" => "string", "defaultValue" => key}}
    }
  end

  defp encode(datafile, true), do: Jason.encode!(datafile)
  defp encode(datafile, false), do: datafile

  for encoded <- [false, true], mode <- [:default, false, true] do
    @encoded encoded
    @mode mode
    test "accepts initial, unchanged and changed input encoded=#{encoded} mode=#{mode}" do
      parent = self()

      f =
        Featurevisor.create_featurevisor(%{
          on_diagnostic: fn diagnostic -> send(parent, {:diagnostic, diagnostic}) end
        })

      on_exit(fn -> Featurevisor.close(f) end)
      Featurevisor.on(f, :datafile_set, fn details -> send(parent, {:set, details}) end)

      set = fn value ->
        value = encode(value, @encoded)

        if @mode == :default,
          do: Featurevisor.set_datafile(f, value),
          else: Featurevisor.set_datafile(f, value, @mode)
      end

      assert set.(datafile("one", "original")) === true

      assert_receive {:set,
                      %{revision: "one", previousRevision: "unknown", revisionChanged: true}}

      assert set.(datafile("one", "original")) === true
      replaced = @mode == true

      assert_receive {:set,
                      %{
                        revision: "one",
                        previousRevision: "one",
                        revisionChanged: false,
                        features: [],
                        variables: [],
                        replaced: ^replaced
                      }}

      assert set.(datafile("one", "next")) === true
      assert_receive {:set, %{revisionChanged: false}}
      assert Featurevisor.get_feature(f, "original") != nil == not replaced
      assert Featurevisor.get_segment(f, "original") != nil == not replaced
      assert "original" in Featurevisor.get_global_variable_keys(f) == not replaced
      assert Featurevisor.get_feature(f, "next")
      assert Featurevisor.get_segment(f, "next")
      assert "next" in Featurevisor.get_global_variable_keys(f)
      updated = put_in(datafile("two", "next"), ["features", "next", "hash"], "changed")
      assert set.(updated) === true
      assert Featurevisor.get_revision(f) == "two"

      assert_receive {:set,
                      %{
                        previousRevision: "one",
                        revision: "two",
                        revisionChanged: true,
                        features: ["next"]
                      }}

      for _ <- 1..4, do: assert_receive({:diagnostic, %{code: "datafile_set"}})
      refute_receive {:set, _}
      refute_receive {:diagnostic, %{code: "datafile_set"}}
    end
  end

  for replace <- [false, true] do
    @replace replace
    test "rejects invalid input without changing the last valid datafile replace=#{replace}" do
      parent = self()
      original = datafile("valid", "original")

      f =
        Featurevisor.create_featurevisor(%{
          datafile: original,
          on_diagnostic: fn diagnostic -> send(parent, {:diagnostic, diagnostic}) end
        })

      on_exit(fn -> Featurevisor.close(f) end)
      Featurevisor.on(f, :datafile_set, fn details -> send(parent, {:set, details}) end)
      Featurevisor.on(f, :error, fn details -> send(parent, {:error, details.diagnostic}) end)

      invalid = ["{", "null", "[]", "true", "7", ~s("text"), "{}", nil, [], true, 7, %{}]

      invalid =
        invalid ++
          for field <- ["schemaVersion", "revision", "features", "segments", "variables"],
              encoded <- [false, true],
              do: encode(Map.put(original, field, 17), encoded)

      for value <- invalid do
        assert Featurevisor.set_datafile(f, value, @replace) === false
        assert Featurevisor.get_revision(f) == "valid"
        assert Featurevisor.get_feature(f, "original")
        assert Featurevisor.get_segment(f, "original")
        assert Featurevisor.get_global_variable_keys(f) == ["original"]

        assert_receive {:diagnostic,
                        %{
                          code: "invalid_datafile",
                          message: "Could not parse datafile",
                          original_error: reason
                        }}

        assert reason != nil
        assert_receive {:error, %{code: "invalid_datafile"}}
      end

      refute_receive {:set, _}
      assert Featurevisor.set_datafile(f, original, @replace) === true

      assert_receive {:set,
                      %{
                        previousRevision: "valid",
                        revisionChanged: false,
                        features: [],
                        variables: []
                      }}
    end
  end

  test "preserves acceptance of empty revisions and optional variables" do
    f = Featurevisor.create_featurevisor(%{log_level: :fatal})
    on_exit(fn -> Featurevisor.close(f) end)

    for value <- [datafile("", "flag"), Map.delete(datafile("next", "flag"), "variables")],
        encoded <- [false, true],
        replace <- [false, true] do
      assert Featurevisor.set_datafile(f, encode(value, encoded), replace) === true
    end
  end

  test "callback exceptions, throws and exits do not change acceptance or stop listeners" do
    parent = self()

    for fail <- [
          fn -> raise "callback" end,
          fn -> throw(:callback) end,
          fn -> exit(:callback) end
        ] do
      f =
        Featurevisor.create_featurevisor(%{
          on_diagnostic: fn _ -> fail.() end,
          modules: [
            %Featurevisor.Module{
              name: "diagnostics",
              setup: fn api ->
                api.on_diagnostic.(fn _ -> fail.() end, %{log_level: :debug})
              end
            }
          ]
        })

      for event <- [:datafile_set, :error] do
        Featurevisor.on(f, event, fn _ -> fail.() end)
        Featurevisor.on(f, event, fn _ -> send(parent, {event, Featurevisor.get_revision(f)}) end)
      end

      for replace <- [false, true] do
        assert Featurevisor.set_datafile(f, datafile("accepted", "flag"), replace) === true
        assert_receive {:datafile_set, "accepted"}
        assert Featurevisor.set_datafile(f, "bad", replace) === false
        assert_receive {:error, "accepted"}
      end

      Featurevisor.close(f)
    end
  end

  test "accepted update stays true when a listener closes the instance" do
    f = Featurevisor.create_featurevisor(%{log_level: :fatal})
    Featurevisor.on(f, :datafile_set, fn _ -> Featurevisor.close(f) end)
    assert Featurevisor.set_datafile(f, datafile("accepted", "flag")) === true
    assert Featurevisor.set_datafile(f, datafile("late", "flag")) === false
  end

  test "rejected update stays false when an error listener recovers" do
    parent = self()
    f = Featurevisor.create_featurevisor(%{log_level: :fatal})
    on_exit(fn -> Featurevisor.close(f) end)

    Featurevisor.on(f, :error, fn _ ->
      send(
        parent,
        {:recovered, Featurevisor.set_datafile(f, datafile("recovered", "flag"), true)}
      )
    end)

    assert Featurevisor.set_datafile(f, "bad", true) === false
    assert_receive {:recovered, true}
    assert Featurevisor.get_revision(f) == "recovered"
  end

  test "closed instances reject valid and invalid inputs without callbacks" do
    parent = self()
    f = Featurevisor.create_featurevisor(%{log_level: :fatal})

    for event <- [:datafile_set, :error] do
      Featurevisor.on(f, event, fn details -> send(parent, {:event, details}) end)
    end

    Featurevisor.close(f)

    for value <- [
          datafile("late", "flag"),
          Jason.encode!(datafile("late", "flag")),
          "bad",
          %{},
          nil
        ],
        replace <- [false, true] do
      assert Featurevisor.set_datafile(f, value, replace) === false
      assert Featurevisor.set_datafile(f, value) === false
    end

    refute_receive {:event, _}
    assert Featurevisor.get_feature_keys(f) == []
  end

  test "closure queued before an update rejects it at the owner" do
    for replace <- [false, true] do
      f = Featurevisor.create_featurevisor(%{log_level: :fatal})
      parent = self()
      Featurevisor.on(f, :datafile_set, fn _ -> send(parent, :unexpected_update) end)
      :ok = :sys.suspend(f.pid)
      closing = Task.async(fn -> Featurevisor.Server.close(f.pid) end)
      await_calls(f.pid, 1)

      updating =
        Task.async(fn -> Featurevisor.set_datafile(f, datafile("late", "flag"), replace) end)

      await_calls(f.pid, 2)
      :ok = :sys.resume(f.pid)
      Task.await(closing)
      assert Task.await(updating) === false
      refute_receive :unexpected_update
      GenServer.stop(f.pid)
    end
  end

  test "owner stopping while an update is queued returns false" do
    for replace <- [false, true] do
      f = Featurevisor.create_featurevisor(%{log_level: :fatal})
      :ok = :sys.suspend(f.pid)

      updating =
        Task.async(fn -> Featurevisor.set_datafile(f, datafile("late", "flag"), replace) end)

      await_calls(f.pid, 1)
      :ok = :sys.terminate(f.pid, :normal)
      assert Task.await(updating) === false
    end
  end

  defp await_calls(pid, count, attempts \\ 1_000)
  defp await_calls(_pid, _count, 0), do: flunk("owner did not receive the expected calls")

  defp await_calls(pid, count, attempts) do
    {:messages, messages} = Process.info(pid, :messages)

    if Enum.count(messages, &match?({:"$gen_call", _, _}, &1)) >= count do
      :ok
    else
      Process.sleep(1)
      await_calls(pid, count, attempts - 1)
    end
  end
end
