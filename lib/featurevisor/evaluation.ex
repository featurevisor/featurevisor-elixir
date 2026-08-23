defmodule Featurevisor.Evaluation do
  @moduledoc "Detailed result returned by Featurevisor evaluation functions."

  @type reason ::
          :feature_not_found
          | :disabled
          | :required
          | :out_of_range
          | :no_variations
          | :variation_disabled
          | :variable_not_found
          | :variable_default
          | :variable_disabled
          | :variable_override_variation
          | :variable_override_rule
          | :no_match
          | :forced
          | :sticky
          | :rule
          | :allocated
          | :error

  @type t :: %__MODULE__{}
  defstruct [
    :type,
    :feature_key,
    :reason,
    :bucket_key,
    :bucket_value,
    :rule_key,
    :error,
    :enabled,
    :traffic,
    :force_index,
    :force,
    :required,
    :sticky,
    :variation,
    :variation_value,
    :variable_key,
    :variable_value,
    :variable_schema,
    :variable_override_index
  ]

  @doc "Converts an evaluation to its camelCase wire representation."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = evaluation) do
    evaluation
    |> Map.from_struct()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {camelize(key), value} end)
  end

  defp camelize(:feature_key), do: "featureKey"
  defp camelize(:bucket_key), do: "bucketKey"
  defp camelize(:bucket_value), do: "bucketValue"
  defp camelize(:rule_key), do: "ruleKey"
  defp camelize(:force_index), do: "forceIndex"
  defp camelize(:variation_value), do: "variationValue"
  defp camelize(:variable_key), do: "variableKey"
  defp camelize(:variable_value), do: "variableValue"
  defp camelize(:variable_schema), do: "variableSchema"
  defp camelize(:variable_override_index), do: "variableOverrideIndex"
  defp camelize(key), do: Atom.to_string(key)
end
