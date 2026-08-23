defmodule Featurevisor.Child do
  @moduledoc "A child Featurevisor instance with isolated context and sticky state."
  alias Featurevisor.Evaluation

  @opaque t :: %__MODULE__{parent: Featurevisor.t(), agent: pid()}
  defstruct [:parent, :agent]

  @doc false
  @spec create(Featurevisor.t(), map(), map() | keyword()) :: t()
  def create(parent, context, options) do
    options = if is_list(options), do: Map.new(options), else: options
    stored = Map.merge(Featurevisor.get_context(parent), context)

    {:ok, agent} =
      Agent.start(fn ->
        %{
          context: stored,
          sticky: Map.get(options, :sticky, %{}),
          listeners: %{},
          unsubs: [],
          closed: false
        }
      end)

    %__MODULE__{parent: parent, agent: agent}
  end

  @doc "Merges or replaces child context."
  def set_context(child, context, replace \\ false) do
    details =
      Agent.get_and_update(child.agent, fn state ->
        value = if replace, do: context, else: Map.merge(state.context, context)
        {%{context: value, replaced: replace}, %{state | context: value}}
      end)

    trigger(child, :context_set, details)
    :ok
  end

  @doc "Returns the effective child context."
  def get_context(child, context \\ %{}) do
    stored = Agent.get(child.agent, & &1.context)
    Featurevisor.get_context(child.parent) |> Map.merge(stored) |> Map.merge(context)
  end

  @doc "Merges or replaces child sticky values."
  def set_sticky(child, sticky, replace \\ false) do
    details =
      Agent.get_and_update(child.agent, fn state ->
        value = if replace, do: sticky, else: Map.merge(state.sticky, sticky)

        {%{features: Enum.uniq(Map.keys(state.sticky) ++ Map.keys(value)), replaced: replace},
         %{state | sticky: value}}
      end)

    trigger(child, :sticky_set, details)
    :ok
  end

  @doc "Subscribes to a child or delegated parent event."
  def on(child, event, callback) when event in [:context_set, :sticky_set] do
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

  def on(child, event, callback) do
    unsubscribe = Featurevisor.on(child.parent, event, callback)
    Agent.update(child.agent, fn state -> %{state | unsubs: state.unsubs ++ [unsubscribe]} end)
    once(fn -> unsubscribe.() end)
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

  @doc "Alias matching other Featurevisor SDK terminology."
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_enabled(child, key, context \\ %{}, options \\ %{}),
    do: enabled?(child, key, context, options)

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

  @doc "Closes child listeners and delegated subscriptions."
  def close(child) do
    if Process.alive?(child.agent) do
      unsubs = Agent.get(child.agent, & &1.unsubs)
      Enum.each(unsubs, & &1.())
      Agent.stop(child.agent)
    end

    :ok
  end

  defp child_options(child, options) do
    options = if is_list(options), do: Map.new(options), else: options
    Map.put(options, :__child_sticky, Agent.get(child.agent, & &1.sticky))
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
