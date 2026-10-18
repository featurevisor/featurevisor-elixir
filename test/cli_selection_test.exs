defmodule Featurevisor.CLI.SelectionTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  @moduletag skip: match?({:win32, _}, :os.type())

  @tag :tmp_dir
  test "evaluation commands delegate selections and propagate failures", %{tmp_dir: directory} do
    on_exit(fn -> File.rm_rf!(directory) end)
    for set <- ["alpha", "beta"], do: File.mkdir_p!(Path.join([directory, "sets", set]))

    executable = Path.join(directory, "npx")

    File.write!(executable, """
    #!/bin/sh
    printf '%s\\n' "$*" >> calls.log
    case "$2" in
      config) cat config.json ;;
      list)
        case "$*" in
          *--tests*) printf '%s\\n' '{"kind":"featurevisor.test-execution","schemaVersion":1,"tests":[{"key":"smoke","scenario":"smoke","_test":{"source":"tests/scenarios/smoke.spec.yml","set":null,"entityType":"scenario"},"assertions":[{"_case":{"id":"case-smoke","assertionIndex":0,"matrixIndex":null,"matrixValues":{}},"checks":[{"feature":"checkout","enabled":true}]}]}]}' ;;
          *) printf '%s\\n' '[]' ;;
        esac ;;
      build)
        case "$*" in
          *--target=bad*|*--set=bad*) echo 'delegated selection error' >&2; exit 7 ;;
        esac
        printf '%s\\n' '{"schemaVersion":"2","revision":"1","segments":{},"features":{"checkout":{"bucketBy":"userId","traffic":[{"key":"all","segments":"*","percentage":100000,"enabled":true}]}},"variables":{"subject":{"type":"string","defaultValue":"ready"}}}' ;;
      *) exit 8 ;;
    esac
    """)

    File.chmod!(executable, 0o755)
    old_path = System.get_env("PATH")
    System.put_env("PATH", directory <> ":" <> old_path)
    on_exit(fn -> System.put_env("PATH", old_path) end)
    sets = Jason.encode!(%{sets: true, setsDirectoryPath: Path.join(directory, "sets")})

    for command <- ["benchmark", "assess-distribution"],
        {name, config, args, success, builds, expected} <- [
          {"flat", "{}", [], true, 1, ""},
          {"configured", ~s({"environments":["production"]}), ["--environment=production"], true,
           1, "--environment=production"},
          {"missing environment", ~s({"environments":["production"]}), [], false, 0, ""},
          {"unknown environment", ~s({"environments":["production"]}), ["--environment=typo"],
           false, 0, ""},
          {"unexpected environment", "{}", ["--environment=production"], false, 0, ""},
          {"sets", sets, [], true, 2, "--set=beta"},
          {"selected set", sets, ["--set=alpha"], true, 1, "--set=alpha"},
          {"targets", sets, ["--set=alpha", "--target=web", "--target=mobile", "--target=web"],
           true, 2, "--target=mobile"},
          {"bad target", "{}", ["--target=bad"], false, 1, "--target=bad"},
          {"bad set", sets, ["--set=bad"], false, 1, "--set=bad"},
          {"zero n", "{}", ["--n=0"], false, 0, ""},
          {"zero inflate", "{}", ["--inflate=0"], false, 0, ""},
          {"array context", "{}", ["--context=[]"], false, 0, ""},
          {"null context", "{}", ["--context=null"], false, 0, ""},
          {"broken context", "{}", ["--context={"], false, 0, ""},
          {"broken config", "{", [], false, 0, ""}
        ] do
      File.write!(Path.join(directory, "config.json"), config)
      File.write!(Path.join(directory, "calls.log"), "")
      iterations = if Enum.any?(args, &String.starts_with?(&1, "--n=")), do: [], else: ["--n=1"]

      capture_io(fn ->
        result =
          Featurevisor.CLI.execute(
            [command, "--projectDirectoryPath=#{directory}", "--feature=checkout"] ++
              iterations ++ args
          )

        assert result == :ok == success, "#{command}/#{name}: #{inspect(result)}"
      end)

      calls = File.read!(Path.join(directory, "calls.log"))

      assert length(Regex.scan(~r/featurevisor build/, calls)) == builds,
             "#{command}/#{name}: #{calls}"

      assert String.contains?(calls, expected)
      if name == "flat", do: refute(String.contains?(calls, "--environment"))
    end

    File.write!(Path.join(directory, "config.json"), "{}")

    arguments =
      [[], ["--inflate"]] ++
        Enum.flat_map(["1", "2", "0", "-1", "1.5", "invalid", ""], fn value ->
          [["--inflate=#{value}"], ["--inflate", value]]
        end)

    for command <- ["benchmark", "assess-distribution", "test"], extra <- arguments do
      File.write!(Path.join(directory, "calls.log"), "")

      value =
        if extra == [], do: nil, else: String.replace_prefix(List.last(extra), "--inflate=", "")

      valid = value in [nil, "1", "2"]
      evaluation = if command == "test", do: [], else: ["--feature=checkout", "--n=1"]

      capture_io(fn ->
        result =
          Featurevisor.CLI.execute(
            [command, "--projectDirectoryPath=#{directory}"] ++ evaluation ++ extra
          )

        assert result == :ok == valid, "#{command}/#{inspect(extra)}: #{inspect(result)}"
        if not valid, do: assert(elem(result, 1) =~ "inflate")
      end)

      calls = File.read!(Path.join(directory, "calls.log"))

      if valid do
        assert length(Regex.scan(~r/featurevisor build/, calls)) == 1
        if extra == [], do: refute(String.contains?(calls, "--inflate"))
        if value == "2", do: assert(String.contains?(calls, "--inflate=2"))
      else
        assert calls == "", "invalid inflation reached Node: #{calls}"
      end
    end
  end
end
