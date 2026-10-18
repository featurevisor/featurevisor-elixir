defmodule Featurevisor.LiveModulesTest do
  use ExUnit.Case, async: true

  test "a diagnostic installs after hooks for the in flight dependency and both root types" do
    for global <- [false, true], disable_gate <- [false, true] do
      parent = self()
      {:ok, holder} = Agent.start_link(fn -> nil end)

      sdk =
        Featurevisor.create_featurevisor(%{
          log_level: :error,
          datafile: datafile(),
          on_diagnostic: fn diagnostic ->
            if diagnostic.code == "conditions_parse_error" do
              Featurevisor.add_module(Agent.get(holder, & &1), module(parent, disable_gate))
            end
          end
        })

      Agent.update(holder, fn _ -> sdk end)

      evaluation =
        if global,
          do: Featurevisor.evaluate_global_variable(sdk, "subject"),
          else: Featurevisor.evaluate_flag(sdk, "subject")

      if global do
        assert evaluation.variable_value == if(disable_gate, do: nil, else: "matched")
      else
        assert evaluation.enabled == not disable_gate
      end

      if disable_gate, do: assert(evaluation.reason == :conditions_unmet)
      assert trace() == ["after:broken", "before:gate", "after:gate", "after:subject"]
      Featurevisor.close(sdk)
      Agent.stop(holder)
    end
  end

  test "a diagnostic removes hooks before the after phase for both root types" do
    for global <- [false, true] do
      parent = self()
      {:ok, holder} = Agent.start_link(fn -> nil end)

      sdk =
        Featurevisor.create_featurevisor(%{
          log_level: :error,
          datafile: datafile(),
          on_diagnostic: fn diagnostic ->
            if diagnostic.code == "conditions_parse_error", do: Agent.get(holder, & &1).()
          end
        })

      remove = Featurevisor.add_module(sdk, module(parent))
      Agent.update(holder, fn _ -> remove end)
      assert evaluate(sdk, global) == if(global, do: "matched", else: true)
      assert trace() == ["before:subject", "before:broken"]
      Featurevisor.close(sdk)
      Agent.stop(holder)
    end
  end

  test "before and after phases retain their starting membership for feature and global roots" do
    for global <- [false, true],
        phase <- [:before, :after],
        action <- [:add, :remove, :remove_add] do
      parent = self()
      {:ok, once} = Agent.start_link(fn -> true end)
      sdk = Featurevisor.create_featurevisor(%{datafile: phase_datafile(), log_level: :fatal})

      mutate = fn ->
        if Agent.get_and_update(once, &{&1, false}) do
          if action in [:remove, :remove_add], do: Featurevisor.remove_module(sdk, "other")

          if action in [:add, :remove_add],
            do: Featurevisor.add_module(sdk, phase_module(parent, "late"))
        end
      end

      Featurevisor.add_module(sdk, phase_module(parent, "adder", phase, mutate))
      remove_other = Featurevisor.add_module(sdk, phase_module(parent, "other"))
      assert phase_evaluate(sdk, global) == if(global, do: 7, else: true)

      before = ["before:adder", "before:other"]
      closing = if action in [:remove, :remove_add], do: ["close:other"], else: []

      after_names =
        case action do
          :add -> ["adder", "other", "late"]
          :remove -> ["adder"]
          :remove_add -> ["adder", "late"]
        end

      expected =
        if phase == :before do
          ["before:adder"] ++ closing ++ ["before:other"] ++ Enum.map(after_names, &"after:#{&1}")
        else
          before ++ ["after:adder"] ++ closing ++ ["after:other"]
        end

      assert trace() == expected
      assert phase_evaluate(sdk, global) == if(global, do: 7, else: true)

      assert trace() ==
               Enum.map(after_names, &"before:#{&1}") ++ Enum.map(after_names, &"after:#{&1}")

      remove_other.()
      remove_other.()
      assert trace() == if(action == :add, do: ["close:other"], else: [])
      Featurevisor.close(sdk)
      Featurevisor.close(sdk)
      assert trace() == Enum.map(List.delete(after_names, "other"), &"close:#{&1}")
      Agent.stop(once)
    end
  end

  test "bucket key and value phases refresh membership but keep their own immutable lists" do
    for phase <- [:before, :bucket_key, :bucket_value], action <- [:add, :remove, :remove_add] do
      parent = self()
      {:ok, once} = Agent.start_link(fn -> true end)
      sdk = Featurevisor.create_featurevisor(%{datafile: phase_datafile(), log_level: :fatal})

      mutate = fn ->
        if Agent.get_and_update(once, &{&1, false}) do
          if action in [:remove, :remove_add], do: Featurevisor.remove_module(sdk, "other")

          if action in [:add, :remove_add],
            do: Featurevisor.add_module(sdk, bucket_module(parent, "late"))
        end
      end

      Featurevisor.add_module(sdk, bucket_module(parent, "adder", phase, mutate))
      Featurevisor.add_module(sdk, bucket_module(parent, "other"))
      evaluation = Featurevisor.evaluate_flag(sdk, "plain", %{"id" => "test"})
      assert evaluation.enabled
      assert evaluation.bucket_value == 42

      starting = ["adder", "other"]

      following =
        case action do
          :add -> ["adder", "other", "late"]
          :remove -> ["adder"]
          :remove_add -> ["adder", "late"]
        end

      {expected, _} =
        Enum.map_reduce([:before, :bucket_key, :bucket_value, :after], starting, fn current,
                                                                                    names ->
          values = Enum.map(names, &"#{current}:#{&1}")
          {values, if(current == phase, do: following, else: names)}
        end)

      assert trace() == List.flatten(expected)
      assert Featurevisor.enabled?(sdk, "plain", %{"id" => "test"})

      assert trace() ==
               for(
                 current <- [:before, :bucket_key, :bucket_value, :after],
                 name <- following,
                 do: "#{current}:#{name}"
               )

      Featurevisor.close(sdk)
      Agent.stop(once)
    end
  end

  test "membership changes survive callback errors without continuing the failed phase" do
    for global <- [false, true], phase <- [:before, :after] do
      parent = self()
      {:ok, once} = Agent.start_link(fn -> true end)
      sdk = Featurevisor.create_featurevisor(%{datafile: phase_datafile(), log_level: :fatal})

      mutate = fn ->
        if Agent.get_and_update(once, &{&1, false}) do
          Featurevisor.remove_module(sdk, "other")
          Featurevisor.add_module(sdk, phase_module(parent, "late"))
          raise "phase failure"
        end
      end

      Featurevisor.add_module(sdk, phase_module(parent, "adder", phase, mutate))
      Featurevisor.add_module(sdk, phase_module(parent, "other"))

      evaluation =
        if global,
          do: Featurevisor.evaluate_global_variable(sdk, "plain"),
          else: Featurevisor.evaluate_flag(sdk, "plain", %{"id" => "test"})

      assert evaluation.reason == :error
      assert Exception.message(evaluation.error) == "phase failure"

      assert trace() ==
               if(phase == :before,
                 do: ["before:adder", "close:other"],
                 else: ["before:adder", "before:other", "after:adder", "close:other"]
               )

      assert phase_evaluate(sdk, global) == if(global, do: 7, else: true)
      assert trace() == ["before:adder", "before:late", "after:adder", "after:late"]
      Featurevisor.close(sdk)
      assert trace() == ["close:adder", "close:late"]
      Agent.stop(once)
    end
  end

  defp phase_evaluate(sdk, true), do: Featurevisor.get_global_variable(sdk, "plain")
  defp phase_evaluate(sdk, false), do: Featurevisor.enabled?(sdk, "plain", %{"id" => "test"})

  defp phase_module(parent, name, phase \\ nil, mutate \\ fn -> :ok end) do
    %Featurevisor.Module{
      name: name,
      before_evaluation: fn options ->
        send(parent, {:trace, "before:#{name}"})
        if phase == :before, do: mutate.()
        options
      end,
      after_evaluation: fn evaluation, _options ->
        send(parent, {:trace, "after:#{name}"})
        if phase == :after, do: mutate.()
        evaluation
      end,
      close: fn -> send(parent, {:trace, "close:#{name}"}) end
    }
  end

  defp bucket_module(parent, name, phase \\ nil, mutate \\ fn -> :ok end) do
    module = phase_module(parent, name, phase, mutate)

    %{
      module
      | close: nil,
        bucket_key: fn options ->
          send(parent, {:trace, "bucket_key:#{name}"})
          if phase == :bucket_key, do: mutate.()
          options.bucket_key <> ":#{name}"
        end,
        bucket_value: fn _options ->
          send(parent, {:trace, "bucket_value:#{name}"})
          if phase == :bucket_value, do: mutate.()
          42
        end
    }
  end

  defp phase_datafile do
    %{
      datafile()
      | "features" => %{"plain" => datafile()["features"]["gate"]},
        "variables" => %{"plain" => %{"type" => "integer", "defaultValue" => 7}}
    }
  end

  defp module(parent, disable_gate \\ false) do
    %Featurevisor.Module{
      name: "live",
      before_evaluation: fn options ->
        send(parent, {:trace, "before:#{options[:feature_key] || options[:variable_key]}"})
        options
      end,
      after_evaluation: fn evaluation, options ->
        send(parent, {:trace, "after:#{options[:feature_key] || options[:variable_key]}"})
        refute Map.has_key?(options, :sticky_owner)
        assert is_map(options.sticky_features) or is_nil(options.sticky_features)
        assert is_map(options.sticky_variables) or is_nil(options.sticky_variables)
        if options[:feature_key], do: refute(is_struct(options.datafile["features"]))

        if disable_gate and options[:feature_key] == "gate",
          do: %{evaluation | enabled: false},
          else: evaluation
      end
    }
  end

  defp trace do
    receive do
      {:trace, value} -> [value | trace()]
    after
      0 -> []
    end
  end

  defp evaluate(sdk, true), do: Featurevisor.get_global_variable(sdk, "subject")
  defp evaluate(sdk, false), do: Featurevisor.enabled?(sdk, "subject")

  defp datafile do
    feature = %{
      "bucketBy" => "id",
      "traffic" => [%{"key" => "all", "conditions" => "*", "percentage" => 100_000}]
    }

    conditions = %{"or" => [%{"feature" => "broken"}, %{"feature" => "gate"}]}

    %{
      "schemaVersion" => "4",
      "revision" => "live",
      "segments" => %{},
      "features" => %{
        "broken" => Map.put(feature, "conditions", "[broken"),
        "gate" => feature,
        "subject" => Map.put(feature, "conditions", conditions)
      },
      "variables" => %{
        "subject" => %{
          "type" => "string",
          "defaultValue" => "matched",
          "conditions" => conditions
        }
      }
    }
  end
end
