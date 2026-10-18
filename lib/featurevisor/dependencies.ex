defmodule Featurevisor.Dependencies do
  @moduledoc false

  def entity("segments", value), do: visit(value["conditions"], MapSet.new())

  def entity("features", value) do
    result = selector(value, MapSet.new())
    result = Enum.reduce(value["force"] || [], result, &selector/2)

    Enum.reduce((value["traffic"] || []) ++ (value["variations"] || []), result, fn entry,
                                                                                    result ->
      (entry["variableOverrides"] || %{})
      |> Map.values()
      |> List.flatten()
      |> Enum.reduce(selector(entry, result), &selector/2)
    end)
  end

  def entity("variables", value) do
    result = selector(value, MapSet.new())

    result =
      case value["compose"] do
        key when is_binary(key) -> MapSet.put(result, {"variables", key})
        entries when is_list(entries) -> Enum.reduce(entries, result, &reference/2)
        _ -> result
      end

    Enum.reduce(value["overrideProgram"] || value["overrides"] || [], result, &selector/2)
  end

  defp selector(entry, result), do: visit(entry["conditions"], result)
  defp visit("*", result), do: result

  defp visit(value, result) when is_binary(value) do
    if Featurevisor.Normalize.stringified?(value) do
      case Jason.decode(value) do
        {:ok, decoded} -> visit(decoded, result)
        _ -> result
      end
    else
      MapSet.put(result, {"segments", value})
    end
  end

  defp visit(values, result) when is_list(values), do: Enum.reduce(values, result, &visit/2)
  defp visit(%{"variable" => _} = value, result), do: reference(value, result)
  defp visit(%{"feature" => _} = value, result), do: reference(value, result)
  defp visit(%{"attribute" => _}, result), do: result

  defp visit(value, result) when is_map(value) do
    Enum.reduce(["and", "or", "not"], result, fn name, result -> visit(value[name], result) end)
  end

  defp visit(_, result), do: result
  defp reference(%{"feature" => key}, result), do: MapSet.put(result, {"features", key})
  defp reference(%{"variable" => key}, result), do: MapSet.put(result, {"variables", key})
end
