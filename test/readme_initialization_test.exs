defmodule Featurevisor.ReadmeInitializationTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  setup do
    readme = File.read!(Path.expand("../README.md", __DIR__))
    [_, source] = Regex.run(~r/## Initialization\n.*?```elixir\n(.*?)\n```/s, readme)
    assert length(String.split(source, "featurevisor-all.json")) == 2

    directory =
      Path.join(System.tmp_dir!(), "featurevisor-readme-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    path = Path.join(directory, "featurevisor-all.json")
    source = String.replace(source, ~s("featurevisor-all.json"), inspect(path))
    %{source: source, path: path}
  end

  test "evaluates the extracted example and closes its instance", %{source: source, path: path} do
    for enabled <- [true, false] do
      datafile = %{
        "schemaVersion" => "2",
        "revision" => "readme",
        "segments" => %{},
        "variables" => %{},
        "features" => %{
          "checkout" => %{
            "key" => "checkout",
            "bucketBy" => "userId",
            "traffic" => [
              %{"key" => "all", "segments" => "*", "percentage" => 100_000, "enabled" => enabled}
            ]
          }
        }
      }

      File.write!(path, Jason.encode!(datafile))

      output =
        capture_io(fn ->
          {_, bindings} = Code.eval_string(source, [], file: "README.md")
          instance = Keyword.fetch!(bindings, :f)
          on_exit(fn -> Featurevisor.close(instance) end)
          refute Process.alive?(instance.pid)
        end)

      assert to_string(enabled) in String.split(output, "\n")
    end
  end

  test "raises on a missing datafile", %{source: source} do
    assert_raise File.Error, fn -> Code.eval_string(source, [], file: "README.md") end
  end

  test "raises on malformed JSON", %{source: source, path: path} do
    File.write!(path, "{")
    assert_raise Jason.DecodeError, fn -> Code.eval_string(source, [], file: "README.md") end
  end
end
