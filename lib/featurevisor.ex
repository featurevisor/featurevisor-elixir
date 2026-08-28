defmodule Featurevisor do
  @moduledoc """
  Feature flags, experiments, and remote configuration for Elixir.

  Create an isolated instance with `create_featurevisor/1`, then evaluate flags,
  variations, and variables against a Featurevisor schema version 2 datafile.
  """

  alias Featurevisor.{Conditions, Diagnostic, Evaluator, Module, Server}
  require Logger

  @opaque t :: %__MODULE__{pid: pid(), table: :ets.tid()}
  defstruct [:pid, :table]

  @type options :: %{
          optional(:datafile) => map() | String.t(),
          optional(:context) => map(),
          optional(:log_level) => Diagnostic.level(),
          optional(:on_diagnostic) => (Diagnostic.t() -> any()),
          optional(:sticky_features) => map(),
          optional(:sticky_variables) => map(),
          optional(:modules) => [Module.t()],
          optional(:name) => GenServer.name()
        }

  @doc "Creates an isolated Featurevisor instance."
  @spec create_featurevisor(options() | keyword()) :: t()
  def create_featurevisor(options \\ %{}) do
    options = normalize_options(options)

    pid =
      case Server.start(options) do
        {:ok, pid} -> pid
        {:error, reason} -> raise "Could not start Featurevisor instance: #{inspect(reason)}"
      end

    initialize_instance(pid, options)
  end

  @doc "Starts a supervised Featurevisor owner process."
  @spec start_link(options() | keyword()) :: GenServer.on_start()
  def start_link(options \\ %{}) do
    options = normalize_options(options)

    case Server.start_link(options) do
      {:ok, pid} ->
        initialize_instance(pid, options)
        {:ok, pid}

      error ->
        error
    end
  end

  @doc "Returns a Featurevisor handle for a running owner process or registered name."
  @spec instance(GenServer.server()) :: t()
  def instance(server) do
    pid = GenServer.whereis(server)

    if is_pid(pid) do
      %__MODULE__{pid: pid, table: Server.table(server)}
    else
      raise ArgumentError, "Featurevisor instance is not running"
    end
  catch
    :exit, _reason -> raise ArgumentError, "Featurevisor instance is not running"
  end

  @doc false
  def child_spec(options) do
    options = normalize_options(options)

    %{
      id: Map.get(options, :name, __MODULE__),
      start: {__MODULE__, :start_link, [options]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc "Merges or replaces the stored datafile."
  @spec set_datafile(t(), map() | String.t(), boolean()) :: :ok | {:error, term()}
  def set_datafile(instance, input, replace \\ false) do
    if open?(instance), do: set_live_datafile(instance, input, replace), else: :ok
  end

  defp set_live_datafile(instance, input, replace) do
    with {:ok, datafile} <- Server.parse_datafile(input),
         true <- Server.valid_datafile?(datafile) do
      details =
        Server.update(instance.pid, fn snapshot ->
          stored =
            if replace, do: datafile, else: Server.merge_datafile(snapshot.datafile, datafile)

          :ets.delete_all_objects(snapshot.regex_cache)

          {Server.datafile_details(snapshot.datafile, stored, replace),
           %{snapshot | datafile: stored}}
        end)

      report(instance, %{
        level: :info,
        code: "datafile_set",
        message: "Datafile set",
        details: details
      })

      trigger(instance, :datafile_set, details)
      :ok
    else
      error ->
        reason =
          if match?({:error, _}, error),
            do: elem(error, 1),
            else: ArgumentError.exception("Invalid datafile")

        report(instance, %{
          level: :error,
          code: "invalid_datafile",
          message: "Could not parse datafile",
          originalError: reason,
          details: %{}
        })

        {:error, reason}
    end
  end

  @doc "Merges or replaces the stored context."
  def set_context(instance, context, replace \\ false) when is_map(context) do
    if open?(instance), do: set_live_context(instance, context, replace), else: :ok
  end

  defp set_live_context(instance, context, replace) do
    resolved =
      Server.update(instance.pid, fn snapshot ->
        value = if replace, do: context, else: Map.merge(snapshot.context, context)
        {value, %{snapshot | context: value}}
      end)

    details = %{context: resolved, replaced: replace}
    trigger(instance, :context_set, details)

    report(instance, %{
      level: :debug,
      code: "context_set",
      message: if(replace, do: "Context replaced", else: "Context updated"),
      details: details
    })

    :ok
  end

  @doc "Returns stored context merged with optional evaluation context."
  def get_context(instance, context \\ %{}), do: Map.merge(snapshot(instance).context, context)

  @doc "Merges or replaces sticky evaluations."
  def set_sticky(instance, sticky, replace \\ false) when is_map(sticky) do
    set_sticky_features(instance, sticky, replace)
  end

  @doc "Merges or replaces sticky feature evaluations."
  def set_sticky_features(instance, sticky, replace \\ false) when is_map(sticky) do
    if open?(instance), do: set_live_sticky_features(instance, sticky, replace), else: :ok
  end

  defp set_live_sticky_features(instance, sticky, replace) do
    {_resolved, keys} =
      Server.update(instance.pid, fn snapshot ->
        previous = snapshot.sticky_features || %{}
        value = if replace, do: sticky, else: Map.merge(previous, sticky)

        {{value, Enum.uniq(Map.keys(previous) ++ Map.keys(value))},
         %{snapshot | sticky_features: value}}
      end)

    details = %{features: keys, replaced: replace}
    trigger(instance, :sticky_set, details)

    report(instance, %{
      level: :info,
      code: "sticky_set",
      message: "Sticky features set",
      details: details
    })

    :ok
  end

  @doc "Merges or replaces sticky global variable values."
  def set_sticky_variables(instance, sticky, replace \\ false) when is_map(sticky) do
    if open?(instance) do
      {_resolved, keys} =
        Server.update(instance.pid, fn snapshot ->
          previous = snapshot.sticky_variables || %{}
          value = if replace, do: sticky, else: Map.merge(previous, sticky)

          {{value, Enum.uniq(Map.keys(previous) ++ Map.keys(value))},
           %{snapshot | sticky_variables: value}}
        end)

      details = %{variables: keys, replaced: replace}
      trigger(instance, :sticky_variables_set, details)

      report(instance, %{
        level: :info,
        code: "sticky_variables_set",
        message: "Sticky variables set",
        details: details
      })
    end

    :ok
  end

  @doc "Changes the diagnostic threshold."
  def set_log_level(instance, level) when level in [:fatal, :error, :warn, :info, :debug] do
    if open?(instance) do
      Server.update(instance.pid, fn snapshot -> {:ok, %{snapshot | log_level: level}} end)
    else
      :ok
    end
  end

  @doc "Returns the current datafile revision."
  def get_revision(instance), do: snapshot(instance).datafile["revision"]
  @doc "Returns the informational datafile schema version."
  def get_schema_version(instance), do: snapshot(instance).datafile["schemaVersion"]
  @doc "Returns a feature definition."
  def get_feature(instance, key), do: get_in(snapshot(instance).datafile, ["features", key])
  @doc "Returns a segment definition."
  def get_segment(instance, key) do
    case get_in(snapshot(instance).datafile, ["segments", key]) do
      nil ->
        nil

      segment ->
        Map.update!(segment, "conditions", &Conditions.parse_conditions(&1, reporter(instance)))
    end
  end

  @doc "Returns all feature keys. Ordering is not guaranteed."
  def get_feature_keys(instance), do: Map.keys(snapshot(instance).datafile["features"])
  @doc "Returns variable keys for a feature."
  def get_variable_keys(instance, key),
    do: instance |> get_feature(key) |> then(&Map.keys((&1 && &1["variablesSchema"]) || %{}))

  @doc "Returns all global variable keys. Ordering is not guaranteed."
  def get_global_variable_keys(instance),
    do: Map.keys(snapshot(instance).datafile["variables"] || %{})

  @doc "Returns whether a feature defines variations."
  def has_variations?(instance, key),
    do: match?(%{"variations" => [_ | _]}, get_feature(instance, key))

  @doc "Evaluates a feature flag and returns details."
  def evaluate_flag(instance, feature_key, context \\ %{}, options \\ %{}),
    do: evaluate(instance, :flag, feature_key, nil, context, options)

  @doc "Returns whether a feature is enabled."
  def enabled?(instance, feature_key, context \\ %{}, options \\ %{}),
    do: evaluate_flag(instance, feature_key, context, options).enabled == true

  @doc "Evaluates a variation and returns details."
  def evaluate_variation(instance, feature_key, context \\ %{}, options \\ %{}),
    do: evaluate(instance, :variation, feature_key, nil, context, options)

  @doc "Returns a variation value or nil."
  def get_variation(instance, feature_key, context \\ %{}, options \\ %{}) do
    evaluation = evaluate_variation(instance, feature_key, context, options)
    evaluation.variation_value || (evaluation.variation && evaluation.variation["value"])
  end

  @doc "Evaluates a variable and returns details."
  def evaluate_variable(instance, feature_key, variable_key, context \\ %{}, options \\ %{}),
    do: evaluate(instance, :variable, feature_key, variable_key, context, options)

  @doc "Returns a variable value or nil. JSON variables are decoded."
  def get_variable(instance, feature_key, variable_key, context \\ %{}, options \\ %{}) do
    evaluation = evaluate_variable(instance, feature_key, variable_key, context, options)
    value = evaluation.variable_value

    if get_in(evaluation.variable_schema || %{}, ["type"]) == "json" and is_binary(value) do
      case Jason.decode(value) do
        {:ok, parsed} ->
          parsed

        {:error, error} ->
          report(instance, %{
            level: :error,
            code: "evaluation_error",
            message: "getVariable failed",
            originalError: error,
            details: %{featureKey: feature_key, variableKey: variable_key}
          })

          nil
      end
    else
      value
    end
  end

  @doc "Returns a boolean variable after runtime type checking."
  def get_variable_boolean(instance, feature, variable, context \\ %{}, options \\ %{}),
    do: typed(get_variable(instance, feature, variable, context, options), :boolean)

  @doc "Returns a string variable after runtime type checking."
  def get_variable_string(instance, feature, variable, context \\ %{}, options \\ %{}),
    do: typed(get_variable(instance, feature, variable, context, options), :string)

  @doc "Returns an integer variable after runtime type checking."
  def get_variable_integer(instance, feature, variable, context \\ %{}, options \\ %{}),
    do: typed(get_variable(instance, feature, variable, context, options), :integer)

  @doc "Returns a finite numeric variable after runtime type checking."
  def get_variable_double(instance, feature, variable, context \\ %{}, options \\ %{}),
    do: typed(get_variable(instance, feature, variable, context, options), :double)

  @doc "Returns a list variable after runtime type checking."
  def get_variable_array(instance, feature, variable, context \\ %{}, options \\ %{}),
    do: typed(get_variable(instance, feature, variable, context, options), :array)

  @doc "Returns a map variable after runtime type checking."
  def get_variable_object(instance, feature, variable, context \\ %{}, options \\ %{}),
    do: typed(get_variable(instance, feature, variable, context, options), :object)

  @doc "Returns a decoded JSON variable."
  def get_variable_json(instance, feature, variable, context \\ %{}, options \\ %{}),
    do: get_variable(instance, feature, variable, context, options)

  @doc "Evaluates a global variable and returns details."
  def evaluate_global_variable(instance, variable_key, context \\ %{}, options \\ %{}) do
    snap = snapshot(instance)
    options = normalize_options(options)

    evaluation_options = %{
      type: :variable,
      variable_key: variable_key,
      context: Map.merge(snap.context, context),
      default_variable_present: Map.has_key?(options, :default_variable_value),
      default_variable_value: Map.get(options, :default_variable_value)
    }

    try do
      evaluation_options =
        Enum.reduce(snap.modules, evaluation_options, fn module, current ->
          if module.before_evaluation, do: module.before_evaluation.(current), else: current
        end)

      resolved_key = evaluation_options.variable_key
      variable = get_in(snap.datafile, ["variables", resolved_key])
      sticky = Map.get(options, :__child_sticky_variables, snap.sticky_variables || %{})

      evaluation =
        cond do
          Map.has_key?(sticky, resolved_key) ->
            %Featurevisor.Evaluation{
              type: :variable,
              variable_key: resolved_key,
              variable: variable,
              variable_value: sticky[resolved_key],
              reason: :sticky
            }

          variable &&
              not required_features_match?(
                instance,
                variable["requiredFeatures"],
                evaluation_options.context,
                options
              ) ->
            value =
              if variable["useDefaultWhenDisabled"],
                do: variable["defaultValue"],
                else: variable["disabledValue"]

            %Featurevisor.Evaluation{
              type: :variable,
              variable_key: resolved_key,
              variable: variable,
              variable_value: value,
              reason: :required_features_unmet
            }

          variable ->
            case matched_global_override(
                   instance,
                   snap,
                   variable["overrides"] || [],
                   evaluation_options.context,
                   options
                 ) do
              {override, index} ->
                %Featurevisor.Evaluation{
                  type: :variable,
                  variable_key: resolved_key,
                  variable: variable,
                  variable_value: override["value"],
                  variable_override_index: index,
                  variable_override_key: override["key"],
                  variable_override_path: override["keyPath"],
                  reason: :variable_override_rule
                }

              nil ->
                %Featurevisor.Evaluation{
                  type: :variable,
                  variable_key: resolved_key,
                  variable: variable,
                  variable_value: variable["defaultValue"],
                  reason: :variable_default
                }
            end

          true ->
            %Featurevisor.Evaluation{
              type: :variable,
              variable_key: resolved_key,
              reason: :variable_not_found
            }
        end

      value_present =
        case evaluation.reason do
          :sticky ->
            true

          :variable_override_rule ->
            true

          :variable_default ->
            variable && Map.has_key?(variable, "defaultValue")

          :required_features_unmet ->
            variable &&
              Map.has_key?(
                variable,
                if(variable["useDefaultWhenDisabled"], do: "defaultValue", else: "disabledValue")
              )

          _ ->
            false
        end

      evaluation =
        if not value_present and evaluation_options.default_variable_present,
          do: %{evaluation | variable_value: evaluation_options.default_variable_value},
          else: evaluation

      evaluation =
        Enum.reduce(snap.modules, evaluation, fn module, current ->
          if module.after_evaluation,
            do: module.after_evaluation.(current, evaluation_options),
            else: current
        end)

      if variable && variable["deprecated"] do
        report(instance, %{
          level: :warn,
          code: "variable_deprecated",
          message: "Variable \"#{resolved_key}\" is deprecated",
          details: %{
            variableKey: resolved_key,
            evaluation: Featurevisor.Evaluation.to_map(evaluation)
          }
        })
      end

      report(instance, %{
        level: :debug,
        code: Atom.to_string(evaluation.reason),
        message: "Global variable evaluated",
        details: Featurevisor.Evaluation.to_map(evaluation)
      })

      evaluation
    rescue
      error ->
        evaluation = %Featurevisor.Evaluation{
          type: :variable,
          variable_key: variable_key,
          reason: :error,
          error: error
        }

        report(instance, %{
          level: :error,
          code: "evaluation_error",
          message: "Global variable evaluation failed",
          originalError: error,
          details: Featurevisor.Evaluation.to_map(evaluation)
        })

        evaluation
    end
  end

  @doc "Returns a global variable value or nil. JSON variables are decoded."
  def get_global_variable(instance, variable_key, context \\ %{}, options \\ %{}) do
    evaluation = evaluate_global_variable(instance, variable_key, context, options)
    value = evaluation.variable_value

    if get_in(evaluation.variable || %{}, ["type"]) == "json" and is_binary(value) do
      case Jason.decode(value) do
        {:ok, parsed} -> parsed
        {:error, _error} -> nil
      end
    else
      value
    end
  end

  @doc "Returns a typed boolean global variable."
  def get_global_variable_boolean(instance, key, context \\ %{}, options \\ %{}),
    do: typed(get_global_variable(instance, key, context, options), :boolean)

  @doc "Returns a typed string global variable."
  def get_global_variable_string(instance, key, context \\ %{}, options \\ %{}),
    do: typed(get_global_variable(instance, key, context, options), :string)

  @doc "Returns a typed integer global variable."
  def get_global_variable_integer(instance, key, context \\ %{}, options \\ %{}),
    do: typed(get_global_variable(instance, key, context, options), :integer)

  @doc "Returns a typed numeric global variable."
  def get_global_variable_double(instance, key, context \\ %{}, options \\ %{}),
    do: typed(get_global_variable(instance, key, context, options), :double)

  @doc "Returns a typed list global variable."
  def get_global_variable_array(instance, key, context \\ %{}, options \\ %{}),
    do: typed(get_global_variable(instance, key, context, options), :array)

  @doc "Returns a typed map global variable."
  def get_global_variable_object(instance, key, context \\ %{}, options \\ %{}),
    do: typed(get_global_variable(instance, key, context, options), :object)

  @doc "Returns a decoded JSON global variable."
  def get_global_variable_json(instance, key, context \\ %{}, options \\ %{}),
    do: get_global_variable(instance, key, context, options)

  @doc "Evaluates all or selected features."
  def get_feature_evaluations(instance, context \\ %{}, feature_keys \\ [], options \\ %{}) do
    keys = if feature_keys == [], do: get_feature_keys(instance), else: feature_keys

    Map.new(keys, fn key ->
      value = %{enabled: enabled?(instance, key, context, options)}

      value =
        if has_variations?(instance, key),
          do: Map.put(value, :variation, get_variation(instance, key, context, options)),
          else: value

      variable_keys = get_variable_keys(instance, key)

      value =
        if variable_keys == [],
          do: value,
          else:
            Map.put(
              value,
              :variables,
              Map.new(variable_keys, &{&1, get_variable(instance, key, &1, context, options)})
            )

      {key, value}
    end)
  end

  @doc "Evaluates all or selected global variables."
  def get_global_variable_evaluations(
        instance,
        context \\ %{},
        variable_keys \\ [],
        options \\ %{}
      ) do
    keys = if variable_keys == [], do: get_global_variable_keys(instance), else: variable_keys
    Map.new(keys, &{&1, get_global_variable(instance, &1, context, options)})
  end

  @doc "Deprecated alias for get_feature_evaluations/4."
  @deprecated "Use get_feature_evaluations/4"
  def get_all_evaluations(instance, context \\ %{}, feature_keys \\ [], options \\ %{}),
    do: get_feature_evaluations(instance, context, feature_keys, options)

  @doc false
  def segment_matches?(instance, segment_key, context \\ %{}) do
    snap = snapshot(instance)

    Conditions.all_segments?(
      segment_key,
      Map.merge(snap.context, context),
      snap.datafile["segments"],
      snap.regex_cache,
      reporter(instance)
    )
  end

  @doc "Registers an SDK module. Returns an idempotent removal function or nil."
  def add_module(instance, %Module{} = original) do
    if open?(instance), do: add_live_module(instance, original), else: nil
  end

  defp add_live_module(instance, original) do
    module = Server.module_id(original)

    duplicate =
      Server.update(instance.pid, fn state ->
        duplicate =
          module.name &&
            (Enum.any?(state.modules, &(&1.name == module.name)) or
               Enum.any?(state.pending_modules, &(&1.name == module.name)))

        if duplicate do
          {true, state}
        else
          {false, %{state | pending_modules: state.pending_modules ++ [module]}}
        end
      end)

    if duplicate do
      report(instance, %{
        level: :error,
        code: "duplicate_module",
        message: "Duplicate module name",
        moduleName: module.name,
        details: %{}
      })

      nil
    else
      try do
        if module.setup, do: module.setup.(module_api(instance, module))

        Server.update(instance.pid, fn state ->
          {:ok,
           %{
             state
             | modules: state.modules ++ [module],
               pending_modules: Enum.reject(state.pending_modules, &(&1.id == module.id))
           }}
        end)

        once(fn ->
          if Process.alive?(instance.pid), do: remove_module_by_id(instance, module.id), else: :ok
        end)
      rescue
        error ->
          clear_pending_module(instance, module.id)
          clear_module_subscriptions(instance, module.id)

          report(instance, %{
            level: :error,
            code: "module_setup_error",
            message: "Module setup failed",
            moduleName: module.name,
            originalError: error,
            details: %{}
          })

          close_module(instance, module)
          nil
      end
    end
  end

  @doc "Removes every module with the supplied name."
  def remove_module(instance, name) do
    if open?(instance), do: remove_live_module(instance, name), else: :ok
  end

  defp remove_live_module(instance, name) do
    modules =
      Server.update(instance.pid, fn state ->
        {removed, retained} = Enum.split_with(state.modules, &(&1.name == name))

        subscriptions =
          Enum.reject(state.subscriptions, fn sub ->
            Enum.any?(removed, &(&1.id == sub.source))
          end)

        {removed, %{state | modules: retained, subscriptions: subscriptions}}
      end)

    Enum.each(modules, &close_module(instance, &1))
    :ok
  end

  @doc "Subscribes to an event and returns an idempotent unsubscribe function."
  def on(instance, event, callback)
      when event in [:datafile_set, :context_set, :sticky_set, :sticky_variables_set, :error] and
             is_function(callback, 1) do
    if open?(instance) do
      subscribe_to_event(instance, event, callback)
    else
      once(fn -> :ok end)
    end
  end

  defp subscribe_to_event(instance, event, callback) do
    id = make_ref()

    Server.update(instance.pid, fn state ->
      listeners = Map.update(state.listeners, event, [{id, callback}], &(&1 ++ [{id, callback}]))
      {:ok, %{state | listeners: listeners}}
    end)

    once(fn ->
      if Process.alive?(instance.pid) do
        Server.update(instance.pid, fn state ->
          {nil,
           %{
             state
             | listeners:
                 Map.update(
                   state.listeners,
                   event,
                   [],
                   &Enum.reject(&1, fn {current, _} -> current == id end)
                 )
           }}
        end)
      else
        :ok
      end
    end)
  end

  @doc "Spawns a child instance with isolated context and sticky state."
  def spawn(instance, context \\ %{}, options \\ %{}),
    do: Featurevisor.Child.create(instance, context, options)

  @doc "Closes modules, subscriptions, listeners, caches, and the instance owner."
  def close(instance) do
    if open?(instance) do
      modules = Server.close(instance.pid)
      Enum.each(modules, &close_module(instance, &1))
      if Process.alive?(instance.pid), do: GenServer.stop(instance.pid, :normal)
    end

    :ok
  end

  defp evaluate(instance, type, feature_key, variable_key, context, options) do
    snap = snapshot(instance)
    options = normalize_options(options)

    evaluation_options = %{
      type: type,
      feature_key: feature_key,
      variable_key: variable_key,
      context: Map.merge(snap.context, context),
      datafile: snap.datafile,
      regex_cache: snap.regex_cache,
      report: reporter(instance),
      modules: snap.modules,
      sticky: Map.get(options, :__child_sticky_features, snap.sticky_features),
      default_variation_present: Map.has_key?(options, :default_variation_value),
      default_variation_value: Map.get(options, :default_variation_value),
      default_variable_present: Map.has_key?(options, :default_variable_value),
      default_variable_value: Map.get(options, :default_variable_value)
    }

    Evaluator.evaluate_with_modules(evaluation_options)
  end

  defp required_features_match?(_instance, nil, _context, _options), do: true

  defp required_features_match?(instance, requirements, context, options) do
    Enum.all?(requirements, fn requirement ->
      {feature, enabled, variation} =
        if is_binary(requirement) do
          {requirement, true, nil}
        else
          {requirement["feature"] || requirement["key"], Map.get(requirement, "enabled", true),
           requirement["variation"]}
        end

      enabled?(instance, feature, context, options) == enabled and
        (is_nil(variation) or get_variation(instance, feature, context, options) == variation)
    end)
  end

  defp matched_global_override(instance, snap, overrides, context, options) do
    overrides
    |> Enum.with_index()
    |> Enum.find_value(fn {override, index} ->
      requirements_match =
        required_features_match?(instance, override["requiredFeatures"], context, options)

      conditions_match =
        not Map.has_key?(override, "conditions") or
          Conditions.all_conditions?(
            Conditions.parse_conditions(override["conditions"], reporter(instance)),
            context,
            snap.regex_cache,
            reporter(instance)
          )

      segments_match =
        not Map.has_key?(override, "segments") or
          Conditions.all_segments?(
            Conditions.parse_segments(override["segments"]),
            context,
            snap.datafile["segments"],
            snap.regex_cache,
            reporter(instance)
          )

      if requirements_match and conditions_match and segments_match, do: {override, index}
    end)
  end

  defp typed(value, :boolean) when is_boolean(value), do: value
  defp typed(value, :string) when is_binary(value), do: value
  defp typed(value, :integer) when is_integer(value), do: value
  defp typed(value, :integer) when is_float(value) and value == trunc(value), do: trunc(value)
  defp typed(value, :double) when is_number(value), do: value
  defp typed(value, :array) when is_list(value), do: value
  defp typed(value, :object) when is_map(value), do: value
  defp typed(_, _), do: nil

  defp snapshot(instance), do: Server.snapshot(instance.table)
  defp open?(instance), do: Process.alive?(instance.pid) and not snapshot(instance).closed
  defp normalize_options(options) when is_list(options), do: Map.new(options)
  defp normalize_options(options) when is_map(options), do: options

  defp initialize_instance(pid, options) do
    instance = %__MODULE__{pid: pid, table: Server.table(pid)}

    Enum.each(Map.get(options, :modules, []), &add_module(instance, &1))
    if Map.has_key?(options, :datafile), do: set_datafile(instance, options.datafile, true)

    report(instance, %{
      level: :info,
      code: "sdk_initialized",
      message: "SDK initialized",
      details: %{}
    })

    instance
  end

  defp reporter(instance), do: fn diagnostic -> report(instance, diagnostic) end

  defp report(instance, diagnostic, source \\ nil) do
    snap = snapshot(instance)
    diagnostic = diagnostic_struct(diagnostic)

    Enum.each(snap.subscriptions, fn subscription ->
      if subscription.source != source and
           Diagnostic.allowed?(subscription.log_level, diagnostic.level) do
        safely(fn -> subscription.handler.(diagnostic) end)
      end
    end)

    if Diagnostic.allowed?(snap.log_level, diagnostic.level) do
      if snap.on_diagnostic do
        safely(fn -> snap.on_diagnostic.(diagnostic) end)
      else
        default_diagnostic(diagnostic)
      end
    end

    if diagnostic.level == :error, do: trigger(instance, :error, %{diagnostic: diagnostic})
    :ok
  end

  defp diagnostic_struct(%Diagnostic{} = diagnostic),
    do: %{diagnostic | details: diagnostic.details || %{}}

  defp diagnostic_struct(map) do
    %Diagnostic{
      level: map[:level] || map["level"],
      code: map[:code] || map["code"],
      message: map[:message] || map["message"],
      module: map[:module] || map["module"],
      module_name: map[:moduleName] || map[:module_name] || map["moduleName"],
      original_error: map[:originalError] || map[:original_error] || map["originalError"],
      details: map[:details] || map["details"] || %{}
    }
  end

  defp default_diagnostic(%Diagnostic{level: level} = diagnostic) when level in [:fatal, :error],
    do: IO.puts(:stderr, "[Featurevisor] #{diagnostic.message}")

  defp default_diagnostic(%Diagnostic{level: :warn} = diagnostic),
    do: Logger.warning("[Featurevisor] #{diagnostic.message}")

  defp default_diagnostic(%Diagnostic{level: :info} = diagnostic),
    do: Logger.info("[Featurevisor] #{diagnostic.message}")

  defp default_diagnostic(%Diagnostic{level: :debug} = diagnostic),
    do: Logger.debug("[Featurevisor] #{diagnostic.message}")

  defp trigger(instance, event, details) do
    snapshot(instance).listeners
    |> Map.get(event, [])
    |> Enum.each(fn {_id, callback} -> safely(fn -> callback.(details) end) end)
  end

  defp module_api(instance, module) do
    %{
      get_revision: fn -> get_revision(instance) end,
      on_diagnostic: fn handler, options ->
        options = normalize_options(options)
        id = make_ref()

        Server.update(instance.pid, fn state ->
          sub = %{
            id: id,
            source: module.id,
            handler: handler,
            log_level: Map.get(options, :log_level, :info)
          }

          {:ok, %{state | subscriptions: state.subscriptions ++ [sub]}}
        end)

        once(fn ->
          if Process.alive?(instance.pid) do
            Server.update(instance.pid, fn state ->
              {nil, %{state | subscriptions: Enum.reject(state.subscriptions, &(&1.id == id))}}
            end)
          else
            :ok
          end
        end)
      end,
      report_diagnostic: fn diagnostic ->
        value =
          if is_struct(diagnostic, Diagnostic), do: Map.from_struct(diagnostic), else: diagnostic

        value = value |> Map.put(:module, module.name) |> Map.put_new(:details, %{})
        report(instance, value, module.id)
      end
    }
  end

  defp remove_module_by_id(instance, id) do
    modules =
      Server.update(instance.pid, fn state ->
        {removed, retained} = Enum.split_with(state.modules, &(&1.id == id))

        {removed,
         %{
           state
           | modules: retained,
             subscriptions: Enum.reject(state.subscriptions, &(&1.source == id))
         }}
      end)

    Enum.each(modules, &close_module(instance, &1))
    :ok
  end

  defp clear_module_subscriptions(instance, id),
    do:
      Server.update(instance.pid, fn state ->
        {nil, %{state | subscriptions: Enum.reject(state.subscriptions, &(&1.source == id))}}
      end)

  defp clear_pending_module(instance, id),
    do:
      Server.update(instance.pid, fn state ->
        {nil, %{state | pending_modules: Enum.reject(state.pending_modules, &(&1.id == id))}}
      end)

  defp close_module(instance, module) do
    if module.close do
      try do
        module.close.()
      rescue
        error ->
          report(instance, %{
            level: :error,
            code: "module_close_error",
            message: "Module close failed",
            moduleName: module.name,
            originalError: error,
            details: %{}
          })
      end
    end
  end

  defp safely(fun) do
    fun.()
  rescue
    error -> IO.puts(:stderr, "[Featurevisor] Callback failed: #{Exception.message(error)}")
  end

  defp once(fun) do
    ref = :atomics.new(1, [])
    fn -> if :atomics.compare_exchange(ref, 1, 0, 1) == :ok, do: fun.(), else: :ok end
  end
end
