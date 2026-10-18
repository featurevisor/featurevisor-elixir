defmodule Featurevisor.CLI do
  @moduledoc "Featurevisor project test, benchmark, and distribution command line runner."

  alias Featurevisor.CLI.{AssessDistribution, Benchmark, TestRunner}

  @switches [
    projectDirectoryPath: :string,
    project_directory_path: :string,
    rootDirectoryPath: :string,
    root_directory_path: :string,
    environment: :string,
    target: :keep,
    set: :string,
    inflate: :integer,
    quiet: :boolean,
    verbose: :boolean,
    showDatafile: :boolean,
    show_datafile: :boolean,
    onlyFailures: :boolean,
    only_failures: :boolean,
    keyPattern: :string,
    key_pattern: :string,
    assertionPattern: :string,
    assertion_pattern: :string,
    entityType: :string,
    entity_type: :string,
    json: :boolean,
    pretty: :boolean,
    case: :string,
    coverage: :boolean,
    uncovered: :boolean,
    feature: :string,
    variation: :boolean,
    variable: :string,
    context: :string,
    n: :integer,
    populateUuid: :keep,
    populate_uuid: :keep,
    with_scopes: :boolean,
    withScopes: :boolean,
    with_tags: :boolean,
    withTags: :boolean,
    schemaVersion: :string,
    schema_version: :string,
    help: :boolean
  ]

  @option_aliases %{
    project_directory_path: :projectDirectoryPath,
    rootDirectoryPath: :projectDirectoryPath,
    root_directory_path: :projectDirectoryPath,
    show_datafile: :showDatafile,
    only_failures: :onlyFailures,
    key_pattern: :keyPattern,
    assertion_pattern: :assertionPattern,
    entity_type: :entityType,
    populate_uuid: :populateUuid,
    withScopes: :with_scopes,
    withTags: :with_tags
  }
  @common [
    :projectDirectoryPath,
    :target,
    :set,
    :inflate,
    :help,
    :with_scopes,
    :with_tags,
    :schemaVersion,
    :schema_version
  ]
  @command_options %{
    "test" => [
      :quiet,
      :verbose,
      :showDatafile,
      :onlyFailures,
      :keyPattern,
      :assertionPattern,
      :entityType,
      :json,
      :pretty,
      :case,
      :coverage,
      :uncovered
    ],
    "benchmark" => [:environment, :feature, :variation, :variable, :context, :n],
    "assess-distribution" => [:environment, :feature, :context, :n, :populateUuid, :verbose]
  }

  @doc "Escript entry point."
  def main(arguments) do
    :io.setopts(:standard_io, encoding: :unicode)
    :io.setopts(:standard_error, encoding: :unicode)

    case execute(arguments) do
      :ok ->
        :ok

      {:error, message} ->
        IO.puts(:stderr, "Error: #{message}")
        System.halt(1)
    end
  end

  @doc "Executes CLI arguments without halting the VM."
  def execute([]), do: help()
  def execute([flag]) when flag in ["--help", "-h"], do: help()

  def execute([command | arguments]) when is_map_key(@command_options, command) do
    switches =
      Enum.filter(@switches, fn {key, _} ->
        Map.get(@option_aliases, key, key) in (@common ++ @command_options[command])
      end)

    case OptionParser.parse(arguments, strict: switches, aliases: [n: :n, h: :help]) do
      {options, positionals, []} when positionals == [] ->
        dispatch(command, options |> canonical_options() |> normalize())

      {_options, _positionals, invalid} when invalid != [] ->
        {:error, "Unknown or invalid option #{inspect(hd(invalid))}"}

      {_options, positionals, _invalid} ->
        {:error, "Unexpected arguments: #{Enum.join(positionals, " ")}"}
    end
  end

  def execute([command | _]), do: {:error, "Unknown command #{inspect(command)}"}

  defp canonical_options(options) do
    Enum.reduce(options, [], fn {key, value}, acc ->
      key = Map.get(@option_aliases, key, key)

      if key in [:target, :populateUuid],
        do: acc ++ [{key, value}],
        else: Keyword.put(acc, key, value)
    end)
  end

  defp dispatch(command, %{help: true}), do: help(command)

  defp dispatch(command, %{feature: ""}) when command in ["benchmark", "assess-distribution"],
    do: {:error, "--feature must not be empty"}

  defp dispatch("benchmark", %{variable: ""}), do: {:error, "--variable must not be empty"}

  defp dispatch(command, %{inflate: inflate})
       when command in ["test", "benchmark", "assess-distribution"] and inflate <= 0,
       do: {:error, "--inflate must be a positive integer"}

  defp dispatch("test", %{pretty: true, json: false}), do: {:error, "--pretty requires --json"}

  defp dispatch("test", %{entity_type: type})
       when not is_nil(type) and type not in ["feature", "segment", "variable", "scenario"],
       do: {:error, "--entity-type must be feature, segment, variable or scenario"}

  defp dispatch("test", options), do: TestRunner.run(options)

  defp dispatch("benchmark", %{feature: nil, variable: nil}),
    do: {:error, "--feature or --variable is required"}

  defp dispatch("benchmark", %{n: n}) when n <= 0, do: {:error, "--n must be a positive integer"}

  defp dispatch("benchmark", %{variation: true, variable: variable}) when is_binary(variable),
    do: {:error, "--variation and --variable cannot be used together"}

  defp dispatch("benchmark", options), do: with_object_context(options, &Benchmark.run/1)
  defp dispatch("assess-distribution", %{feature: nil}), do: {:error, "--feature is required"}

  defp dispatch("assess-distribution", %{n: n}) when n <= 0,
    do: {:error, "--n must be a positive integer"}

  defp dispatch("assess-distribution", options),
    do: with_object_context(options, &AssessDistribution.run/1)

  defp dispatch(command, _), do: {:error, "Unknown command #{inspect(command)}"}

  defp with_object_context(options, callback) do
    case Jason.decode(options.context) do
      {:ok, value} when is_map(value) -> callback.(options)
      {:ok, _} -> {:error, "--context must be a JSON object"}
      {:error, error} -> {:error, "Could not parse --context: #{Exception.message(error)}"}
    end
  end

  defp normalize(options) do
    %{
      project_directory_path: Keyword.get(options, :projectDirectoryPath, "."),
      project_directory_path_argument: Keyword.get(options, :projectDirectoryPath),
      environment: Keyword.get(options, :environment),
      target: Keyword.get_values(options, :target),
      set: Keyword.get(options, :set),
      inflate: Keyword.get(options, :inflate, 1),
      quiet: Keyword.get(options, :quiet, false),
      verbose: Keyword.get(options, :verbose, false),
      show_datafile: Keyword.get(options, :showDatafile, false),
      only_failures: Keyword.get(options, :onlyFailures, false),
      key_pattern: Keyword.get(options, :keyPattern),
      assertion_pattern: Keyword.get(options, :assertionPattern),
      entity_type: Keyword.get(options, :entityType),
      json: Keyword.get(options, :json, false),
      pretty: Keyword.get(options, :pretty, false),
      case_id: Keyword.get(options, :case),
      coverage: Keyword.get(options, :coverage, false),
      uncovered: Keyword.get(options, :uncovered, false),
      feature: Keyword.get(options, :feature),
      variation: Keyword.get(options, :variation, false),
      variable: Keyword.get(options, :variable),
      context: Keyword.get(options, :context, "{}"),
      n: Keyword.get(options, :n, 1_000),
      populate_uuid: Keyword.get_values(options, :populateUuid),
      help: Keyword.get(options, :help, false)
    }
  end

  defp help(command \\ nil) do
    IO.puts("""
    Featurevisor SDK for Elixir

    Usage:
      featurevisor test [options]
      featurevisor benchmark --feature=<key> [--variation | --variable=<key>] [options]
      featurevisor assess-distribution --feature=<key> [options]

    Common options:
      --project-directory-path=<path>  Also --root-directory-path
      --set=<set>                    Omit to run all Sets
      --target=<target>              Repeat for multiple Targets
      --inflate=<number>

    Documentation: https://featurevisor.com/docs/sdks/elixir/
    """)

    case command do
      "test" ->
        IO.puts("""
        Test options:
          --key-pattern=<regex> --assertion-pattern=<regex>
          --entity-type=<feature|segment|variable|scenario>
          --only-failures --quiet --verbose --show-datafile
          --case=<id> --coverage --uncovered --json --pretty
        """)

      "benchmark" ->
        IO.puts(
          "Benchmark options: --feature=<key> --variable=<key> --variation --context=<json> --environment=<name> --n=<count> (or -n)"
        )

      "assess-distribution" ->
        IO.puts(
          "Distribution options: --feature=<key> --context=<json> --environment=<name> --n=<count> (or -n) --populate-uuid=<key> (repeatable) --verbose"
        )

      _ ->
        :ok
    end

    IO.puts(
      "CamelCase aliases remain supported. Authoring and datafile generation use the Node.js CLI."
    )

    :ok
  end
end
