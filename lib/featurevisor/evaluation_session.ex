defmodule Featurevisor.RequirementCycleError do
  @moduledoc false
  defexception message: "Circular dependency"
end

defmodule Featurevisor.RequirementError do
  @moduledoc false
  defexception [:message]
end

defmodule Featurevisor.EvaluationSession do
  @moduledoc false

  # The table belongs to one public evaluation. It is passed only to internal
  # prerequisite reads and is deleted when that evaluation finishes.
  def new, do: :ets.new(__MODULE__, [:set, :private])

  def close(session) do
    Process.delete({__MODULE__, session, :borrowed})
    :ets.delete(session)
  end

  def dependency_of(session) do
    case :ets.lookup(session, :active) do
      [{:active, [parent | _]}] -> parent.current
      _ -> nil
    end
  end

  def update_current(session, options) do
    current = identity(options)
    [{:active, [frame | ancestors]}] = :ets.lookup(session, :active)
    :ets.insert(session, {:active, [%{frame | current: current} | ancestors]})
  end

  def bypass_memo(session) do
    [{:active, [frame | ancestors]}] = :ets.lookup(session, :active)
    :ets.insert(session, {:active, [%{frame | memoable: false} | ancestors]})
  end

  def run(session, options, prerequisite, fun) do
    identity = identity(options)

    active =
      case :ets.lookup(session, :active) do
        [{:active, stack}] -> stack
        _ -> []
      end

    if Enum.any?(active, &(&1.identity == identity or &1.current == identity)),
      do: raise(Featurevisor.RequirementCycleError)

    if length(active) + segment_depth(session) > 256,
      do:
        raise(Featurevisor.RequirementCycleError, message: "Evaluation dependency depth exceeded")

    requester = dependency_of(session)
    key = if prerequisite, do: fingerprint(identity, requester, options), else: nil

    if key && :ets.member(session, {:memo, key}) do
      [{_, value}] = :ets.lookup(session, {:memo, key})

      if value == :borrowed,
        do: Map.fetch!(Process.get({__MODULE__, session, :borrowed}), key),
        else: value
    else
      :ets.insert(
        session,
        {:active, [%{identity: identity, current: identity, memoable: true} | active]}
      )

      try do
        options =
          if prerequisite,
            do:
              options
              |> Map.put(:dependency_of, requester)
              |> Map.put(:dependency_purpose, options[:dependency_purpose] || :condition),
            else: options

        options =
          if is_nil(options[:dependency_purpose]),
            do: Map.delete(options, :dependency_purpose),
            else: options

        result = fun.(options)
        result = if prerequisite, do: normalize_getter(result, options), else: result

        [{:active, [frame | _]}] = :ets.lookup(session, :active)

        if frame.memoable && key && key == fingerprint(identity, requester, options) do
          if minimal = minimal(result, options[:dependency_purpose]),
            do: put_memo(session, key, minimal, options[:dependency_purpose])
        end

        result
      rescue
        error ->
          [{:active, [frame | _]}] = :ets.lookup(session, :active)

          :ets.insert(
            session,
            {:pending_error, {identity, requester, if(frame.memoable, do: key, else: nil)}}
          )

          reraise error, __STACKTRACE__
      after
        :ets.insert(session, {:active, active})
      end
    end
  end

  def remember(session, options, result, true) do
    identity = identity(options)
    pending = :ets.lookup(session, :pending_error)
    :ets.delete(session, :pending_error)
    key = fingerprint(identity, dependency_of(session), options)

    if pending == [{:pending_error, {identity, dependency_of(session), key}}] && key &&
         minimal(result, options[:dependency_purpose]),
       do:
         put_memo(
           session,
           key,
           minimal(result, options[:dependency_purpose]),
           options[:dependency_purpose]
         )

    :ok
  end

  def remember(_session, _options, _result, _prerequisite), do: :ok

  # BEAM values are immutable. Keep composition values on this request's heap,
  # avoiding the deep term copy which an ETS value insertion would introduce.
  defp put_memo(session, key, value, :composition) do
    cache_key = {__MODULE__, session, :borrowed}
    Process.put(cache_key, Map.put(Process.get(cache_key, %{}), key, value))
    :ets.insert(session, {{:memo, key}, :borrowed})
  end

  defp put_memo(session, key, value, _purpose), do: :ets.insert(session, {{:memo, key}, value})

  defp identity(options) do
    %{type: options.type}
    |> maybe_put(:feature_key, options[:feature_key])
    |> maybe_put(:variable_key, options[:variable_key])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp fingerprint(identity, requester, options) do
    owner_sticky = options[:sticky_owner] == true

    unless safe_json?(options[:context]) and
             (owner_sticky or
                (safe_json?(options[:sticky_features]) and
                   safe_json?(options[:sticky_variables]))),
           do: raise(ArgumentError, "Unsupported memo input")

    sticky =
      if owner_sticky,
        do:
          {options[:sticky_features_token] || :owner, options[:sticky_variables_token] || :owner},
        else: {options[:sticky_features], options[:sticky_variables]}

    :erlang.term_to_binary(
      {identity, requester, options[:dependency_purpose] || :condition, options[:context], sticky,
       options[:regex_cache], options[:state_signature] && options[:state_signature].(),
       options[:child_signature] && options[:child_signature].()}
    )
  rescue
    _ -> nil
  end

  def segment(session, key, fun) do
    active =
      case :ets.lookup(session, :segments) do
        [{_, values}] -> values
        _ -> []
      end

    frames =
      case :ets.lookup(session, :active) do
        [{_, values}] -> length(values)
        _ -> 0
      end

    if key in active, do: raise(Featurevisor.RequirementCycleError)

    if frames + length(active) > 256,
      do:
        raise(Featurevisor.RequirementCycleError, message: "Evaluation dependency depth exceeded")

    :ets.insert(session, {:segments, [key | active]})

    try do
      fun.()
    after
      :ets.insert(session, {:segments, active})
    end
  end

  defp segment_depth(session) do
    case :ets.lookup(session, :segments) do
      [{_, values}] -> length(values)
      _ -> 0
    end
  end

  defp minimal(%Featurevisor.Evaluation{} = evaluation, :composition),
    do: minimal_json(evaluation)

  defp minimal(%Featurevisor.Evaluation{} = evaluation, _purpose) do
    if not safe_json?(evaluation.variable_value) or
         not safe_json?(evaluation.variation_value) or
         not safe_json?(evaluation.variation),
       do: nil,
       else: minimal_json(evaluation)
  end

  defp minimal(_, _), do: nil

  defp normalize_getter(%Featurevisor.Evaluation{type: :variable} = evaluation, options) do
    schema = evaluation.variable_schema || evaluation.variable || %{}
    value = evaluation.variable_value

    value =
      if is_nil(schema["compose"]) and schema["type"] == "json" and is_binary(value) do
        case Jason.decode(value) do
          {:ok, decoded} ->
            decoded

          {:error, error} ->
            options.report.(%{
              level: :error,
              code: "evaluation_error",
              message: "getVariable failed",
              originalError: error,
              details: %{featureKey: evaluation.feature_key, variableKey: evaluation.variable_key}
            })

            nil
        end
      else
        value
      end

    %{evaluation | variable_value: value, __getter_value_normalized: true}
  end

  defp normalize_getter(evaluation, _options), do: evaluation

  defp minimal_json(evaluation) do
    %Featurevisor.Evaluation{
      type: evaluation.type,
      feature_key: evaluation.feature_key,
      variable_key: evaluation.variable_key,
      reason: evaluation.reason,
      enabled: evaluation.enabled,
      variation_value: evaluation.variation_value,
      variation: if(evaluation.variation, do: Map.take(evaluation.variation, ["value"])),
      variable_value: evaluation.variable_value,
      __getter_value_normalized: evaluation.__getter_value_normalized,
      variable_schema:
        if(evaluation.variable_schema, do: Map.take(evaluation.variable_schema, ["type"])),
      variable: if(evaluation.variable, do: Map.take(evaluation.variable, ["type", "compose"]))
    }
  end

  defp safe_json?(_value, depth) when depth > 64, do: false

  defp safe_json?(value, _depth)
       when is_nil(value) or is_boolean(value) or is_binary(value) or is_integer(value), do: true

  defp safe_json?(value, _depth) when is_float(value),
    do: abs(value) < 1.797_693_134_862_315_7e308

  defp safe_json?(value, depth) when is_list(value),
    do: Enum.all?(value, &safe_json?(&1, depth + 1))

  defp safe_json?(value, depth) when is_map(value) do
    not is_struct(value) and
      Enum.all?(value, fn {key, item} ->
        (is_binary(key) or is_atom(key)) and safe_json?(item, depth + 1)
      end)
  end

  defp safe_json?(_value, _depth), do: false
  defp safe_json?(value), do: safe_json?(value, 0)
end
