defmodule Featurevisor.StickyStore do
  @moduledoc false
  use GenServer
  @behaviour Access

  defmodule Generation do
    @moduledoc false
    defstruct [:table, :retired]
  end

  defstruct [:table, :kind]

  def start(owner), do: GenServer.start(__MODULE__, owner)

  def create(pid, features, variables),
    do: GenServer.call(pid, {:create, features, variables}, :infinity)

  def retire(pid, generation), do: GenServer.cast(pid, {:retire, generation})

  def view(%Generation{table: table}, kind), do: %__MODULE__{table: table, kind: kind}
  def materialize(nil), do: nil

  def materialize(%__MODULE__{table: table, kind: kind}) do
    table
    |> :ets.select([{{{kind, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}])
    |> Map.new()
  end

  def materialize(map), do: map

  @impl Access
  def fetch(%__MODULE__{table: table, kind: kind}, key) do
    case :ets.lookup(table, {kind, key}) do
      [{_, value}] -> {:ok, value}
      [] -> :error
    end
  end

  @impl Access
  def get_and_update(_store, _key, _fun), do: raise(ArgumentError, "Read only sticky state")
  @impl Access
  def pop(_store, _key), do: raise(ArgumentError, "Read only sticky state")

  def has_key?(%__MODULE__{} = view, key), do: match?({:ok, _}, fetch(view, key))
  def has_key?(map, key), do: Map.has_key?(map || %{}, key)

  # The owner marks a generation retired before checking fixation. A reader
  # fixes first and checks retirement before accessing rows. A late fixation
  # therefore cannot become an admitted reader, while the VM releases an
  # admitted reader's fixation automatically if its process dies.
  def pin(%Generation{table: table, retired: retired} = generation) do
    if :ets.safe_fixtable(table, true) do
      if :atomics.get(retired, 1) == 0 do
        true
      else
        unpin(generation)
        false
      end
    else
      false
    end
  rescue
    ArgumentError -> false
  end

  def unpin(%Generation{table: table}) do
    :ets.safe_fixtable(table, false)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp mark_retired(%Generation{retired: retired}), do: :atomics.put(retired, 1, 1)

  @impl true
  def init(owner) do
    Process.flag(:trap_exit, true)
    Process.monitor(owner)
    {:ok, %{owner: owner, tables: [], retired: [], timer: nil}}
  end

  @impl true
  def handle_call({:create, features, variables}, _from, state) do
    table = :ets.new(__MODULE__, [:set, :public, read_concurrency: true])

    Enum.each([{:features, features}, {:variables, variables}], fn {kind, values} ->
      Enum.each(values || %{}, fn {key, value} -> :ets.insert(table, {{kind, key}, value}) end)
    end)

    generation = %Generation{table: table, retired: :atomics.new(1, [])}
    {:reply, generation, %{state | tables: [generation | state.tables]}, :hibernate}
  end

  @impl true
  def handle_cast({:retire, generation}, state) do
    mark_retired(generation)
    {:noreply, schedule(%{state | retired: Enum.uniq([generation | state.retired])}), :hibernate}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, owner, _reason}, %{owner: owner} = state) do
    Enum.each(state.tables, &mark_retired/1)
    {:noreply, schedule(%{state | owner: nil, retired: state.tables}), :hibernate}
  end

  def handle_info({:EXIT, owner, _reason}, %{owner: owner} = state),
    do: {:noreply, state}

  def handle_info(:collect, state) do
    {unused, retained} =
      Enum.split_with(state.retired, &(:ets.info(&1.table, :safe_fixed) == false))

    Enum.each(unused, &:ets.delete(&1.table))
    state = %{state | tables: state.tables -- unused, retired: retained, timer: nil}

    if is_nil(state.owner) and state.tables == [],
      do: {:stop, :normal, state},
      else: {:noreply, schedule(state), :hibernate}
  end

  defp schedule(%{retired: [_ | _], timer: nil} = state),
    do: %{state | timer: Process.send_after(self(), :collect, 100)}

  defp schedule(state), do: state
end
