defmodule Featurevisor.Server do
  @moduledoc false
  use GenServer

  alias Featurevisor.Module, as: FeaturevisorModule

  @empty_datafile %{
    "schemaVersion" => "2",
    "revision" => "unknown",
    "segments" => %{},
    "features" => %{}
  }

  def start(options) do
    GenServer.start(__MODULE__, options)
  end

  @impl true
  def init(options) do
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
      sticky: Map.get(options, :sticky),
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

  def update(pid, fun), do: GenServer.call(pid, {:update, fun})
  def table(pid), do: GenServer.call(pid, :table)
  def close(pid), do: GenServer.call(pid, :close)

  def snapshot(table) do
    case :ets.lookup(table, :snapshot) do
      [{:snapshot, snapshot}] -> snapshot
      [] -> raise ArgumentError, "Featurevisor instance is closed"
    end
  end

  def parse_datafile(datafile) when is_binary(datafile), do: Jason.decode(datafile)
  def parse_datafile(datafile) when is_map(datafile), do: {:ok, datafile}
  def parse_datafile(_), do: {:error, ArgumentError.exception("Invalid datafile")}

  def valid_datafile?(datafile) do
    is_map(datafile) and is_binary(datafile["schemaVersion"]) and
      is_binary(datafile["revision"]) and is_map(datafile["segments"]) and
      is_map(datafile["features"])
  end

  def merge_datafile(existing, incoming) do
    %{
      "schemaVersion" => incoming["schemaVersion"],
      "revision" => incoming["revision"],
      "featurevisorVersion" => incoming["featurevisorVersion"],
      "segments" => Map.merge(existing["segments"] || %{}, incoming["segments"] || %{}),
      "features" => Map.merge(existing["features"] || %{}, incoming["features"] || %{})
    }
  end

  def datafile_details(previous, current, replace) do
    previous_keys = Map.keys(previous["features"])
    current_keys = Map.keys(current["features"])

    changed =
      Enum.filter(previous_keys, fn key ->
        not Map.has_key?(current["features"], key) or
          get_in(previous, ["features", key, "hash"]) !=
            get_in(current, ["features", key, "hash"])
      end)

    added = Enum.reject(current_keys, &Map.has_key?(previous["features"], &1))

    %{
      revision: current["revision"],
      previousRevision: previous["revision"],
      revisionChanged: previous["revision"] != current["revision"],
      features: Enum.uniq(changed ++ added),
      replaced: replace
    }
  end

  def module_id(%FeaturevisorModule{id: nil} = module), do: %{module | id: make_ref()}
  def module_id(%FeaturevisorModule{} = module), do: module
end
