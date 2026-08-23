defmodule Featurevisor.CLI do
  @moduledoc "Featurevisor project test, benchmark, and distribution command line runner."

  alias Featurevisor.CLI.{AssessDistribution, Benchmark, TestRunner}

  @switches [
    projectDirectoryPath: :string,
    environment: :string,
    target: :string,
    inflate: :integer,
    quiet: :boolean,
    verbose: :boolean,
    showDatafile: :boolean,
    onlyFailures: :boolean,
    keyPattern: :string,
    assertionPattern: :string,
    feature: :string,
    variation: :boolean,
    variable: :string,
    context: :string,
    n: :integer,
    populateUuid: :string,
    with_scopes: :boolean,
    with_tags: :boolean,
    schemaVersion: :string,
    schema_version: :string,
    help: :boolean
  ]

  @doc "Escript entry point."
  def main(arguments) do
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

  def execute([command | arguments]) do
    case OptionParser.parse(arguments, strict: @switches) do
      {options, positionals, []} when positionals == [] ->
        dispatch(command, normalize(options))

      {_options, _positionals, invalid} when invalid != [] ->
        {:error, "Unknown or invalid option #{inspect(hd(invalid))}"}

      {_options, positionals, _invalid} ->
        {:error, "Unexpected arguments: #{Enum.join(positionals, " ")}"}
    end
  end

  defp dispatch(_command, %{help: true}), do: help()
  defp dispatch("test", options), do: TestRunner.run(options)
  defp dispatch("benchmark", %{feature: nil}), do: {:error, "--feature is required"}
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
      environment: Keyword.get(options, :environment),
      target: Keyword.get_values(options, :target),
      inflate: Keyword.get(options, :inflate, 1),
      quiet: Keyword.get(options, :quiet, false),
      verbose: Keyword.get(options, :verbose, false),
      show_datafile: Keyword.get(options, :showDatafile, false),
      only_failures: Keyword.get(options, :onlyFailures, false),
      key_pattern: Keyword.get(options, :keyPattern),
      assertion_pattern: Keyword.get(options, :assertionPattern),
      feature: Keyword.get(options, :feature),
      variation: Keyword.get(options, :variation, false),
      variable: Keyword.get(options, :variable),
      context: Keyword.get(options, :context, "{}"),
      n: Keyword.get(options, :n, 1_000),
      populate_uuid: Keyword.get_values(options, :populateUuid),
      help: Keyword.get(options, :help, false)
    }
  end

  defp help do
    IO.puts("""
    Featurevisor SDK for Elixir

    Usage:
      featurevisor test [options]
      featurevisor benchmark --feature=<key> [--variation | --variable=<key>] [options]
      featurevisor assess-distribution --feature=<key> [options]

    Common options:
      --projectDirectoryPath=<path>
      --environment=<environment>
      --target=<target>              Repeat for multiple Targets
      --inflate=<number>

    Documentation: https://featurevisor.com/docs/sdks/elixir/
    """)

    :ok
  end
end
