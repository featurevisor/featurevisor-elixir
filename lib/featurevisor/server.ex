defmodule Featurevisor.Server do
  @moduledoc false
  use GenServer

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
    log_level: :fatal,
    on_diagnostic: nil,
    modules: [],
    pending_modules: [],
    subscriptions: [],
    listeners: %{},
    regex_cache: nil,
    closed: true
  }

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

    regex_cache =
      :ets.new(Featurevisor.RegexCache, [
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    snapshot = %{
      datafile: @empty_datafile,
      context: Map.get(options, :context, %{}),
      sticky_features: Map.get(options, :sticky_features),
      sticky_variables: Map.get(options, :sticky_variables),
      log_level: Map.get(options, :log_level, :info),
      on_diagnostic: Map.get(options, :on_diagnostic),
      modules: [],
      pending_modules: [],
      subscriptions: [],
      listeners: %{},
      regex_cache: regex_cache,
      closed: false
    }

    :ets.insert(table, {:snapshot, snapshot})
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call(:table, _from, state), do: {:reply, state.table, state}

  def handle_call({:update, fun}, _from, state) do
    [{:snapshot, snapshot}] = :ets.lookup(state.table, :snapshot)
    {reply, snapshot} = fun.(snapshot)
    :ets.insert(state.table, {:snapshot, snapshot})
    {:reply, reply, state}
  end

  def handle_call(:close, _from, state) do
    [{:snapshot, snapshot}] = :ets.lookup(state.table, :snapshot)
    modules = snapshot.modules

    :ets.insert(
      state.table,
      {:snapshot, %{snapshot | closed: true, modules: [], subscriptions: [], listeners: %{}}}
    )

    {:reply, modules, state}
  end

  @impl true
  def terminate(_reason, state) do
    case :ets.lookup(state.table, :snapshot) do
      [{:snapshot, snapshot}] ->
        :ets.insert(
          state.table,
          {:snapshot, %{snapshot | closed: true, modules: [], subscriptions: [], listeners: %{}}}
        )

        task =
          Task.async(fn ->
            Enum.each(snapshot.modules, fn module ->
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

      [] ->
        :ok
    end

    :ok
  end

  def update(pid, fun), do: GenServer.call(pid, {:update, fun})
  def table(pid), do: GenServer.call(pid, :table)
  def close(pid), do: GenServer.call(pid, :close)

  def snapshot(table) do
    case :ets.lookup(table, :snapshot) do
      [{:snapshot, snapshot}] -> snapshot
      [] -> @closed_snapshot
    end
  rescue
    ArgumentError -> @closed_snapshot
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

  def datafile_details(previous, current, replace) do
    previous_keys = Map.keys(previous["features"])
    current_keys = Map.keys(current["features"])

    changed =
      Enum.filter(previous_keys, fn key ->
        not Map.has_key?(current["features"], key) or
          is_nil(get_in(previous, ["features", key, "hash"])) or
          is_nil(get_in(current, ["features", key, "hash"])) or
          get_in(previous, ["features", key, "hash"]) !=
            get_in(current, ["features", key, "hash"])
      end)

    added = Enum.reject(current_keys, &Map.has_key?(previous["features"], &1))

    previous_variable_keys = Map.keys(previous["variables"] || %{})
    current_variable_keys = Map.keys(current["variables"] || %{})

    changed_variables =
      Enum.filter(previous_variable_keys, fn key ->
        not Map.has_key?(current["variables"] || %{}, key) or
          is_nil(get_in(previous, ["variables", key, "hash"])) or
          is_nil(get_in(current, ["variables", key, "hash"])) or
          get_in(previous, ["variables", key, "hash"]) !=
            get_in(current, ["variables", key, "hash"])
      end)

    added_variables =
      Enum.reject(current_variable_keys, &Map.has_key?(previous["variables"] || %{}, &1))

    changed_segments =
      Map.keys(previous["segments"] || %{})
      |> Kernel.++(Map.keys(current["segments"] || %{}))
      |> Enum.uniq()
      |> Enum.filter(&(get_in(previous, ["segments", &1]) != get_in(current, ["segments", &1])))
      |> MapSet.new()

    {affected_features, affected_variables} =
      expand_dependencies(
        [previous, current],
        MapSet.new(changed ++ added),
        MapSet.new(changed_variables ++ added_variables),
        changed_segments
      )

    %{
      revision: current["revision"],
      previousRevision: previous["revision"],
      revisionChanged: previous["revision"] != current["revision"],
      features: affected_features |> MapSet.to_list() |> Enum.sort(),
      variables: affected_variables |> MapSet.to_list() |> Enum.sort(),
      replaced: replace
    }
  end

  defp expand_dependencies(datafiles, changed_features, changed_variables, changed_segments) do
    next_features =
      Enum.reduce(datafiles, changed_features, fn datafile, graph_affected ->
        Enum.reduce(datafile["features"] || %{}, graph_affected, fn {key, feature}, affected ->
          required = references(feature, ["requiredFeatures", "required"])
          segments = references(feature, ["segments"])

          if Enum.any?(required, &MapSet.member?(affected, &1)) or
               Enum.any?(segments, &MapSet.member?(changed_segments, &1)),
             do: MapSet.put(affected, key),
             else: affected
        end)
      end)

    next_variables =
      Enum.reduce(datafiles, changed_variables, fn datafile, graph_affected ->
        Enum.reduce(datafile["variables"] || %{}, graph_affected, fn {key, variable}, affected ->
          required = references(variable, ["requiredFeatures"])
          segments = references(variable, ["segments"])

          if Enum.any?(required, &MapSet.member?(next_features, &1)) or
               Enum.any?(segments, &MapSet.member?(changed_segments, &1)),
             do: MapSet.put(affected, key),
             else: affected
        end)
      end)

    if next_features == changed_features and next_variables == changed_variables,
      do: {next_features, next_variables},
      else: expand_dependencies(datafiles, next_features, next_variables, changed_segments)
  end

  defp references(value, fields), do: collect_references(value, MapSet.new(fields), MapSet.new())

  defp collect_references(value, fields, result) when is_map(value) do
    Enum.reduce(value, result, fn {key, child}, current ->
      if MapSet.member?(fields, key),
        do: collect_expression(child, current),
        else: collect_references(child, fields, current)
    end)
  end

  defp collect_references(value, fields, result) when is_list(value),
    do: Enum.reduce(value, result, &collect_references(&1, fields, &2))

  defp collect_references(_value, _fields, result), do: result

  defp collect_expression(value, result) when is_binary(value),
    do: if(value == "*", do: result, else: MapSet.put(result, value))

  defp collect_expression(value, result) when is_list(value),
    do: Enum.reduce(value, result, &collect_expression/2)

  defp collect_expression(value, result) when is_map(value) do
    case value["feature"] || value["key"] do
      key when is_binary(key) -> MapSet.put(result, key)
      _ -> Enum.reduce(Map.values(value), result, &collect_expression/2)
    end
  end

  defp collect_expression(_value, result), do: result

  def module_id(%FeaturevisorModule{id: nil} = module), do: %{module | id: make_ref()}
  def module_id(%FeaturevisorModule{} = module), do: module
end
