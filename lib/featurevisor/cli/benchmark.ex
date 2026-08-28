defmodule Featurevisor.CLI.Benchmark do
  @moduledoc false
  alias Featurevisor.CLI.Project

  def run(options) do
    targets = if options.target == [], do: [nil], else: Enum.uniq(options.target)

    Enum.reduce_while(targets, :ok, fn target, :ok ->
      case Project.build(
             options.project_directory_path,
             options.environment,
             target,
             options.inflate
           ) do
        {:ok, datafile} ->
          f = Featurevisor.create_featurevisor(%{datafile: datafile, log_level: :fatal})
          context = Jason.decode!(options.context)
          evaluator = evaluator(f, options, context)
          value = evaluator.()
          durations = for _ <- 1..options.n, do: timed(evaluator)
          total = Enum.sum(durations)

          IO.puts(
            "\nBenchmark Featurevisor #{if options.feature, do: "feature", else: "variable"}"
          )

          if options.feature, do: IO.puts("Feature: #{options.feature}")
          if is_nil(options.feature), do: IO.puts("Variable: #{options.variable}")
          IO.puts("Environment: #{options.environment || false}")
          if target, do: IO.puts("Target: #{target}")
          IO.puts("Iterations: #{options.n}")
          IO.puts("Context: #{Jason.encode!(context)}")
          IO.puts("Evaluated value: #{Jason.encode!(value)}")
          IO.puts("Total duration: #{format(total)}")
          IO.puts("Minimum duration: #{format(Enum.min(durations))}")
          IO.puts("Average duration: #{format(total / options.n)}")
          IO.puts("Maximum duration: #{format(Enum.max(durations))}")
          Featurevisor.close(f)
          {:cont, :ok}

        error ->
          {:halt, error}
      end
    end)
  end

  defp evaluator(f, %{variable: variable, feature: feature}, context) when is_binary(variable),
    do:
      if(is_binary(feature),
        do: fn -> Featurevisor.get_variable(f, feature, variable, context) end,
        else: fn -> Featurevisor.get_global_variable(f, variable, context) end
      )

  defp evaluator(f, %{variation: true, feature: feature}, context),
    do: fn -> Featurevisor.get_variation(f, feature, context) end

  defp evaluator(f, %{feature: feature}, context),
    do: fn -> Featurevisor.enabled?(f, feature, context) end

  defp timed(fun) do
    started = System.monotonic_time(:nanosecond)
    fun.()
    System.monotonic_time(:nanosecond) - started
  end

  defp format(nanoseconds),
    do: :erlang.float_to_binary(nanoseconds / 1_000_000, decimals: 6) <> "ms"
end
