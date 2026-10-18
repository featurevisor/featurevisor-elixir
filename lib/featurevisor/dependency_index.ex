defmodule Featurevisor.DependencyIndex do
  @moduledoc false
  @kinds ["features", "variables", "segments"]

  def new(datafile), do: add(%{reverse: %{}, owners: %{}}, datafile)

  def update(index, previous, current, nil) do
    Enum.reduce(@kinds, index, fn kind, index ->
      old = previous[kind] || %{}
      new = current[kind] || %{}

      index =
        Enum.reduce(old, index, fn {key, _}, index ->
          if Map.has_key?(new, key), do: index, else: remove(index, {kind, key})
        end)

      update_entities(index, kind, old, new)
    end)
  end

  def update(index, previous, _current, incoming) do
    Enum.reduce(@kinds, index, fn kind, index ->
      update_entities(index, kind, previous[kind] || %{}, incoming[kind] || %{})
    end)
  end

  defp update_entities(index, kind, previous, incoming) do
    Enum.reduce(incoming, index, fn {key, entity}, index ->
      # Hashes do not identify edges. Reuse only an identical definition.
      if Map.has_key?(index.owners, {kind, key}) and previous[key] === entity do
        index
      else
        index |> remove({kind, key}) |> add_entity(kind, key, entity)
      end
    end)
  end

  defp add(index, datafile) do
    Enum.reduce(@kinds, index, fn kind, index ->
      Enum.reduce(datafile[kind] || %{}, index, fn {key, entity}, index ->
        add_entity(index, kind, key, entity)
      end)
    end)
  end

  defp add_entity(index, kind, key, entity) do
    owner = {kind, key}
    edges = Featurevisor.Dependencies.entity(kind, entity)

    reverse =
      Enum.reduce(edges, index.reverse, fn edge, reverse ->
        Map.update(reverse, edge, MapSet.new([owner]), &MapSet.put(&1, owner))
      end)

    %{reverse: reverse, owners: Map.put(index.owners, owner, edges)}
  end

  defp remove(index, owner) do
    reverse =
      Enum.reduce(Map.get(index.owners, owner, []), index.reverse, fn edge, reverse ->
        remaining = MapSet.delete(Map.fetch!(reverse, edge), owner)

        if MapSet.size(remaining) == 0,
          do: Map.delete(reverse, edge),
          else: Map.put(reverse, edge, remaining)
      end)

    %{reverse: reverse, owners: Map.delete(index.owners, owner)}
  end
end
