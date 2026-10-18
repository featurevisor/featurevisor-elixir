defmodule Featurevisor.CLI.Segments do
  @moduledoc false
  alias Featurevisor.{Dependencies, Normalize}

  def empty do
    %{
      "schemaVersion" => "4",
      "revision" => "tester",
      "segments" => %{},
      "features" => %{},
      "variables" => %{}
    }
  end

  def prepare(datafile, definitions) do
    segments = Map.merge(definitions, datafile["segments"] || %{})

    {features, keys} =
      Enum.reduce(Map.keys(definitions), {datafile["features"] || %{}, %{}}, fn key,
                                                                                {features, keys} ->
        helper = available("__featurevisor_segment_test__" <> key, features)

        feature = %{
          "bucketBy" => "__segment_test__",
          "conditions" => key,
          "traffic" => [%{"key" => "segment", "conditions" => "*", "percentage" => 100_000}]
        }

        {Map.put(features, helper, feature), Map.put(keys, key, helper)}
      end)

    {datafile |> Map.put("segments", segments) |> Map.put("features", features), keys}
  end

  def preflight(key, datafile, definitions),
    do: references([{"segments", key, nil}], %{}, datafile, definitions)

  def dependent?(key, definitions) do
    dependent?([key], %{}, definitions)
  end

  defp dependent?([], _seen, _definitions), do: false

  defp dependent?([key | rest], seen, definitions) do
    if Map.has_key?(seen, key) do
      dependent?(rest, seen, definitions)
    else
      dependencies = Dependencies.entity("segments", definitions[key] || %{})

      Enum.any?(dependencies, fn {kind, _} -> kind != "segments" end) or
        dependent?(
          rest ++ for({"segments", key} <- dependencies, do: key),
          Map.put(seen, key, true),
          definitions
        )
    end
  end

  defp references([], _seen, _datafile, _definitions), do: :ok

  defp references([{kind, key, variable} = reference | rest], seen, datafile, definitions) do
    if Map.has_key?(seen, reference) do
      references(rest, seen, datafile, definitions)
    else
      raw =
        if kind == "segments",
          do: definitions[key] || datafile["segments"][key],
          else: datafile[kind][key]

      cond do
        is_nil(raw) ->
          {:error,
           "#{label(kind)} #{inspect(key)} is absent from the selected datafile and test definitions"}

        kind == "features" and not is_nil(variable) and
            not Map.has_key?(raw["variablesSchema"] || %{}, variable) ->
          {:error,
           "Feature variable #{inspect(key <> "." <> variable)} is absent from the selected datafile"}

        true ->
          {entity, _errors} = Normalize.entity(kind, key, raw, datafile["schemaVersion"] == "2")

          entity = if kind == "features", do: filter_feature(entity, variable), else: entity
          dependencies = Dependencies.entity(kind, entity)

          pending = Enum.map(dependencies, fn {kind, key} -> {kind, key, nil} end)
          pending = pending ++ feature_variable_references(entity)
          references(rest ++ pending, Map.put(seen, reference, true), datafile, definitions)
      end
    end
  end

  defp filter_feature(feature, variable) do
    feature =
      if is_nil(variable) do
        Map.put(feature, "variations", [])
        |> Map.update("traffic", [], fn entries ->
          Enum.map(entries, &Map.delete(&1, "variableOverrides"))
        end)
      else
        Enum.reduce(["traffic", "variations"], feature, fn kind, feature ->
          Map.update(feature, kind, [], fn entries ->
            Enum.map(entries, fn entry ->
              Map.update(entry, "variableOverrides", %{}, &Map.take(&1, [variable]))
            end)
          end)
        end)
      end

    feature
  end

  defp feature_variable_references(%{"feature" => feature, "variable" => variable}),
    do: [{"features", feature, variable}]

  defp feature_variable_references(value) when is_map(value) do
    value
    |> Map.drop([
      "value",
      "defaultValue",
      "disabledValue",
      "operations",
      "variablesSchema",
      "variables"
    ])
    |> Map.values()
    |> Enum.flat_map(&feature_variable_references/1)
  end

  defp feature_variable_references(values) when is_list(values),
    do: Enum.flat_map(values, &feature_variable_references/1)

  defp feature_variable_references(_), do: []

  defp label("segments"), do: "Segment"
  defp label("features"), do: "Feature"
  defp label("variables"), do: "Global variable"

  defp available(key, features),
    do: if(Map.has_key?(features, key), do: available(key <> "_", features), else: key)
end
