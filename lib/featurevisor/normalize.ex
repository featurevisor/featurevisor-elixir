defmodule Featurevisor.Normalize do
  @moduledoc false

  @invalid :invalid_conditions
  @kinds ["features", "segments", "variables"]

  def datafile(datafile) do
    if datafile["schemaVersion"] == "2" do
      Enum.reduce(@kinds, {datafile, []}, fn kind, {result, errors} ->
        {definitions, errors} =
          Enum.reduce(datafile[kind] || %{}, {%{}, errors}, fn {key, value}, {values, errors} ->
            {value, found} = entity(kind, key, value, true)
            {Map.put(values, key, value), errors ++ found}
          end)

        {Map.put(result, kind, definitions), errors}
      end)
    else
      {datafile, []}
    end
  end

  def get(datafile, kind, key, nil, _report), do: datafile[kind][key]

  def get(_datafile, kind, key, cache, report) do
    cache_key = {:normalized, kind, key}

    case :ets.lookup(cache, cache_key) do
      [{_, value}] ->
        value

      [] ->
        case Featurevisor.DatafileStore.entity(cache, kind, key) do
          nil ->
            nil

          {token, raw} ->
            [{_, shared}] = :ets.lookup(cache, :normalization_cache)

            case :ets.lookup(shared, token) do
              [{_, value}] ->
                :ets.insert_new(cache, {cache_key, value})
                value

              [] ->
                {value, errors} = entity(kind, key, raw)
                first = :ets.insert_new(shared, {token, value})
                :ets.insert_new(cache, {cache_key, value})
                if first, do: Enum.each(errors, report)
                value
            end
        end
    end
  end

  def entity(kind, key, value, legacy \\ false) do
    parse = fn conditions -> parse(conditions, kind, key) end

    case kind do
      "segments" ->
        {conditions, errors} = parse.(value["conditions"])

        {Map.put(value, "conditions", if(legacy, do: legacy(conditions), else: conditions)),
         errors}

      "features" ->
        {value, errors} = select(value, false, parse)

        {traffic, errors} =
          entries(value["traffic"] || [], errors, fn entry ->
            {entry, errors} = select(entry, false, parse)
            {entry, found} = overrides(entry, legacy, parse)
            {entry, errors ++ found}
          end)

        {force, errors} = entries(value["force"] || [], errors, &select(&1, legacy, parse))

        {variations, errors} =
          entries(value["variations"] || [], errors, &overrides(&1, legacy, parse))

        value = Map.put(value, "traffic", traffic)
        value = if Map.has_key?(value, "force"), do: Map.put(value, "force", force), else: value

        value =
          if Map.has_key?(value, "variations"),
            do: Map.put(value, "variations", variations),
            else: value

        {value, errors}

      "variables" ->
        {value, errors} = select(value, false, parse)

        Enum.reduce(
          [{"overrides", legacy}, {"overrideProgram", false}],
          {value, errors},
          fn {name, old}, {value, errors} ->
            if is_list(value[name]) do
              {items, errors} = entries(value[name], errors, &select(&1, old, parse))
              {Map.put(value, name, items), errors}
            else
              {value, errors}
            end
          end
        )
    end
  end

  defp overrides(entry, old, parse) do
    Enum.reduce(entry["variableOverrides"] || %{}, {entry, []}, fn {key, values},
                                                                   {entry, errors} ->
      {values, errors} = entries(values, errors, &select(&1, old, parse))
      {put_in(entry, ["variableOverrides", key], values), errors}
    end)
  end

  defp entries(values, errors, fun) do
    Enum.map_reduce(values, errors, fn entry, errors ->
      {entry, found} = fun.(entry)
      {entry, errors ++ found}
    end)
  end

  defp select(value, old, parse) do
    {parts, errors} =
      Enum.reduce(["conditions", "segments"], {[], []}, fn name, {parts, errors} ->
        if Map.has_key?(value, name) do
          {parsed, found} = parse.(value[name])
          parsed = if old or name == "segments", do: legacy(parsed), else: parsed
          {parts ++ [parsed], errors ++ found}
        else
          {parts, errors}
        end
      end)

    features = value["requiredFeatures"]

    features =
      if is_list(features), do: features, else: if(is_nil(features), do: [], else: [features])

    parts = if features == [], do: parts, else: parts ++ [Enum.map(features, &legacy_feature/1)]
    value = Map.drop(value, ["segments", "requiredFeatures", "requiredVariables", "required"])

    conditions =
      case parts do
        [] ->
          nil

        [part] ->
          part

        parts ->
          if @invalid in parts,
            do: @invalid,
            else:
              Enum.flat_map(parts, fn
                [] -> [%{"and" => []}]
                part when is_list(part) -> part
                part -> [part]
              end)
      end

    {if(parts == [], do: value, else: Map.put(value, "conditions", conditions)), errors}
  end

  defp legacy_feature(value) when is_binary(value), do: %{"feature" => value}
  defp legacy_feature(%{"feature" => _} = value), do: value
  defp legacy_feature(%{"and" => []}), do: "*"

  defp legacy_feature(value) when is_map(value) do
    Map.new(value, fn {key, children} -> {key, Enum.map(children, &legacy_feature/1)} end)
  end

  defp legacy([]), do: "*"
  defp legacy(%{"and" => []}), do: "*"
  defp legacy(values) when is_list(values), do: Enum.map(values, &legacy/1)

  defp legacy(value) when is_map(value) do
    Enum.reduce(["and", "or", "not"], value, fn key, value ->
      if is_list(value[key]),
        do: Map.update!(value, key, &Enum.map(&1, fn child -> legacy(child) end)),
        else: value
    end)
  end

  defp legacy(value), do: value

  def public(:invalid_conditions), do: %{"or" => []}
  def public(value) when is_list(value), do: Enum.map(value, &public/1)

  def public(value) when is_map(value),
    do: Map.new(value, fn {key, value} -> {key, public(value)} end)

  def public(value), do: value

  def stringified?(value), do: is_binary(value) and Regex.match?(~r/^\s*[\{\[\"]/, value)

  defp parse(value, kind, key) do
    if stringified?(value) do
      case Jason.decode(value) do
        {:ok, parsed} ->
          {parsed, []}

        {:error, error} ->
          {@invalid,
           [
             %{
               level: :error,
               code: "conditions_parse_error",
               message: "Error parsing conditions",
               originalError: error,
               details: %{
                 conditions: value,
                 entityType: String.trim_trailing(kind, "s"),
                 entityKey: key
               }
             }
           ]}
      end
    else
      {value, []}
    end
  end
end
