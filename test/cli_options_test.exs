defmodule Featurevisor.CLI.OptionsTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  @moduletag skip: match?({:win32, _}, :os.type())

  setup %{tmp_dir: root} do
    on_exit(fn -> File.rm_rf!(root) end)
    directory = Path.join(root, "project 'quoted' $path")
    File.mkdir_p!(directory)
    executable = Path.join(directory, "npx")
    File.cp!(Path.join(__DIR__, "support/cli_npx.sh"), executable)
    File.chmod!(executable, 0o755)
    File.write!(Path.join(directory, "calls.log"), "")
    path = System.get_env("PATH")
    System.put_env("PATH", directory <> ":" <> path)
    on_exit(fn -> System.put_env("PATH", path) end)
    %{directory: directory}
  end

  @moduletag :tmp_dir

  defp value_option(name, value, true), do: ["--#{name}=#{value}"]
  defp value_option(name, value, false), do: ["--#{name}", value]

  defp run(args) do
    ref = make_ref()

    stderr =
      capture_io(:stderr, fn ->
        stdout = capture_io(fn -> assert :ok = Featurevisor.CLI.execute(args) end)
        send(self(), {ref, stdout})
      end)

    unless Enum.any?(args, &(&1 in ["--help", "-h"])),
      do: assert(stderr =~ "delegated warning")

    assert_receive {^ref, stdout}
    stdout
  end

  defp calls(directory), do: File.read!(Path.join(directory, "calls.log"))
  defp clear(directory), do: File.write!(Path.join(directory, "calls.log"), "")

  test "test aliases and directory forms preserve reports and target order", %{
    directory: directory
  } do
    for path <- [
          "projectDirectoryPath",
          "project-directory-path",
          "rootDirectoryPath",
          "root-directory-path"
        ],
        equals <- [false, true],
        camel <- [false, true] do
      clear(directory)

      names =
        if camel,
          do: ["keyPattern", "assertionPattern", "entityType", "onlyFailures", "showDatafile"],
          else: [
            "key-pattern",
            "assertion-pattern",
            "entity-type",
            "only-failures",
            "show-datafile"
          ]

      [key, assertion, entity, failures, datafile] = names

      args =
        [
          "test",
          "--json",
          "--#{failures}",
          "--#{datafile}",
          "--target=space target",
          "--target",
          "web",
          "--target=space target"
        ] ++
          value_option(path, directory, equals) ++
          value_option(key, "^smoke$", equals) ++
          value_option(assertion, "^ready$", equals) ++ value_option(entity, "scenario", equals)

      report = args |> run() |> Jason.decode!()
      assert report["passed"]
      assert report["summary"]["assertions"]["passed"] > 0

      targets =
        calls(directory)
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "--target="))

      assert targets == ["--target=space target", "--target=web"]
      assert calls(directory) =~ "--entityType=scenario\n"
    end
  end

  test "numeric forms and UUID aliases preserve context and repeated selectors", %{
    directory: directory
  } do
    context = %{"country" => "Café 'quoted' $HOME; space", "nested" => %{"x" => "a b"}}

    for command <- ["benchmark", "assess-distribution"],
        n <- [["--n=2"], ["--n", "2"], ["-n=2"], ["-n", "2"]] do
      clear(directory)

      extra =
        if command == "assess-distribution",
          do: [
            "--verbose",
            "--populateUuid=first",
            "--populate-uuid",
            "second",
            "--populate-uuid=third",
            "--populateUuid",
            "fourth"
          ],
          else: []

      args =
        [
          command,
          "--root-directory-path",
          directory,
          "--feature=checkout",
          "--context",
          Jason.encode!(context),
          "--target=space target",
          "--target",
          "web",
          "--target=space target"
        ] ++ n ++ extra

      output = run(args)
      assert output =~ "Iterations: 2"
      assert output =~ "Environment: false"

      contexts =
        output |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "Context: "))

      for line <- contexts do
        actual = line |> String.replace_prefix("Context: ", "") |> Jason.decode!()
        assert Map.take(actual, Map.keys(context)) == context

        if command == "assess-distribution" do
          for key <- ["first", "second", "third", "fourth"], do: assert(is_binary(actual[key]))
        end
      end

      assert length(contexts) == if(command == "benchmark", do: 2, else: 4)

      targets =
        calls(directory)
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "--target="))

      assert targets == ["--target=space target", "--target=web"]
    end
  end

  test "invalid and irrelevant options do not delegate", %{directory: directory} do
    for args <- [
          ["benchmark", "--feature="],
          ["benchmark", "--variable="],
          ["assess-distribution", "--feature="]
        ] do
      assert {:error, message} = Featurevisor.CLI.execute(args)
      assert message =~ "empty"
    end

    for args <- [
          ["test", "--entity-type=unknown"],
          ["test", "--feature=ignored"],
          ["test", "--environment=ignored"],
          ["test", "--target"],
          ["test", "--unknown"],
          ["test", "--only-failures", "extra"],
          ["test", "--pretty"],
          ["test", "--n=2"],
          ["benchmark", "--feature=flag", "--json"],
          ["benchmark", "--feature=flag", "--only-failures"],
          ["assess-distribution", "--feature=flag", "--variable=ignored"],
          ["assess-distribution", "--feature=flag", "--populate-uuid"],
          ["assess-distribution", "--feature=flag", "--populate-uuid=a", "ignored"]
        ] do
      assert {:error, _} =
               Featurevisor.CLI.execute(args ++ ["--project-directory-path", directory])
    end

    for command <- ["benchmark", "assess-distribution"],
        value <- ["0", "-1", "1.5", "invalid", ""],
        equals <- [false, true] do
      assert {:error, _} =
               Featurevisor.CLI.execute(
                 [command, "--feature=flag"] ++ value_option("n", value, equals)
               )
    end

    for option <- ["key-pattern", "assertion-pattern"] do
      output =
        capture_io(fn ->
          assert {:error, message} = Featurevisor.CLI.execute(["test", "--json", "--#{option}=["])
          assert message =~ "Invalid"
        end)

      assert Jason.decode!(output)["passed"] == false
    end

    assert calls(directory) == ""
  end

  test "root and scoped help do not delegate", %{directory: directory} do
    for command <- [[], ["test"], ["benchmark"], ["assess-distribution"]],
        flag <- ["--help", "-h"] do
      output = run(command ++ [flag])
      assert output =~ "Usage:"
      assert output =~ "--project-directory-path"
      assert output =~ "Node.js"
    end

    assert {:error, _} = Featurevisor.CLI.execute(["unknown", "--help"])
    assert calls(directory) == ""
  end
end
