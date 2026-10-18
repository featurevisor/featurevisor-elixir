defmodule Featurevisor.Server do
  @moduledoc false
  use GenServer

  alias Featurevisor.{DatafileStore, EntityCollection, StickyStore}
  alias Featurevisor.Module, as: FeaturevisorModule

  @empty_datafile %{
    "schemaVersion" => "2",
    "revision" => "unknown",
    "segments" => %{},
    "features" => %{},
    "variables" => %{}
  }

  @closed_snapshot %{
    datafile: @empty_datafile,
    context: %{},
    sticky_features: nil,
    sticky_variables: nil,
    generation: 0,
    log_level: :fatal,
    on_diagnostic: nil,
    modules: [],
    pending_modules: [],
    subscriptions: [],
    listeners: %{},
    regex_cache: nil,
    closed: true
  }
  @request_cache_key {__MODULE__, :request_cache}

  def start(options) do
    GenServer.start(__MODULE__, options)
  end

  def start_link(options) do
    case Map.get(options, :name) do
      nil -> GenServer.start_link(__MODULE__, options)
      name -> GenServer.start_link(__MODULE__, options, name: name)
    end
  end

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    table = :ets.new(__MODULE__, [:set, :public, read_concurrency: true, write_concurrency: true])

    {:ok, store} = DatafileStore.start(self())
    Process.monitor(store)
    {:ok, sticky_store} = StickyStore.start(self())
    Process.monitor(sticky_store)

    sticky_table =
      StickyStore.create(
        sticky_store,
        Map.get(options, :sticky_features),
        Map.get(options, :sticky_variables)
      )

    regex_cache = DatafileStore.create(store, @empty_datafile)

    snapshot = %{
      datafile: @empty_datafile,
      context: Map.get(options, :context, %{}),
      sticky_features: Map.get(options, :sticky_features),
      sticky_variables: Map.get(options, :sticky_variables),
      sticky_table: sticky_table,
      generation: 0,
      log_level: Map.get(options, :log_level, :info),
      on_diagnostic: Map.get(options, :on_diagnostic),
      modules: [],
      pending_modules: [],
      subscriptions: [],
      listeners: %{},
      regex_cache: regex_cache,
      closed: false
    }

    publish(table, snapshot)

    {:ok,
     %{
       table: table,
       snapshot: snapshot,
       store: store,
       sticky_store: sticky_store,
       dependency_index: nil
     }}
  end

  @impl true
  def handle_call(:table, _from, state), do: {:reply, state.table, state}

  def handle_call({:set_datafile, incoming, replace}, from, state) do
    if state.snapshot.closed do
      {:reply, :closed, state}
    else
      previous = state.snapshot.datafile
      current = if replace, do: incoming, else: merge_datafile(previous, incoming)

      {details, index} =
        datafile_details(previous, current, replace, state.dependency_index, incoming)

      handle_call(
        {:update,
         fn snapshot ->
           {{:ok, details},
            snapshot
            |> Map.put(:datafile, current)
            |> Map.put(:normalization_update, {replace, incoming})}
         end},
        from,
        %{state | dependency_index: index}
      )
    end
  end

  def handle_call({:update, fun}, _from, state) do
    {reply, snapshot} = fun.(state.snapshot)

    datafile_changed =
      Map.has_key?(snapshot, :normalization_update) or
        snapshot.datafile !== state.snapshot.datafile

    snapshot = %{snapshot | generation: state.snapshot.generation + 1}

    snapshot =
      if snapshot.sticky_features !== state.snapshot.sticky_features or
           snapshot.sticky_variables !== state.snapshot.sticky_variables do
        %{
          snapshot
          | sticky_table:
              StickyStore.create(
                state.sticky_store,
                snapshot.sticky_features,
                snapshot.sticky_variables
              )
        }
      else
        snapshot
      end

    snapshot =
      if datafile_changed do
        cache =
          case snapshot[:normalization_update] do
            {false, incoming} ->
              DatafileStore.create(
                state.store,
                nil,
                state.snapshot.regex_cache,
                incoming
              )

            _ ->
              DatafileStore.create(state.store, snapshot.datafile)
          end

        %{snapshot | regex_cache: cache}
      else
        snapshot
      end

    snapshot = Map.delete(snapshot, :normalization_update)
    publish(state.table, snapshot)

    if snapshot.regex_cache != state.snapshot.regex_cache,
      do: DatafileStore.retire(state.store, state.snapshot.regex_cache)

    if snapshot.sticky_table != state.snapshot.sticky_table,
      do: StickyStore.retire(state.sticky_store, state.snapshot.sticky_table)

    # Compact the large temporary update heap, without adding collection work
    # to evaluations or ordinary context, sticky and module state changes.
    {:reply, reply, %{state | snapshot: snapshot},
     if(datafile_changed, do: :hibernate, else: :infinity)}
  end

  def handle_call(:close, _from, state) do
    snapshot = state.snapshot
    modules = snapshot.modules

    snapshot = %{
      snapshot
      | closed: true,
        modules: [],
        subscriptions: [],
        listeners: %{},
        generation: snapshot.generation + 1
    }

    publish(state.table, snapshot)
    {:reply, modules, %{state | snapshot: snapshot}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, store, reason}, %{store: store} = state),
    do: {:stop, {:datafile_store_exit, reason}, state}

  def handle_info({:DOWN, _ref, :process, store, reason}, %{sticky_store: store} = state),
    do: {:stop, {:sticky_store_exit, reason}, state}

  @impl true
  def terminate(_reason, state) do
    case state.snapshot do
      snapshot when is_map(snapshot) ->
        publish(state.table, %{
          snapshot
          | closed: true,
            modules: [],
            subscriptions: [],
            listeners: %{}
        })

        modules = snapshot.modules

        task =
          Task.async(fn ->
            Enum.each(modules, fn module ->
              if module.close do
                try do
                  module.close.()
                rescue
                  _error -> :ok
                catch
                  _kind, _reason -> :ok
                end
              end
            end)
          end)

        Task.await(task, :infinity)

      _ ->
        :ok
    end

    :ok
  end

  def update(pid, fun), do: GenServer.call(pid, {:update, fun})

  def set_datafile(pid, incoming, replace),
    do: GenServer.call(pid, {:set_datafile, incoming, replace})

  def table(pid), do: GenServer.call(pid, :table)
  def close(pid), do: GenServer.call(pid, :close)

  def snapshot(table) do
    case Process.get(@request_cache_key) do
      nil -> read_snapshot(table)
      cache -> cached_snapshot(table, cache)
    end
  end

  def with_request_cache(fun) do
    previous = Process.get(@request_cache_key)
    Process.put(@request_cache_key, %{pinned: []})

    try do
      fun.()
    after
      Process.get(@request_cache_key, %{})
      |> Map.get(:pinned, [])
      |> Enum.each(&StickyStore.unpin/1)

      if is_nil(previous),
        do: Process.delete(@request_cache_key),
        else: Process.put(@request_cache_key, previous)
    end
  end

  def seed_request_cache(table, snapshot) do
    if cache = Process.get(@request_cache_key) do
      cache =
        if not snapshot.closed and snapshot.sticky_table not in cache.pinned and
             StickyStore.pin(snapshot.sticky_table) do
          Map.put(cache, :pinned, [snapshot.sticky_table | cache.pinned])
        else
          cache
        end

      Process.put(@request_cache_key, Map.put(cache, table, {snapshot.generation, snapshot}))
    end

    :ok
  end

  defp cached_snapshot(table, cache) do
    generation = :ets.lookup_element(table, :generation, 2)

    case Map.get(cache, table) do
      {^generation, snapshot} ->
        snapshot

      _ ->
        cache_and_read_snapshot(table, cache)
    end
  rescue
    ArgumentError -> @closed_snapshot
  end

  defp cache_and_read_snapshot(table, cache) do
    snapshot = read_snapshot(table)

    cond do
      snapshot.closed or snapshot.sticky_table in cache.pinned ->
        Process.put(@request_cache_key, Map.put(cache, table, {snapshot.generation, snapshot}))
        snapshot

      StickyStore.pin(snapshot.sticky_table) ->
        current = read_snapshot(table)

        if current.generation == snapshot.generation and not current.closed do
          cache = Map.put(cache, :pinned, [snapshot.sticky_table | cache.pinned])
          Process.put(@request_cache_key, Map.put(cache, table, {snapshot.generation, snapshot}))
          snapshot
        else
          StickyStore.unpin(snapshot.sticky_table)
          cache_and_read_snapshot(table, cache)
        end

      true ->
        current = read_snapshot(table)

        if current.generation == snapshot.generation,
          do: @closed_snapshot,
          else: cache_and_read_snapshot(table, cache)
    end
  end

  defp read_snapshot(table) do
    case :ets.lookup(table, :snapshot) do
      [{:snapshot, snapshot}] -> snapshot
      [] -> @closed_snapshot
    end
  rescue
    ArgumentError -> @closed_snapshot
  end

  # Validate the generation after pinning it. Retirement can race with an
  # unvalidated reader, but never with one already using the generation.
  def with_snapshot(table, fun) do
    snap = snapshot(table)

    cond do
      snap.closed ->
        fun.(@closed_snapshot)

      pin(snap.regex_cache) and StickyStore.pin(snap.sticky_table) ->
        use_snapshot(table, snap, fun)

      true ->
        unpin(snap.regex_cache)

        current = snapshot(table)

        if current.regex_cache == snap.regex_cache and current.sticky_table == snap.sticky_table,
          do: fun.(@closed_snapshot),
          else: with_snapshot(table, fun)
    end
  end

  defp use_snapshot(table, snap, fun) do
    current = snapshot(table)

    if current.regex_cache == snap.regex_cache and
         current.sticky_table == snap.sticky_table and not current.closed do
      try do
        fun.(snap)
      after
        unpin(snap.regex_cache)
        StickyStore.unpin(snap.sticky_table)
      end
    else
      unpin(snap.regex_cache)
      StickyStore.unpin(snap.sticky_table)
      with_snapshot(table, fun)
    end
  end

  defp pin(table) do
    :ets.safe_fixtable(table, true)
  rescue
    ArgumentError -> false
  end

  defp unpin(table) do
    :ets.safe_fixtable(table, false)
  rescue
    ArgumentError -> :ok
  end

  def materialize_datafile(datafile) do
    Enum.reduce(["features", "variables", "segments"], datafile, fn kind, result ->
      Map.put(result, kind, EntityCollection.materialize(datafile[kind] || %{}))
    end)
  end

  defp publish(table, snapshot) do
    datafile =
      Enum.reduce(["features", "variables", "segments"], snapshot.datafile, fn kind, result ->
        Map.put(result, kind, %EntityCollection{table: snapshot.regex_cache, kind: kind})
      end)

    published = %{
      snapshot
      | datafile: datafile,
        sticky_features:
          if(is_nil(snapshot.sticky_features),
            do: nil,
            else: StickyStore.view(snapshot.sticky_table, :features)
          ),
        sticky_variables:
          if(is_nil(snapshot.sticky_variables),
            do: nil,
            else: StickyStore.view(snapshot.sticky_table, :variables)
          )
    }

    :ets.insert(table, {:snapshot, published})
    :ets.insert(table, {:generation, snapshot.generation})
  end

  def parse_datafile(datafile) when is_binary(datafile), do: Jason.decode(datafile)
  def parse_datafile(datafile) when is_map(datafile), do: {:ok, datafile}
  def parse_datafile(_), do: {:error, ArgumentError.exception("Invalid datafile")}

  def valid_datafile?(datafile) do
    is_map(datafile) and is_binary(datafile["schemaVersion"]) and
      is_binary(datafile["revision"]) and is_map(datafile["segments"]) and
      is_map(datafile["features"]) and
      (is_nil(datafile["variables"]) or is_map(datafile["variables"]))
  end

  def merge_datafile(existing, incoming) do
    %{
      "schemaVersion" => incoming["schemaVersion"],
      "revision" => incoming["revision"],
      "featurevisorVersion" => incoming["featurevisorVersion"],
      "segments" => Map.merge(existing["segments"] || %{}, incoming["segments"] || %{}),
      "features" => Map.merge(existing["features"] || %{}, incoming["features"] || %{}),
      "variables" => Map.merge(existing["variables"] || %{}, incoming["variables"] || %{})
    }
  end

  def datafile_details(previous, current, replace, index \\ nil, incoming \\ nil) do
    if Enum.all?(["features", "variables", "segments"], &(map_size(previous[&1] || %{}) == 0)) do
      # Every incoming entity is already announced. Defer graph traversal until
      # an update can affect definitions retained from an earlier datafile.
      {%{
         revision: current["revision"],
         previousRevision: previous["revision"],
         revisionChanged: previous["revision"] != current["revision"],
         features: current["features"] |> Map.keys() |> Enum.sort(),
         variables: (current["variables"] || %{}) |> Map.keys() |> Enum.sort(),
         replaced: replace
       }, index}
    else
      dependent_datafile_details(previous, current, replace, index, incoming)
    end
  end

  defp dependent_datafile_details(previous, current, replace, index, incoming) do
    touched = if replace or is_nil(incoming), do: nil, else: incoming
    changed = changed_entities(previous, current, touched, "features")
    variables = changed_entities(previous, current, touched, "variables")

    segments =
      Enum.filter(
        touched_keys(previous, current, touched, "segments"),
        &(get_in(previous, ["segments", &1]) != get_in(current, ["segments", &1]))
      )

    {features, variables, index} =
      if index || changed != [] || variables != [] || segments != [] do
        index = index || Featurevisor.DependencyIndex.new(previous)
        {features, variables} = expand_dependencies(index.reverse, changed, variables, segments)
        index = Featurevisor.DependencyIndex.update(index, previous, current, touched)
        {features, variables} = expand_dependencies(index.reverse, features, variables, segments)
        {features, variables, index}
      else
        {changed, variables, index}
      end

    {%{
       revision: current["revision"],
       previousRevision: previous["revision"],
       revisionChanged: previous["revision"] != current["revision"],
       features: Enum.sort(features),
       variables: Enum.sort(variables),
       replaced: replace
     }, index}
  end

  defp touched_keys(previous, current, nil, kind),
    do: Enum.uniq(Map.keys(previous[kind] || %{}) ++ Map.keys(current[kind] || %{}))

  defp touched_keys(_previous, _current, incoming, kind), do: Map.keys(incoming[kind] || %{})

  defp changed_entities(previous, current, touched, kind) do
    keys =
      Enum.uniq(Map.keys(previous[kind] || %{}) ++ Map.keys((touched || current)[kind] || %{}))

    Enum.filter(keys, fn key ->
      old = get_in(previous, [kind, key, "hash"])
      new = get_in(current, [kind, key, "hash"])
      old in [nil, ""] or new in [nil, ""] or old != new
    end)
  end

  defp expand_dependencies(graph, features, variables, segments) do
    roots =
      Enum.map(features, &{"features", &1}) ++
        Enum.map(variables, &{"variables", &1}) ++ Enum.map(segments, &{"segments", &1})

    # Keep leaf notifications in the result without scheduling a traversal for
    # each retained hashless root or each terminal dependent.
    pending = Enum.filter(roots, &Map.has_key?(graph, &1))
    affected = dependency_closure(pending, MapSet.new(roots), graph)

    {for({"features", key} <- affected, do: key), for({"variables", key} <- affected, do: key)}
  end

  defp dependency_closure([], affected, _graph), do: affected

  defp dependency_closure([key | rest], affected, graph) do
    next = Map.get(graph, key, MapSet.new()) |> MapSet.difference(affected)
    pending = Enum.filter(next, &Map.has_key?(graph, &1))
    dependency_closure(pending ++ rest, MapSet.union(affected, next), graph)
  end

  def module_id(%FeaturevisorModule{id: nil} = module), do: %{module | id: make_ref()}
  def module_id(%FeaturevisorModule{} = module), do: module
end
