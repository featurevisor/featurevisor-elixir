defmodule Featurevisor.CLI.TestCoverage do
  @moduledoc false

  alias Featurevisor.{Evaluation, Module}

  def open(false), do: nil

  def open(true) do
    :ets.new(:featurevisor_cli_test_coverage, [
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])
  end

  def close(nil), do: :ok

  def close(table) do
    if :ets.info(table) != :undefined, do: :ets.delete(table)
    :ok
  end

  def module(table, metadata, synthetic \\ [])
  def module(nil, _metadata, _synthetic), do: nil

  def module(table, metadata, synthetic) do
    %Module{
      name: "tester-coverage",
      after_evaluation: fn evaluation, _options ->
        unless evaluation.feature_key in synthetic, do: observe(table, metadata, evaluation)
        evaluation
      end
    }
  end

  def selections(nil), do: []

  def selections(table) do
    table
    |> :ets.tab2list()
    |> Enum.map(fn {_key, selection} -> selection end)
    |> Enum.sort_by(&Jason.encode!/1)
  end

  defp observe(table, metadata, %Evaluation{} = evaluation) do
    paths =
      cond do
        is_list(evaluation.variable_override_paths) and
            evaluation.variable_override_paths != [] ->
          evaluation.variable_override_paths

        is_list(evaluation.variable_override_path) ->
          [evaluation.variable_override_path]

        is_binary(evaluation.variable_override_key) ->
          [[evaluation.variable_override_key]]

        is_integer(evaluation.variable_override_index) ->
          [nil]

        true ->
          []
      end

    if is_binary(evaluation.rule_key) or paths != [] do
      paths = if paths == [], do: [nil], else: paths

      Enum.each(paths, fn path ->
        selection =
          metadata
          |> maybe_put("featureKey", evaluation.feature_key)
          |> maybe_put("variableKey", evaluation.variable_key)
          |> maybe_put("ruleKey", evaluation.rule_key)
          |> maybe_put("overridePath", path)
          |> maybe_put("overrideIndex", if(is_nil(path), do: evaluation.variable_override_index))
          |> maybe_put(
            "variation",
            if(is_map(evaluation.variation), do: evaluation.variation["value"])
          )

        :ets.insert(table, {Jason.encode!(selection), selection})
      end)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
