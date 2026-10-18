defmodule Featurevisor.CLIReportTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  test "ordinary failures retain typed values and authored root and child paths" do
    directory =
      Path.join(System.tmp_dir!(), "featurevisor-report-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    npx = Path.join(directory, "npx")

    File.write!(npx, """
    #!/usr/bin/env python3
    import json, sys
    with open("fixture.json", encoding="utf-8") as source:
        fixture = json.load(source)
    args = sys.argv[2:]
    if args[0] == "config": value = {"sets": False, "environments": False}
    elif "--targets" in args: value = []
    elif "--segments" in args: value = [{"key": "all", "conditions": "*"}]
    elif "--tests" in args:
        value = {"kind": "featurevisor.test-execution", "schemaVersion": 1, "tests": fixture["tests"]}
    elif args[0] == "build": value = fixture["datafile"]
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

    feature = %{
      "expectedToBeEnabled" => false,
      "expectedVariation" => "treatment",
      "expectedVariables" => %{"limit" => 99},
      "expectedEvaluations" => %{
        "flag" => %{"enabled" => false},
        "variation" => %{"variation" => %{"value" => "treatment"}},
        "variables" => %{"limit" => %{"variableValue" => 99}}
      }
    }

    variable = %{
      "expectedValue" => "wanted",
      "expectedEvaluation" => %{"variableValue" => "wanted"}
    }

    tests =
      for {type, key, expectation} <- [
            {"feature", "subject", Map.put(feature, "children", [feature])},
            {"variable", "message", Map.put(variable, "children", [variable])},
            {"segment", "all", %{"expectedToMatch" => false}}
          ] do
        %{
          "key" => key,
          type => key,
          "_test" => %{"source" => "tests/#{key}.json", "entityType" => type, "set" => nil},
          "assertions" => [
            Map.put(expectation, "_case", %{
              "id" => key,
              "assertionIndex" => 4,
              "matrixIndex" => nil,
              "matrixValues" => %{}
            })
          ]
        }
      end

    datafile = %{
      "schemaVersion" => "2",
      "revision" => "report",
      "segments" => %{},
      "features" => %{
        "subject" => %{
          "bucketBy" => "userId",
          "traffic" => [],
          "force" => [%{"segments" => "*", "enabled" => true, "variation" => "control"}],
          "variations" => [%{"value" => "control"}],
          "variablesSchema" => %{"limit" => %{"type" => "integer", "defaultValue" => 12}}
        }
      },
      "variables" => %{"message" => %{"type" => "string", "defaultValue" => "actual"}}
    }

    File.write!(
      Path.join(directory, "fixture.json"),
      Jason.encode!(%{"tests" => tests, "datafile" => datafile})
    )

    output =
      capture_io(fn ->
        assert {:error, _} =
                 Featurevisor.CLI.execute([
                   "test",
                   "--json",
                   "--projectDirectoryPath=#{directory}"
                 ])
      end)

    report = Jason.decode!(output)
    assert report["summary"]["entityAssertions"]["failed"] == 3
    [feature_result, variable_result, segment_result] = report["results"]
    feature_errors = hd(feature_result["cases"])["errors"]
    assert length(feature_errors) == 12

    for child <- [false, true] do
      base = ["assertions", 4] ++ if(child, do: ["children", 0], else: [])

      for {type, suffix, expected, actual} <- [
            {"flag", ["expectedToBeEnabled"], false, true},
            {"variation", ["expectedVariation"], "treatment", "control"},
            {"variable", ["expectedVariables", "limit"], 99, 12},
            {"evaluation", ["expectedEvaluations", "flag", "enabled"], false, true},
            {"evaluation", ["expectedEvaluations", "variation", "variation"],
             %{"value" => "treatment"}, %{"value" => "control"}},
            {"evaluation", ["expectedEvaluations", "variables", "limit", "variableValue"], 99, 12}
          ] do
        assert_error(feature_errors, type, base ++ suffix, expected, actual)
      end

      variable_errors = hd(variable_result["cases"])["errors"]
      assert length(variable_errors) == 4
      assert_error(variable_errors, "variable", base ++ ["expectedValue"], "wanted", "actual")

      assert_error(
        variable_errors,
        "evaluation",
        base ++ ["expectedEvaluation", "variableValue"],
        "wanted",
        "actual"
      )
    end

    segment_errors = hd(segment_result["cases"])["errors"]
    assert length(segment_errors) == 1
    assert_error(segment_errors, "segment", ["assertions", 4, "expectedToMatch"], false, true)
  end

  defp assert_error(errors, type, path, expected, actual) do
    error = Enum.find(errors, &(&1["path"] == path))
    assert error, inspect(path)
    assert error["type"] == type
    assert error["expected"] == expected
    assert error["actual"] == actual
    assert is_binary(error["message"])
  end
end
