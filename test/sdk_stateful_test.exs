defmodule Featurevisor.SDKStatefulTest do
  use ExUnit.Case, async: true

  @fixture Path.expand("../conformance/sdk-stateful.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  test "executes every canonical stateful SDK case" do
    assert @fixture["kind"] == "featurevisor.sdk-stateful"
    assert @fixture["schemaVersion"] == 1
    assert [_ | _] = @fixture["cases"]

    Enum.each(@fixture["cases"], &run_case/1)
  end

  defp run_case(item) do
    test_pid = self()

    root =
      Featurevisor.create_featurevisor(%{
        datafile: item["initial"]["datafile"],
        context: item["initial"]["context"] || %{},
        log_level: :fatal
      })

    subscribe(root, "root", test_pid)

    try do
      Enum.reduce(item["operations"], %{"root" => root}, fn operation, targets ->
        targets = execute_operation(operation, targets, test_pid)
        assert_operation(operation, targets, item["name"])
        targets
      end)
    after
      Process.get({__MODULE__, :children}, [])
      |> Enum.each(&Featurevisor.Child.close/1)

      Process.delete({__MODULE__, :children})
      Featurevisor.close(root)
    end
  end

  defp subscribe(root, target, test_pid) do
    for event <- [:datafile_set, :sticky_features_set, :sticky_variables_set] do
      Featurevisor.on(root, event, fn details ->
        send(test_pid, {:sdk_stateful_event, target, Atom.to_string(event), details})
      end)
    end

    Featurevisor.on(root, :error, fn %{diagnostic: diagnostic} ->
      send(test_pid, {:sdk_stateful_error, target, diagnostic})
    end)
  end

  defp subscribe_child(child, target, test_pid) do
    for event <- [:sticky_features_set, :sticky_variables_set] do
      Featurevisor.Child.on(child, event, fn details ->
        send(test_pid, {:sdk_stateful_event, target, Atom.to_string(event), details})
      end)
    end
  end

  defp execute_operation(%{"action" => "setDatafile"} = operation, targets, _test_pid) do
    result =
      Featurevisor.set_datafile(
        Map.fetch!(targets, operation["target"]),
        operation["datafile"],
        operation["replace"]
      )

    Process.put({__MODULE__, :operation_result}, result)
    targets
  end

  defp execute_operation(%{"action" => "spawn"} = operation, targets, test_pid) do
    child =
      Featurevisor.spawn(
        Map.fetch!(targets, operation["parent"]),
        operation["context"] || %{},
        spawn_options(operation["options"] || %{})
      )

    subscribe_child(child, operation["target"], test_pid)
    Process.put({__MODULE__, :children}, [child | Process.get({__MODULE__, :children}, [])])
    Process.put({__MODULE__, :operation_result}, :ok)
    Map.put(targets, operation["target"], child)
  end

  defp execute_operation(%{"action" => "setStickyFeatures"} = operation, targets, _test_pid) do
    target = Map.fetch!(targets, operation["target"])

    result =
      if operation["target"] == "root" do
        Featurevisor.set_sticky_features(
          target,
          operation["stickyFeatures"],
          operation["replace"]
        )
      else
        Featurevisor.Child.set_sticky_features(
          target,
          operation["stickyFeatures"],
          operation["replace"]
        )
      end

    Process.put({__MODULE__, :operation_result}, result)
    targets
  end

  defp execute_operation(%{"action" => "setStickyVariables"} = operation, targets, _test_pid) do
    target = Map.fetch!(targets, operation["target"])

    result =
      if operation["target"] == "root" do
        Featurevisor.set_sticky_variables(
          target,
          operation["stickyVariables"],
          operation["replace"]
        )
      else
        Featurevisor.Child.set_sticky_variables(
          target,
          operation["stickyVariables"],
          operation["replace"]
        )
      end

    Process.put({__MODULE__, :operation_result}, result)
    targets
  end

  defp assert_operation(operation, targets, case_name) do
    expected = operation["expect"]

    assert_error(expected["error"], operation["action"], case_name)
    assert_events(expected["events"], case_name)

    Enum.each(expected["results"], fn result ->
      assert invoke(result, targets) == result["value"],
             "#{case_name}: #{result["target"]}.#{result["method"]}"
    end)
  end

  defp assert_error(nil, "setDatafile", case_name) do
    assert Process.get({__MODULE__, :operation_result}) === true, case_name
    refute_receive {:sdk_stateful_error, _, _}
  end

  defp assert_error(nil, _action, case_name) do
    assert Process.get({__MODULE__, :operation_result}) == :ok, case_name
    refute_receive {:sdk_stateful_error, _, _}
  end

  defp assert_error(%{"code" => code}, "setDatafile", case_name) do
    assert Process.get({__MODULE__, :operation_result}) === false, case_name
    assert_receive {:sdk_stateful_error, "root", diagnostic}
    assert diagnostic.code == code, case_name
  end

  defp assert_events(expected, case_name) do
    actual =
      Enum.map(expected, fn _ ->
        assert_receive {:sdk_stateful_event, target, name, details}

        %{
          "target" => target,
          "name" => name,
          "details" => normalize_details(details)
        }
      end)

    expected =
      Enum.map(expected, fn event ->
        Map.update!(event, "details", &normalize_details/1)
      end)

    assert actual == expected, case_name
    refute_receive {:sdk_stateful_event, _, _, _}
  end

  defp invoke(%{"target" => target, "method" => "getRevision"}, targets) do
    Featurevisor.get_revision(Map.fetch!(targets, target))
  end

  defp invoke(%{"target" => target, "method" => "isEnabled", "args" => [feature]}, targets) do
    instance = Map.fetch!(targets, target)

    if target == "root",
      do: Featurevisor.enabled?(instance, feature),
      else: Featurevisor.Child.enabled?(instance, feature)
  end

  defp invoke(%{"target" => target, "method" => "getVariable", "args" => [variable]}, targets) do
    instance = Map.fetch!(targets, target)

    if target == "root",
      do: Featurevisor.get_global_variable(instance, variable),
      else: Featurevisor.Child.get_global_variable(instance, variable)
  end

  defp invoke(
         %{"target" => target, "method" => "getVariable", "args" => [feature, variable]},
         targets
       ) do
    instance = Map.fetch!(targets, target)

    if target == "root",
      do: Featurevisor.get_variable(instance, feature, variable),
      else: Featurevisor.Child.get_variable(instance, feature, variable)
  end

  defp spawn_options(options) do
    %{
      sticky_features: options["stickyFeatures"] || %{},
      sticky_variables: options["stickyVariables"] || %{}
    }
  end

  defp normalize_details(details) do
    details
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Map.new()
    |> normalize_keyset("features")
    |> normalize_keyset("variables")
  end

  defp normalize_keyset(details, key) do
    if Map.has_key?(details, key), do: Map.update!(details, key, &Enum.sort/1), else: details
  end
end
