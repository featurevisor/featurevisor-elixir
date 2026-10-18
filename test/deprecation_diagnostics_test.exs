defmodule Featurevisor.DeprecationDiagnosticsTest do
  use ExUnit.Case, async: true

  @datafile %{
    "schemaVersion" => "4",
    "revision" => "1",
    "segments" => %{},
    "features" => %{
      "legacy" => %{
        "deprecated" => true,
        "bucketBy" => "userId",
        "variablesSchema" => %{
          "old" => %{"type" => "string", "defaultValue" => "x", "deprecated" => true}
        },
        "traffic" => [
          %{"key" => "all", "conditions" => "*", "percentage" => 100_000, "allocation" => []}
        ]
      }
    },
    "variables" => %{
      "oldGlobal" => %{"type" => "string", "defaultValue" => "y", "deprecated" => true}
    }
  }

  test "deprecated features and variables use one code per kind" do
    parent = self()

    f =
      Featurevisor.create_featurevisor(%{
        datafile: @datafile,
        log_level: :warn,
        on_diagnostic: fn diagnostic ->
          if String.contains?(diagnostic.code, "deprecated"),
            do: send(parent, {:deprecated, diagnostic.code})
        end
      })

    on_exit(fn -> Featurevisor.close(f) end)

    Featurevisor.enabled?(f, "legacy")
    assert MapSet.new(drain()) == MapSet.new(["deprecated_feature"])

    Featurevisor.get_variable(f, "legacy", "old")
    assert MapSet.new(drain()) == MapSet.new(["deprecated_feature", "deprecated_variable"])

    Featurevisor.get_global_variable(f, "oldGlobal")
    assert drain() == ["deprecated_variable"]
  end

  defp drain(codes \\ []) do
    receive do
      {:deprecated, code} -> drain([code | codes])
    after
      0 -> Enum.reverse(codes)
    end
  end
end
