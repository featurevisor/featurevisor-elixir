defmodule Featurevisor.CLICacheTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  setup do
    directory =
      Path.join(System.tmp_dir!(), "featurevisor-cache-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    npx = Path.join(directory, "npx")

    File.write!(npx, """
    #!/usr/bin/env python3
    import json, sys
    args = sys.argv[2:]
    with open("fixture.json", encoding="utf-8") as source:
        fixture = json.load(source)
    with open("calls.jsonl", "a", encoding="utf-8") as log:
        log.write(json.dumps(args) + "\\n")
    if args[0] == "config": value = fixture["config"]
    elif "--segments" in args: value = []
    elif "--targets" in args: value = [{"key": target} for target in fixture["targets"]]
    elif "--tests" in args:
        value = {"kind": "featurevisor.test-execution", "schemaVersion": 1, "tests": fixture["tests"]}
    elif args[0] == "build":
        def option(name):
            return next((arg[len(name)+3:] for arg in args if arg.startswith("--"+name+"=")), None)
        selection = [option("environment"), option("target")]
        value = {"schemaVersion": "2", "revision": "cache", "segments": {}, "features": {},
                 "variables": {"selection": {"type": "string", "defaultValue": json.dumps(selection, ensure_ascii=False, separators=(",", ":"))}}}
    else: raise SystemExit("unexpected arguments: " + repr(args))
    print(json.dumps(value))
    """)

    File.chmod!(npx, 0o755)
    path = System.fetch_env!("PATH")
    System.put_env("PATH", directory <> ":" <> path)

    on_exit(fn ->
      System.put_env("PATH", path)
      File.rm_rf!(directory)
    end)

    %{directory: directory}
  end

  for flat <- [false, true] do
    test "cache isolates every selection with flat=#{flat}", %{directory: directory} do
      assert_cache_selections(unquote(flat), directory)
    end
  end

  defp assert_cache_selections(flat, directory) do
    targets = ["web", "web-target-mobile", "mobile", "Café 東京 🧪\"\\", "[null,\"web\"]"]

    environments =
      if flat,
        do: [nil],
        else: [
          "prod",
          "prod-target-web",
          "prod-target-web-target-mobile",
          "false",
          "__no_environment__",
          "Café 東京 🧪\"\\",
          "[null,\"web\"]"
        ]

    selections =
      for environment <- environments, target <- [nil | targets], do: {environment, target}

    assertions =
      selections
      |> Enum.with_index()
      |> Enum.map(fn {{environment, target}, index} ->
        %{
          "environment" => environment,
          "target" => target,
          "expectedValue" => Jason.encode!([environment, target]),
          "_case" => %{
            "id" => Jason.encode!([nil, "variable", "selection", index, nil]),
            "assertionIndex" => index,
            "matrixIndex" => nil,
            "matrixValues" => %{}
          }
        }
      end)

    fixture = %{
      "config" =>
        if(flat,
          do: %{"sets" => false},
          else: %{"sets" => false, "environments" => environments}
        ),
      "targets" => targets,
      "tests" => [
        %{
          "key" => "selection",
          "variable" => "selection",
          "assertions" => assertions,
          "_test" => %{
            "source" => "tests/selection.json",
            "entityType" => "variable",
            "set" => nil
          }
        }
      ]
    }

    File.write!(Path.join(directory, "fixture.json"), Jason.encode!(fixture))

    output =
      capture_io(fn ->
        assert :ok =
                 Featurevisor.CLI.execute([
                   "test",
                   "--json",
                   "--projectDirectoryPath=#{directory}"
                 ])
      end)

    report = Jason.decode!(output)
    assert report["passed"]
    cases = hd(report["results"])["cases"]
    assert length(cases) == length(selections)

    Enum.zip(cases, selections)
    |> Enum.each(fn {item, {environment, target}} ->
      assert item["environment"] == environment
      assert item["target"] == target
      assert item["passed"]
    end)

    builds =
      File.read!(Path.join(directory, "calls.jsonl"))
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&(hd(&1) == "build"))

    assert length(builds) == length(selections)
  end

  test "explicit Sets including empty are rejected for non Sets projects", %{directory: directory} do
    File.write!(
      Path.join(directory, "fixture.json"),
      Jason.encode!(%{"config" => %{"sets" => false}})
    )

    for command <- ["test", "benchmark", "assess-distribution"], selected <- ["", "web"] do
      command_options = if command == "test", do: ["--json"], else: ["--feature=flag", "--n=1"]

      capture_io(fn ->
        assert {:error, message} =
                 Featurevisor.CLI.execute(
                   [command, "--set=#{selected}", "--projectDirectoryPath=#{directory}"] ++
                     command_options
                 )

        assert message =~ "Omit --set"
      end)
    end

    calls =
      File.read!(Path.join(directory, "calls.jsonl"))
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert Enum.all?(calls, &(hd(&1) == "config"))
  end
end
