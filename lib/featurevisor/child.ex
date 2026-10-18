defmodule Featurevisor.Child do
  @moduledoc "A child Featurevisor instance with isolated context and sticky state."
  alias Featurevisor.{Evaluation, StickyStore}
  @request_cache_key {__MODULE__, :request_cache}

  @opaque t :: %__MODULE__{parent: Featurevisor.t(), agent: pid(), sticky_store: pid()}
  defstruct [:parent, :agent, :sticky_store]

  @doc false
  @spec create(Featurevisor.t(), map(), map() | keyword()) :: t()
  def create(parent, context, options) do
    options = if is_list(options), do: Map.new(options), else: options
    stored = Map.merge(Featurevisor.get_context(parent), context)

    {:ok, agent} =
      Agent.start(fn ->
        %{
          context: stored,
          sticky_features: Map.get(options, :sticky_features, %{}),
          sticky_variables: Map.get(options, :sticky_variables, %{}),
          sticky_table: nil,
          listeners: %{},
          unsubs: [],
          generation: 0,
          closed: false
        }
      end)

    {:ok, sticky_store} = StickyStore.start(agent)

    Agent.update(agent, fn state ->
      Process.link(sticky_store)
      table = StickyStore.create(sticky_store, state.sticky_features, state.sticky_variables)
      state |> Map.put(:sticky_table, table) |> Map.put(:sticky_store, sticky_store)
    end)

    %__MODULE__{parent: parent, agent: agent, sticky_store: sticky_store}
  end

  @doc "Merges or replaces child context."
  def set_context(child, context, replace \\ false) do
    while_live(child, :ok, fn -> set_live_context(child, context, replace) end)
  end

  defp set_live_context(child, context, replace) do
    details =
      Agent.get_and_update(child.agent, fn state ->
        value = if replace, do: context, else: Map.merge(state.context, context)

        {%{context: value, replaced: replace},
         %{state | context: value, generation: state.generation + 1}}
      end)

    trigger(child, :context_set, details)
    :ok
  end

  @doc "Returns the effective child context."
  def get_context(child, context \\ %{}) do
    stored = while_live(child, %{}, fn -> Agent.get(child.agent, & &1.context) end)
    Featurevisor.get_context(child.parent) |> Map.merge(stored) |> Map.merge(context)
  end

  @doc "Merges or replaces child sticky feature values."
  def set_sticky_features(child, sticky, replace \\ false) do
    while_live(child, :ok, fn -> set_live_sticky_features(child, sticky, replace) end)
  end

  defp set_live_sticky_features(child, sticky, replace) do
    {details, old_table, sticky_store} =
      Agent.get_and_update(child.agent, fn state ->
        value = if replace, do: sticky, else: Map.merge(state.sticky_features, sticky)
        table = StickyStore.create(state.sticky_store, value, state.sticky_variables)

        {{%{
            features: Enum.uniq(Map.keys(state.sticky_features) ++ Map.keys(value)),
            replaced: replace
          }, state.sticky_table, state.sticky_store},
         %{state | sticky_features: value, sticky_table: table, generation: state.generation + 1}}
      end)

    StickyStore.retire(sticky_store, old_table)

    trigger(child, :sticky_features_set, details)
    :ok
  end

  @doc "Merges or replaces child sticky global variable values."
  def set_sticky_variables(child, sticky, replace \\ false) do
    while_live(child, :ok, fn ->
      {details, old_table, sticky_store} =
        Agent.get_and_update(child.agent, fn state ->
          value = if replace, do: sticky, else: Map.merge(state.sticky_variables, sticky)
          table = StickyStore.create(state.sticky_store, state.sticky_features, value)

          {{%{
              variables: Enum.uniq(Map.keys(state.sticky_variables) ++ Map.keys(value)),
              replaced: replace
            }, state.sticky_table, state.sticky_store},
           %{
             state
             | sticky_variables: value,
               sticky_table: table,
               generation: state.generation + 1
           }}
        end)

      StickyStore.retire(sticky_store, old_table)

      trigger(child, :sticky_variables_set, details)
      :ok
    end)
  end

  @doc "Subscribes to a child or delegated parent event."
  def on(child, event, callback)
      when event in [:context_set, :sticky_features_set, :sticky_variables_set] do
    while_live(child, once(fn -> :ok end), fn ->
      subscribe_to_local_event(child, event, callback)
    end)
  end

  def on(child, event, callback) do
    if live?(child) do
      unsubscribe = Featurevisor.on(child.parent, event, callback)

      try do
        Agent.update(child.agent, fn state -> %{state | unsubs: state.unsubs ++ [unsubscribe]} end)

        watch_delegated_subscription(child, unsubscribe)
      catch
        :exit, reason ->
          unsubscribe.()
          if live?(child), do: exit(reason), else: once(fn -> :ok end)
      end
    else
      once(fn -> :ok end)
    end
  end

  defp subscribe_to_local_event(child, event, callback) do
    id = make_ref()

    Agent.update(child.agent, fn state ->
      %{
        state
        | listeners:
            Map.update(state.listeners, event, [{id, callback}], &(&1 ++ [{id, callback}]))
      }
    end)

    once(fn ->
      if Process.alive?(child.agent),
        do:
          Agent.update(child.agent, fn state ->
            %{
              state
              | listeners:
                  Map.update(
                    state.listeners,
                    event,
                    [],
                    &Enum.reject(&1, fn {current, _} -> current == id end)
                  )
            }
          end)
    end)
  end

  defp watch_delegated_subscription(child, unsubscribe) do
    watcher =
      spawn(fn ->
        ref = Process.monitor(child.agent)

        receive do
          {:DOWN, ^ref, :process, _, _} -> unsubscribe.()
          :stop -> :ok
        end
      end)

    once(fn ->
      unsubscribe.()
      send(watcher, :stop)
    end)
  end

  @doc "Evaluates a flag through the parent instance."
  @spec evaluate_flag(t(), String.t(), map(), map()) :: Evaluation.t()
  def evaluate_flag(child, key, context \\ %{}, options \\ %{}),
    do:
      Featurevisor.evaluate_flag(
        child.parent,
        key,
        get_context(child, context),
        child_options(child, options)
      )

  @doc "Returns whether a feature is enabled."
  def enabled?(child, key, context \\ %{}, options \\ %{}),
    do: evaluate_flag(child, key, context, options).enabled == true

  @doc "Evaluates a variation through the parent instance."
  def evaluate_variation(child, key, context \\ %{}, options \\ %{}),
    do:
      Featurevisor.evaluate_variation(
        child.parent,
        key,
        get_context(child, context),
        child_options(child, options)
      )

  @doc "Returns a variation value."
  def get_variation(child, key, context \\ %{}, options \\ %{}),
    do:
      Featurevisor.get_variation(
        child.parent,
        key,
        get_context(child, context),
        child_options(child, options)
      )

  @doc "Evaluates a variable through the parent instance."
  def evaluate_variable(child, key, variable, context \\ %{}, options \\ %{}),
    do:
      Featurevisor.evaluate_variable(
        child.parent,
        key,
        variable,
        get_context(child, context),
        child_options(child, options)
      )

  @doc "Returns a variable value."
  def get_variable(child, key, variable, context \\ %{}, options \\ %{}),
    do:
      Featurevisor.get_variable(
        child.parent,
        key,
        variable,
        get_context(child, context),
        child_options(child, options)
      )

  @doc "Returns a boolean variable after runtime type checking."
  def get_variable_boolean(child, key, variable, context \\ %{}, options \\ %{}),
    do: typed_variable(child, :get_variable_boolean, key, variable, context, options)

  @doc "Returns a string variable after runtime type checking."
  def get_variable_string(child, key, variable, context \\ %{}, options \\ %{}),
    do: typed_variable(child, :get_variable_string, key, variable, context, options)

  @doc "Returns an integer variable after runtime type checking."
  def get_variable_integer(child, key, variable, context \\ %{}, options \\ %{}),
    do: typed_variable(child, :get_variable_integer, key, variable, context, options)

  @doc "Returns a finite number variable, whole or fractional, after runtime type checking."
  def get_variable_number(child, key, variable, context \\ %{}, options \\ %{}),
    do: typed_variable(child, :get_variable_number, key, variable, context, options)

  @doc "Returns a list variable after runtime type checking."
  def get_variable_array(child, key, variable, context \\ %{}, options \\ %{}),
    do: typed_variable(child, :get_variable_array, key, variable, context, options)

  @doc "Returns a map variable after runtime type checking."
  def get_variable_object(child, key, variable, context \\ %{}, options \\ %{}),
    do: typed_variable(child, :get_variable_object, key, variable, context, options)

  @doc "Returns a decoded JSON variable."
  def get_variable_json(child, key, variable, context \\ %{}, options \\ %{}),
    do: typed_variable(child, :get_variable_json, key, variable, context, options)

  @doc "Evaluates all or selected features through the parent instance."
  def get_feature_evaluations(child, context \\ %{}, feature_keys \\ [], options \\ %{}) do
    Featurevisor.get_feature_evaluations(
      child.parent,
      get_context(child, context),
      feature_keys,
      child_options(child, options)
    )
  end

  @doc "Evaluates a global variable through the parent instance."
  def evaluate_global_variable(child, key, context \\ %{}, options \\ %{}),
    do:
      Featurevisor.evaluate_global_variable(
        child.parent,
        key,
        get_context(child, context),
        child_options(child, options)
      )

  @doc "Returns a global variable value."
  def get_global_variable(child, key, context \\ %{}, options \\ %{}),
    do:
      Featurevisor.get_global_variable(
        child.parent,
        key,
        get_context(child, context),
        child_options(child, options)
      )

  for {name, function} <- [
        boolean: :get_global_variable_boolean,
        string: :get_global_variable_string,
        integer: :get_global_variable_integer,
        number: :get_global_variable_number,
        array: :get_global_variable_array,
        object: :get_global_variable_object,
        json: :get_global_variable_json
      ] do
    @doc "Returns a typed #{name} global variable."
    def unquote(function)(child, key, context \\ %{}, options \\ %{}) do
      apply(Featurevisor, unquote(function), [
        child.parent,
        key,
        get_context(child, context),
        child_options(child, options)
      ])
    end
  end

  @doc "Evaluates all or selected global variables through the parent instance."
  def get_global_variable_evaluations(child, context \\ %{}, variable_keys \\ [], options \\ %{}) do
    Featurevisor.get_global_variable_evaluations(
      child.parent,
      get_context(child, context),
      variable_keys,
      child_options(child, options)
    )
  end

  @doc "Closes child listeners and delegated subscriptions."
  def close(child) do
    if Process.alive?(child.agent) do
      unsubs =
        try do
          Agent.get(child.agent, & &1.unsubs)
        catch
          :exit, _ -> []
        end

      Enum.each(unsubs, & &1.())

      if Process.alive?(child.agent) do
        try do
          Agent.stop(child.agent)
        catch
          :exit, _ -> :ok
        end
      end
    end

    :ok
  end

  defp child_options(child, options) do
    options = if is_list(options), do: Map.new(options), else: options
    snapshot = sticky_snapshot(child)

    options
    |> Map.put(:__child_snapshot, {child.agent, snapshot})
    |> Map.put(:__sticky_features_source, fn -> cached_sticky(child).sticky_features end)
    |> Map.put(:__sticky_variables_source, fn -> cached_sticky(child).sticky_variables end)
    |> Map.put(:__child_signature, fn -> cached_sticky(child).generation end)
  end

  @doc false
  def with_request_cache(initial, fun) do
    previous = Process.get(@request_cache_key)

    {cache, pinned} =
      case initial do
        {agent, %{sticky_table: table} = snapshot} when not is_nil(table) ->
          if StickyStore.pin(table), do: {%{agent => snapshot}, [table]}, else: {%{}, []}

        _ ->
          {%{}, []}
      end

    cache = Map.put(cache, :pinned, pinned)
    Process.put(@request_cache_key, cache)

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

  defp sticky_snapshot(child) do
    if live?(child) do
      try do
        Agent.get(child.agent, fn state ->
          state
          |> Map.take([:generation, :sticky_table])
          |> sticky_views()
        end)
      catch
        :exit, _ -> sticky_views(%{generation: nil, sticky_table: nil})
      end
    else
      sticky_views(%{generation: nil, sticky_table: nil})
    end
  end

  defp sticky_views(%{sticky_table: nil} = snapshot),
    do: Map.merge(snapshot, %{sticky_features: %{}, sticky_variables: %{}})

  defp sticky_views(%{sticky_table: table} = snapshot),
    do:
      Map.merge(snapshot, %{
        sticky_features: StickyStore.view(table, :features),
        sticky_variables: StickyStore.view(table, :variables)
      })

  defp cached_sticky(child) do
    case Process.get(@request_cache_key) do
      nil ->
        snapshot = sticky_snapshot(child)

        if is_nil(snapshot.sticky_table) do
          snapshot
        else
          if StickyStore.pin(snapshot.sticky_table) do
            try do
              %{
                snapshot
                | sticky_table: nil,
                  sticky_features: StickyStore.materialize(snapshot.sticky_features),
                  sticky_variables: StickyStore.materialize(snapshot.sticky_variables)
              }
            after
              StickyStore.unpin(snapshot.sticky_table)
            end
          else
            retry_sticky(child, snapshot)
          end
        end

      cache ->
        generation = child_value(child, :generation, nil)

        case Map.get(cache, child.agent) do
          %{generation: ^generation} = snapshot ->
            snapshot

          _ ->
            snapshot = sticky_snapshot(child)

            if is_nil(snapshot.sticky_table) or StickyStore.pin(snapshot.sticky_table) do
              pinned =
                if snapshot.sticky_table,
                  do: [snapshot.sticky_table | cache.pinned],
                  else: cache.pinned

              Process.put(
                @request_cache_key,
                cache |> Map.put(child.agent, snapshot) |> Map.put(:pinned, pinned)
              )

              snapshot
            else
              retry_sticky(child, snapshot)
            end
        end
    end
  end

  defp retry_sticky(child, snapshot) do
    current = sticky_snapshot(child)

    if current.generation == snapshot.generation and
         current.sticky_table == snapshot.sticky_table,
       do: sticky_views(%{generation: nil, sticky_table: nil}),
       else: cached_sticky(child)
  end

  defp child_value(child, key, default) do
    if live?(child) do
      try do
        Agent.get(child.agent, &Map.get(&1, key, default))
      catch
        :exit, _ -> default
      end
    else
      default
    end
  end

  defp live?(child),
    do:
      Process.alive?(child.agent) and is_pid(child.sticky_store) and
        Process.alive?(child.sticky_store)

  defp while_live(child, fallback, fun) do
    if live?(child), do: fun.(), else: fallback
  catch
    :exit, reason -> if live?(child), do: exit(reason), else: fallback
  end

  defp typed_variable(child, function, key, variable, context, options) do
    apply(Featurevisor, function, [
      child.parent,
      key,
      variable,
      get_context(child, context),
      child_options(child, options)
    ])
  end

  defp trigger(child, event, details),
    do:
      Agent.get(child.agent, &Map.get(&1.listeners, event, []))
      |> Enum.each(fn {_id, callback} -> callback.(details) end)

  defp once(fun) do
    ref = :atomics.new(1, [])
    fn -> if :atomics.compare_exchange(ref, 1, 0, 1) == :ok, do: fun.(), else: :ok end
  end
end
