defmodule Featurevisor.DatafileStore do
  @moduledoc false
  use GenServer

  # A separate owner lets an in progress evaluation finish after instance
  # shutdown. BEAM releases table fixations automatically if a reader dies.
  def start(owner), do: GenServer.start(__MODULE__, owner)

  def create(pid, datafile, previous \\ nil, incoming \\ nil) do
    input = if previous, do: incoming, else: datafile
    GenServer.call(pid, {:create, input, previous}, :infinity)
  end

  def retire(pid, table), do: GenServer.cast(pid, {:retire, table})

  # Each snapshot has a small read cache. Immutable entity versions live in a
  # shared ordered table, so publishing a partial snapshot writes only its input.
  def entity(table, kind, key) do
    case :ets.lookup(table, {:entity, kind, key}) do
      [{_, slot}] -> slot
      [] -> read_entity(table, kind, key)
    end
  end

  defp read_entity(table, kind, key) do
    [{_, {entities, generation, first}}] = :ets.lookup(table, :entities)

    case :ets.prev(entities, {kind, key, generation + 1}) do
      {^kind, ^key, version} = row when version >= first ->
        slot = :ets.lookup_element(entities, row, 2)
        :ets.insert_new(table, {{:entity, kind, key}, slot})
        slot

      _ ->
        nil
    end
  end

  def materialize(table, kind) do
    [{_, {entities, generation, first}}] = :ets.lookup(table, :entities)

    entities
    |> :ets.select([
      {{{kind, :"$1", :"$2"}, {:_, :"$3"}}, [{:>=, :"$2", first}, {:"=<", :"$2", generation}],
       [{{:"$1", :"$2", :"$3"}}]}
    ])
    |> Enum.reduce(%{}, fn {key, version, value}, values ->
      Map.update(values, key, {version, value}, fn {old, _} = slot ->
        if version > old, do: {version, value}, else: slot
      end)
    end)
    |> Map.new(fn {key, {_, value}} -> {key, value} end)
  end

  def keys(table, kind) do
    [{_, {entities, generation, first}}] = :ets.lookup(table, :entities)

    entities
    |> :ets.select([
      {{{kind, :"$1", :"$2"}, :_}, [{:>=, :"$2", first}, {:"=<", :"$2", generation}], [:"$1"]}
    ])
    |> Enum.uniq()
  end

  @impl true
  def init(owner) do
    Process.monitor(owner)

    normalized =
      :ets.new(__MODULE__, [:set, :public, read_concurrency: true, write_concurrency: true])

    entities = :ets.new(__MODULE__, [:ordered_set, :protected, read_concurrency: true])

    {:ok,
     %{
       tables: [],
       retired: [],
       owner: owner,
       timer: nil,
       normalized: normalized,
       entities: entities,
       generation: 0,
       current: %{},
       obsolete: %{}
     }}
  end

  @impl true
  def handle_call({:create, datafile, previous}, _from, state) do
    table = :ets.new(__MODULE__, [:set, :public, read_concurrency: true, write_concurrency: true])
    generation = state.generation + 1

    first =
      if previous do
        [{_, {_, _, first}}] = :ets.lookup(previous, :entities)
        first
      else
        generation
      end

    :ets.insert(table, {:normalization_cache, state.normalized})
    :ets.insert(table, {:entities, {state.entities, generation, first}})

    {current, obsolete} =
      if previous,
        do: {state.current, state.obsolete},
        else: {%{}, retire_entities(state.current, state.obsolete, generation)}

    {current, obsolete} =
      Enum.reduce(["features", "variables", "segments"], {current, obsolete}, fn kind, slots ->
        Enum.reduce(datafile[kind] || %{}, slots, fn {key, value}, {current, obsolete} ->
          obsolete =
            case Map.fetch(current, {kind, key}) do
              {:ok, version} -> Map.put(obsolete, {kind, key, version}, generation)
              :error -> obsolete
            end

          insert_entity(state.entities, {kind, key, generation}, value)
          {Map.put(current, {kind, key}, generation), obsolete}
        end)
      end)

    {:reply, table,
     %{
       state
       | tables: [table | state.tables],
         generation: generation,
         current: current,
         obsolete: obsolete
     }, :hibernate}
  end

  defp insert_entity(entities, key, value),
    do: :ets.insert(entities, {key, {make_ref(), value}})

  defp retire_entities(current, obsolete, generation) do
    Enum.reduce(current, obsolete, fn {{kind, key}, version}, obsolete ->
      Map.put(obsolete, {kind, key, version}, generation)
    end)
  end

  @impl true
  def handle_cast({:retire, table}, state) do
    {:noreply, schedule(%{state | retired: Enum.uniq([table | state.retired])}), :hibernate}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, owner, _reason}, %{owner: owner} = state) do
    state = %{
      state
      | owner: nil,
        retired: state.tables,
        current: %{},
        obsolete: retire_entities(state.current, state.obsolete, state.generation + 1)
    }

    {:noreply, schedule(state), :hibernate}
  end

  def handle_info(:collect, state) do
    {unused, retained} = Enum.split_with(state.retired, &(:ets.info(&1, :safe_fixed) == false))
    Enum.each(unused, &:ets.delete/1)
    state = %{state | tables: state.tables -- unused, retired: retained, timer: nil}
    state = prune_entities(state)

    if is_nil(state.owner) and state.tables == [],
      do: {:stop, :normal, state},
      else: {:noreply, schedule(state), :hibernate}
  end

  defp prune_entities(state) do
    snapshots =
      Enum.map(state.tables, fn table ->
        [{_, {_, generation, first}}] = :ets.lookup(table, :entities)
        {first, generation}
      end)

    # The immutable owner index holds only keys and generations. Collect only
    # superseded slots, never scan unchanged entities after a partial update.
    obsolete =
      Enum.reduce(state.obsolete, %{}, fn {{_, _, version} = row, next}, retained ->
        needed =
          Enum.any?(snapshots, fn {first, generation} ->
            version >= first and version <= generation and generation < next
          end)

        if needed do
          Map.put(retained, row, next)
        else
          prune_entity(state, row)
          retained
        end
      end)

    %{state | obsolete: obsolete}
  end

  defp prune_entity(state, row) do
    {token, _} = :ets.lookup_element(state.entities, row, 2)
    :ets.delete(state.entities, row)
    :ets.delete(state.normalized, token)
  end

  defp schedule(%{retired: [_ | _], timer: nil} = state),
    do: %{state | timer: Process.send_after(self(), :collect, 100)}

  defp schedule(state), do: state
end

defmodule Featurevisor.EntityCollection do
  @moduledoc false
  @behaviour Access
  defstruct [:table, :kind]

  @impl true
  def fetch(%__MODULE__{table: table, kind: kind}, key) do
    case Featurevisor.DatafileStore.entity(table, kind, key) do
      {_token, value} -> {:ok, value}
      nil -> :error
    end
  end

  @impl true
  def get_and_update(_collection, _key, _fun), do: raise(ArgumentError, "Read only collection")
  @impl true
  def pop(_collection, _key), do: raise(ArgumentError, "Read only collection")

  def keys(%__MODULE__{table: table, kind: kind}),
    do: Featurevisor.DatafileStore.keys(table, kind)

  def keys(map), do: Map.keys(map)

  def materialize(%__MODULE__{table: table, kind: kind}),
    do: Featurevisor.DatafileStore.materialize(table, kind)

  def materialize(map), do: map
end
