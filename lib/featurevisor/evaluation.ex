defmodule Featurevisor.Evaluation do
  @moduledoc "Detailed result returned by Featurevisor evaluation functions."

  @type reason ::
          :feature_not_found
          | :disabled
          | :no_variations
          | :variation_disabled
          | :variable_not_found
          | :variable_default
          | :variable_disabled
          | :conditions_unmet
          | :variable_composed
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
    :conditions,
    :sticky_feature,
    :variation,
    :variation_value,
    :variable_key,
    :variable_value,
    :variable_schema,
    :variable,
    :variable_override_index,
    :variable_override_key,
    :variable_override_path,
    :variable_override_paths,
    __getter_value_normalized: false
  ]

  @doc "Converts an evaluation to its camelCase wire representation."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = evaluation) do
    evaluation
    |> Map.from_struct()
    |> Enum.reject(fn {key, value} ->
      key == :__getter_value_normalized or
        (is_nil(value) and not (key == :conditions and evaluation.reason == :conditions_unmet))
    end)
    |> Map.new(fn {key, value} ->
      value =
        if key in [:conditions, :traffic, :force, :variation, :variable],
          do: Featurevisor.Normalize.public(value),
          else: value

      {camelize(key), value}
    end)
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
  defp camelize(:variable_override_key), do: "variableOverrideKey"
  defp camelize(:variable_override_path), do: "variableOverridePath"
  defp camelize(:sticky_feature), do: "stickyFeature"
  defp camelize(:variable_override_paths), do: "variableOverridePaths"
  defp camelize(key), do: Atom.to_string(key)
end
