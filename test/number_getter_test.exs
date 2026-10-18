defmodule Featurevisor.NumberGetterTest do
  use ExUnit.Case, async: true

  @datafile %{
    "schemaVersion" => "4",
    "revision" => "1",
    "segments" => %{},
    "features" => %{
      "pricing" => %{
        "bucketBy" => "userId",
        "variablesSchema" => %{
          "rate" => %{"type" => "number", "defaultValue" => 2.5},
          "ratio" => %{"type" => "double", "defaultValue" => 1.5}
        },
        "traffic" => [%{"key" => "all", "conditions" => "*", "percentage" => 100_000}]
      }
    },
    "variables" => %{
      "rate" => %{"type" => "number", "defaultValue" => 2.5},
      "ratio" => %{"type" => "double", "defaultValue" => 1.5}
    }
  }

  setup do
    f = Featurevisor.create_featurevisor(%{datafile: @datafile, log_level: :fatal})
    on_exit(fn -> Featurevisor.close(f) end)
    %{f: f}
  end

  test "reads number variables and earlier double variables the same way", %{f: f} do
    context = %{"userId" => "u"}
    assert Featurevisor.get_variable_number(f, "pricing", "rate", context) == 2.5
    assert Featurevisor.get_variable_number(f, "pricing", "ratio", context) == 1.5
    assert Featurevisor.get_global_variable_number(f, "rate") == 2.5
    assert Featurevisor.get_global_variable_number(f, "ratio") == 1.5

    child = Featurevisor.spawn(f, context)
    assert Featurevisor.Child.get_variable_number(child, "pricing", "rate") == 2.5
    assert Featurevisor.Child.get_global_variable_number(child, "rate") == 2.5
  end

  test "no longer has the double getters removed in v4" do
    for {module, name, arity} <- [
          {Featurevisor, :get_variable_double, 5},
          {Featurevisor, :get_global_variable_double, 4},
          {Featurevisor.Child, :get_variable_double, 5},
          {Featurevisor.Child, :get_global_variable_double, 4}
        ] do
      Code.ensure_loaded!(module)
      refute function_exported?(module, name, arity)

      assert function_exported?(
               module,
               String.to_atom(String.replace(Atom.to_string(name), "double", "number")),
               arity
             )
    end
  end
end
