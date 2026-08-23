defmodule FeaturevisorTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias Featurevisor.{Evaluation, Module}

  setup do
    f =
      Featurevisor.create_featurevisor(%{
        datafile: Featurevisor.TestFixtures.datafile(),
        log_level: :fatal
      })

    on_exit(fn -> Featurevisor.close(f) end)
    %{f: f}
  end

  test "evaluates flags, variations, variables, and detailed results", %{f: f} do
    context = %{"userId" => "a", "country" => "nl"}
    assert Featurevisor.enabled?(f, "flag", context)

    assert %Evaluation{reason: :rule, enabled: true} =
             Featurevisor.evaluate_flag(f, "flag", context)

    at = %Module{name: "at", bucket_value: fn _ -> 75_000 end}
    unsubscribe = Featurevisor.add_module(f, at)
    assert Featurevisor.get_variation(f, "experiment", context) == "treatment"
    assert Featurevisor.get_variable(f, "experiment", "title", context) == "Treatment"
    assert Featurevisor.get_variable_integer(f, "experiment", "count", context) == 0

    assert Featurevisor.get_variable_json(f, "experiment", "config", context) == %{
             "enabled" => true
           }

    unsubscribe.()
  end

  test "uses explicit false, zero, empty, and nil defaults by presence", %{f: f} do
    assert Featurevisor.get_variation(f, "missing", %{}, %{default_variation_value: ""}) == ""

    assert Featurevisor.get_variable(f, "missing", "x", %{}, %{default_variable_value: false}) ==
             false

    assert Featurevisor.get_variable(f, "missing", "x", %{}, %{default_variable_value: 0}) == 0

    assert Featurevisor.get_variable(f, "missing", "x", %{}, %{default_variable_value: nil}) ==
             nil
  end

  test "merges and replaces datafiles", %{f: f} do
    assert :ok =
             Featurevisor.set_datafile(f, %{
               "schemaVersion" => "2",
               "revision" => "next",
               "segments" => %{},
               "features" => %{
                 "extra" => %{"key" => "extra", "bucketBy" => "id", "traffic" => []}
               }
             })

    assert Featurevisor.get_feature(f, "flag")
    assert Featurevisor.get_feature(f, "extra")
    assert Featurevisor.get_revision(f) == "next"

    assert :ok =
             Featurevisor.set_datafile(
               f,
               Jason.encode!(%{
                 "schemaVersion" => "2",
                 "revision" => "last",
                 "segments" => %{},
                 "features" => %{}
               }),
               true
             )

    assert Featurevisor.get_feature_keys(f) == []
  end

  test "keeps old datafile and reports stable parse failure message", %{f: f} do
    parent = self()

    Featurevisor.on(f, :error, fn %{diagnostic: diagnostic} ->
      send(parent, {:error, diagnostic})
    end)

    assert {:error, _} = Featurevisor.set_datafile(f, "{")
    assert Featurevisor.get_revision(f) == "test"
    assert_receive {:error, %{message: "Could not parse datafile", code: "invalid_datafile"}}
  end

  test "supports forced values and aggregate evaluations", %{f: f} do
    context = %{"userId" => "1", "country" => "nl"}
    assert Featurevisor.enabled?(f, "forced", context)
    assert Featurevisor.get_variable(f, "forced", "colour", context) == "orange"
    all = Featurevisor.get_all_evaluations(f, context, ["forced"])
    assert all["forced"].enabled
    assert all["forced"].variables["colour"] == "orange"
  end

  test "returns segments with parsed conditions", %{f: f} do
    assert %{"conditions" => [%{"operator" => "equals"}]} = Featurevisor.get_segment(f, "nl")
    assert Featurevisor.get_segment(f, "missing") == nil
  end

  test "reports malformed JSON variables", %{f: f} do
    parent = self()
    Featurevisor.set_log_level(f, :error)
    Featurevisor.on(f, :error, fn %{diagnostic: diagnostic} -> send(parent, diagnostic) end)

    datafile = Featurevisor.TestFixtures.datafile()

    datafile =
      put_in(
        datafile,
        ["features", "experiment", "variablesSchema", "config", "defaultValue"],
        "{"
      )

    Featurevisor.set_datafile(f, datafile, true)

    capture_io(:stderr, fn ->
      assert Featurevisor.get_variable_json(f, "experiment", "config") == nil
    end)

    assert_receive %{code: "evaluation_error", message: "getVariable failed"}
  end

  test "typed getters reject mismatches", %{f: f} do
    assert Featurevisor.get_variable_string(f, "experiment", "count") == nil
    assert Featurevisor.get_variable_boolean(f, "experiment", "count") == nil
    assert Featurevisor.get_variable_array(f, "experiment", "count") == nil
    assert Featurevisor.get_variable_object(f, "experiment", "count") == nil
  end
end
