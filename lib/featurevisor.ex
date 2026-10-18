defmodule Featurevisor do
  @moduledoc """
  Feature flags, experiments, and remote configuration for Elixir.

  Create an isolated instance with `create_featurevisor/1`, then evaluate flags,
  variations, and variables against a Featurevisor schema version 4 or legacy schema version 2 datafile.
  """

  alias Featurevisor.{
    Conditions,
    Diagnostic,
    EvaluationSession,
    Evaluator,
    Module,
    Mutations,
    Server,
    StickyStore
  }

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

  @doc """
  Merges or replaces the stored datafile.

  Returns true when accepted, including unchanged input, or false when rejected or closed.
  """
  @spec set_datafile(t(), map() | String.t(), boolean()) :: boolean()
  def set_datafile(instance, input, replace \\ false) do
    if open?(instance), do: set_live_datafile(instance, input, replace), else: false
  end

  defp set_live_datafile(instance, input, replace) do
    with {:ok, datafile} <- Server.parse_datafile(input),
         true <- Server.valid_datafile?(datafile),
         {datafile, errors} <- Featurevisor.Normalize.datafile(datafile),
         {:ok, details} <- store_datafile(instance, datafile, replace) do
      Enum.each(errors, &report(instance, &1))

      report(instance, %{
        level: :info,
        code: "datafile_set",
        message: "Datafile set",
        details: details
      })

      trigger(instance, :datafile_set, details)
      true
    else
      :closed ->
        false

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

        false
    end
  end

  defp store_datafile(instance, datafile, replace) do
    Server.set_datafile(instance.pid, datafile, replace)
  catch
    :exit, reason ->
      if open?(instance), do: exit(reason), else: :closed
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

    report(instance, %{
      level: :info,
      code: "sticky_features_set",
      message: "Sticky features set",
      details: details
    })

    trigger(instance, :sticky_features_set, details)

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

      report(instance, %{
        level: :info,
        code: "sticky_variables_set",
        message: "Sticky variables set",
        details: details
      })

      trigger(instance, :sticky_variables_set, details)
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
  def get_feature(instance, key),
    do:
      Server.with_snapshot(instance.table, fn snap ->
        Featurevisor.Normalize.get(
          snap.datafile,
          "features",
          key,
          snap.regex_cache,
          reporter(instance)
        )
        |> Featurevisor.Normalize.public()
      end)

  @doc "Returns a segment definition."
  def get_segment(instance, key),
    do:
      Server.with_snapshot(instance.table, fn snap ->
        Featurevisor.Normalize.get(
          snap.datafile,
          "segments",
          key,
          snap.regex_cache,
          reporter(instance)
        )
        |> Featurevisor.Normalize.public()
      end)

  @doc "Returns all feature keys. Ordering is not guaranteed."
  def get_feature_keys(instance),
    do:
      Server.with_snapshot(
        instance.table,
        &Featurevisor.EntityCollection.keys(&1.datafile["features"])
      )

  @doc "Returns variable keys for a feature."
  def get_variable_keys(instance, key),
    do: instance |> get_feature(key) |> then(&Map.keys((&1 && &1["variablesSchema"]) || %{}))

  @doc "Returns all global variable keys. Ordering is not guaranteed."
  def get_global_variable_keys(instance),
    do:
      Server.with_snapshot(
        instance.table,
        &Featurevisor.EntityCollection.keys(&1.datafile["variables"] || %{})
      )

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

    if not evaluation.__getter_value_normalized and
         get_in(evaluation.variable_schema || %{}, ["type"]) == "json" and is_binary(value) do
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

  @doc "Returns a finite number variable, whole or fractional, after runtime type checking."
  def get_variable_number(instance, feature, variable, context \\ %{}, options \\ %{}),
    do: typed(get_variable(instance, feature, variable, context, options), :number)

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
    Server.with_snapshot(instance.table, fn snap ->
      evaluate_global_snapshot(instance, snap, variable_key, context, options)
    end)
  end

  defp evaluate_global_snapshot(instance, snap, variable_key, context, options) do
    options = normalize_options(options)
    options = evaluation_sources(instance, options)

    with_request_session(options, fn options ->
      Server.seed_request_cache(instance.table, snap)
      session = options.__session

      evaluation_options = %{
        type: :variable,
        variable_key: variable_key,
        dependency_purpose: options[:__dependency_purpose],
        context: effective_context(snap, context, options),
        default_variable_present: Map.has_key?(options, :default_variable_value),
        default_variable_value: Map.get(options, :default_variable_value)
      }

      evaluation_options =
        if snap.modules == [] do
          evaluation_options
        else
          Map.merge(evaluation_options, %{
            sticky_features: StickyStore.materialize(options.__sticky_features_source.()),
            sticky_variables: StickyStore.materialize(options.__sticky_variables_source.())
          })
        end

      memo_options =
        Map.merge(evaluation_options, %{
          sticky_owner: true,
          sticky_features_token: options[:__sticky_features_token],
          sticky_variables_token: options[:__sticky_variables_token],
          regex_cache: snap.regex_cache,
          report: reporter(instance),
          state_signature: options.__state_signature,
          child_signature: options[:__child_signature]
        })

      try do
        EvaluationSession.run(
          session,
          memo_options,
          options[:__prerequisite] == true,
          fn evaluation_options ->
            {evaluation_options, resolved_options} =
              if snap.modules == [],
                do: {evaluation_options, options},
                else:
                  before_global_modules(snap.modules, evaluation_options, memo_options, options)

            if snap.modules != [],
              do: EvaluationSession.update_current(session, evaluation_options)

            resolved_key = evaluation_options.variable_key

            variable =
              read_entity(instance, "variables", resolved_key)

            sticky = resolved_options.__sticky_variables_source.() || %{}

            evaluation =
              cond do
                StickyStore.has_key?(sticky, resolved_key) ->
                  %Featurevisor.Evaluation{
                    type: :variable,
                    variable_key: resolved_key,
                    variable: variable,
                    variable_value: sticky[resolved_key],
                    reason: :sticky
                  }

                variable ->
                  evaluate_global_variable_definition(
                    instance,
                    snap,
                    resolved_key,
                    variable,
                    evaluation_options.context,
                    resolved_options
                  )

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

                reason when reason in [:variable_override_rule, :variable_composed] ->
                  true

                :variable_default ->
                  variable && Map.has_key?(variable, "defaultValue")

                :conditions_unmet ->
                  Map.has_key?(variable, "compose") or
                    Map.has_key?(
                      variable,
                      if(variable["useDefaultWhenDisabled"],
                        do: "defaultValue",
                        else: "disabledValue"
                      )
                    )

                _ ->
                  false
              end

            evaluation =
              if not value_present and evaluation_options.default_variable_present,
                do: %{evaluation | variable_value: evaluation_options.default_variable_value},
                else: evaluation

            modules = Server.snapshot(instance.table).modules

            after_options =
              if modules == [] do
                evaluation_options
              else
                evaluation_options
                |> Map.drop([
                  :sticky_owner,
                  :sticky_features_token,
                  :sticky_variables_token,
                  :regex_cache,
                  :report,
                  :state_signature,
                  :child_signature
                ])
                |> Map.put_new_lazy(:sticky_features, fn ->
                  StickyStore.materialize(resolved_options.__sticky_features_source.())
                end)
                |> Map.put_new_lazy(:sticky_variables, fn ->
                  StickyStore.materialize(resolved_options.__sticky_variables_source.())
                end)
              end

            evaluation =
              Enum.reduce(modules, evaluation, fn module, current ->
                if module.after_evaluation,
                  do: module.after_evaluation.(current, after_options),
                  else: current
              end)

            if variable && variable["deprecated"] do
              report(instance, %{
                level: :warn,
                code: "deprecated_variable",
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
          end
        )
      rescue
        error ->
          if (match?(%Featurevisor.RequirementCycleError{}, error) or
                match?(%Featurevisor.RequirementError{}, error)) and
               options[:__prerequisite] == true,
             do: reraise(error, __STACKTRACE__)

          evaluation = %Featurevisor.Evaluation{
            type: :variable,
            variable_key: variable_key,
            reason: :error,
            error: error
          }

          EvaluationSession.remember(
            session,
            memo_options,
            evaluation,
            options[:__prerequisite] == true
          )

          report(instance, %{
            level: :error,
            code: "evaluation_error",
            message: "Global variable evaluation failed",
            originalError: error,
            details: Featurevisor.Evaluation.to_map(evaluation)
          })

          evaluation
      end
    end)
  end

  defp before_global_modules(modules, evaluation_options, memo_options, options) do
    evaluation_options =
      Enum.reduce(
        modules,
        Map.drop(evaluation_options, [
          :sticky_owner,
          :sticky_features_token,
          :sticky_variables_token,
          :regex_cache,
          :report,
          :state_signature,
          :child_signature
        ]),
        fn module, current ->
          if module.before_evaluation,
            do: module.before_evaluation.(current),
            else: current
        end
      )

    replaced_features = evaluation_options[:sticky_features] != memo_options[:sticky_features]
    replaced_variables = evaluation_options[:sticky_variables] != memo_options[:sticky_variables]

    if replaced_features or replaced_variables,
      do: EvaluationSession.bypass_memo(options.__session)

    resolved_options =
      options
      |> Map.put(
        :__sticky_features_source,
        if(replaced_features,
          do: fn -> evaluation_options[:sticky_features] end,
          else: options.__sticky_features_source
        )
      )
      |> Map.put(
        :__sticky_variables_source,
        if(replaced_variables,
          do: fn -> evaluation_options[:sticky_variables] end,
          else: options.__sticky_variables_source
        )
      )
      |> Map.put(
        :__sticky_features_token,
        if(replaced_features, do: make_ref(), else: options[:__sticky_features_token])
      )
      |> Map.put(
        :__sticky_variables_token,
        if(replaced_variables, do: make_ref(), else: options[:__sticky_variables_token])
      )

    {evaluation_options, resolved_options}
  end

  @doc "Returns a global variable value or nil. JSON variables are decoded."
  def get_global_variable(instance, variable_key, context \\ %{}, options \\ %{}) do
    evaluation = evaluate_global_variable(instance, variable_key, context, options)
    value = evaluation.variable_value

    if ((not evaluation.__getter_value_normalized and is_nil(evaluation.variable["compose"])) &&
          get_in(evaluation.variable || %{}, ["type"]) == "json") and is_binary(value) do
      case Jason.decode(value) do
        {:ok, parsed} ->
          parsed

        {:error, error} ->
          report(instance, %{
            level: :error,
            code: "evaluation_error",
            message: "getVariable failed",
            originalError: error,
            details: %{variableKey: variable_key}
          })

          nil
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

  @doc "Returns a typed number global variable, whole or fractional."
  def get_global_variable_number(instance, key, context \\ %{}, options \\ %{}),
    do: typed(get_global_variable(instance, key, context, options), :number)

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
      when event in [
             :datafile_set,
             :context_set,
             :sticky_features_set,
             :sticky_variables_set,
             :error
           ] and
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
    Server.with_snapshot(instance.table, fn snap ->
      evaluate_snapshot(instance, snap, type, feature_key, variable_key, context, options)
    end)
  end

  defp evaluate_snapshot(instance, snap, type, feature_key, variable_key, context, options) do
    options = normalize_options(options)
    options = evaluation_sources(instance, options)

    with_request_session(options, fn options ->
      Server.seed_request_cache(instance.table, snap)
      session = options.__session

      evaluation_options = %{
        type: type,
        feature_key: feature_key,
        variable_key: variable_key,
        context: effective_context(snap, context, options),
        # Preserve ordinary maps in callback options. The common path without
        # modules reads only the entity rows it actually needs.
        datafile:
          if(snap.modules == [],
            do: snap.datafile,
            else: Server.materialize_datafile(snap.datafile)
          ),
        regex_cache: snap.regex_cache,
        report: reporter(instance),
        modules: snap.modules,
        sticky_features:
          if(snap.modules == [],
            do: options.__sticky_features_source.(),
            else: StickyStore.materialize(options.__sticky_features_source.())
          ),
        sticky_variables:
          if(snap.modules == [],
            do: options.__sticky_variables_source.(),
            else: StickyStore.materialize(options.__sticky_variables_source.())
          ),
        sticky_owner: true,
        sticky_features_token: options[:__sticky_features_token],
        sticky_variables_token: options[:__sticky_variables_token],
        session: session,
        prerequisite: options[:__prerequisite] == true,
        dependency_purpose: options[:__dependency_purpose],
        state_signature: options.__state_signature,
        state_source: fn -> Server.snapshot(instance.table) end,
        entity_source: fn kind, key -> read_entity(instance, kind, key) end,
        child_signature: options[:__child_signature],
        sticky_features_source: options.__sticky_features_source,
        sticky_variables_source: options.__sticky_variables_source,
        condition_leaf: fn condition, dependencies ->
          condition_leaf?(instance, condition, dependencies)
        end,
        default_variation_present: Map.has_key?(options, :default_variation_value),
        default_variation_value: Map.get(options, :default_variation_value),
        default_variable_present: Map.has_key?(options, :default_variable_value),
        default_variable_value: Map.get(options, :default_variable_value)
      }

      try do
        Evaluator.evaluate_with_modules(evaluation_options)
      rescue
        error in [Featurevisor.RequirementCycleError, Featurevisor.RequirementError] ->
          if options[:__prerequisite] == true do
            reraise error, __STACKTRACE__
          else
            evaluation = %Featurevisor.Evaluation{
              type: type,
              feature_key: feature_key,
              variable_key: variable_key,
              reason: :error,
              error: error
            }

            report(instance, %{
              level: :error,
              code: "evaluation_error",
              message: "Evaluation failed",
              originalError: error,
              details: Featurevisor.Evaluation.to_map(evaluation)
            })

            evaluation
          end
      end
    end)
  end

  defp effective_context(snap, context, options) do
    if options[:__effective_context], do: context, else: Map.merge(snap.context, context)
  end

  defp read_entity(instance, kind, key) do
    Server.with_snapshot(instance.table, fn snap ->
      Featurevisor.Normalize.get(snap.datafile, kind, key, snap.regex_cache, reporter(instance))
    end)
  end

  defp global_dependencies(instance, snap, context, options) do
    %{
      context: context,
      datafile: snap.datafile,
      regex_cache: snap.regex_cache,
      report: reporter(instance),
      session: options[:__session],
      entity_source: fn kind, key -> read_entity(instance, kind, key) end,
      sticky_features: options.__sticky_features_source.(),
      sticky_variables: options.__sticky_variables_source.(),
      sticky_features_source: options.__sticky_features_source,
      sticky_variables_source: options.__sticky_variables_source,
      sticky_features_token: options[:__sticky_features_token],
      sticky_variables_token: options[:__sticky_variables_token],
      child_signature: options[:__child_signature],
      condition_leaf: fn condition, dependencies ->
        condition_leaf?(instance, condition, dependencies)
      end
    }
  end

  defp evaluate_global_variable_definition(instance, snap, key, variable, context, options) do
    if Map.has_key?(variable, "conditions") and
         not Conditions.matches?(
           variable["conditions"],
           global_dependencies(instance, snap, context, options)
         ) do
      value_key =
        if is_nil(variable["compose"]) && variable["useDefaultWhenDisabled"],
          do: "defaultValue",
          else: "disabledValue"

      %Featurevisor.Evaluation{
        type: :variable,
        variable_key: key,
        variable: variable,
        variable_value: variable[value_key],
        reason: :conditions_unmet,
        conditions: Featurevisor.Normalize.public(variable["conditions"])
      }
    else
      initial =
        if Map.has_key?(variable, "compose") do
          %Featurevisor.Evaluation{
            type: :variable,
            variable_key: key,
            variable: variable,
            variable_value:
              compose(
                instance,
                variable["compose"],
                global_dependencies(instance, snap, context, options)
              ),
            reason: :variable_composed
          }
        else
          default_global_variable_evaluation(key, variable)
        end

      cond do
        not is_nil(variable["overrideProgram"]) ->
          evaluate_override_program(
            instance,
            snap,
            key,
            variable,
            variable["overrideProgram"],
            context,
            Map.put(options, :__initial_evaluation, initial)
          )

        variable["compose"] ->
          initial

        true ->
          case matched_global_override(
                 instance,
                 snap,
                 variable["overrides"] || [],
                 context,
                 options
               ) do
            {override, index} ->
              %{
                initial
                | variable_value: override["value"],
                  variable_override_index: index,
                  variable_override_key: override["key"],
                  variable_override_path: override["keyPath"],
                  reason: :variable_override_rule
              }

            nil ->
              initial
          end
      end
    end
  end

  defp compose(instance, source, dependencies) when is_binary(source) and source != "",
    do: dependency_value(instance, %{"variable" => source}, dependencies, :composition)

  defp compose(instance, entries, dependencies) when is_list(entries) and entries != [] do
    Map.new(entries, fn entry ->
      key = entry["key"]

      if not is_binary(key) or key in ["", "__proto__", "prototype", "constructor"],
        do: raise(Featurevisor.RequirementCycleError, message: "Invalid composition property")

      {key, dependency_value(instance, entry, dependencies, :composition)}
    end)
  end

  defp compose(_, _, _),
    do: raise(Featurevisor.RequirementCycleError, message: "Invalid composition")

  defp evaluate_override_program(instance, snap, key, variable, program, context, options)
       when is_list(program) do
    config = %{
      instance: instance,
      snap: snap,
      key: key,
      variable: variable,
      program: program,
      context: context,
      options: options
    }

    evaluate_override_step(config, %{
      index: 0,
      value: options.__initial_evaluation.variable_value,
      paths: [],
      evaluation: options.__initial_evaluation
    })
  end

  defp evaluate_override_program(_instance, _snap, _key, _variable, _program, _context, _options),
    do: raise(ArgumentError, "Invalid variable override program")

  defp evaluate_override_step(config, state) do
    if state.index == length(config.program) do
      state.evaluation
    else
      apply_override_step(config, state)
    end
  end

  defp apply_override_step(config, state) do
    override = Enum.at(config.program, state.index)

    unless is_map(override), do: raise(ArgumentError, "Invalid variable override program")

    matched =
      global_override_matches?(
        config.instance,
        config.snap,
        override,
        config.context,
        config.options
      )

    {value, paths, evaluation} =
      if matched do
        next_value = Mutations.apply(state.value, override["operations"])
        next_paths = state.paths ++ [override["keyPath"] || [override["key"]]]

        {next_value, next_paths,
         %Featurevisor.Evaluation{
           type: :variable,
           variable_key: config.key,
           variable: config.variable,
           variable_value: next_value,
           variable_override_index: state.index,
           variable_override_key: override["key"],
           variable_override_path: override["keyPath"],
           variable_override_paths: next_paths,
           reason: :variable_override_rule
         }}
      else
        {state.value, state.paths, state.evaluation}
      end

    next_index = override[if(matched, do: "onMatch", else: "onMiss")]

    unless is_integer(next_index) and next_index > state.index and
             next_index <= length(config.program) do
      raise ArgumentError, "Invalid variable override program jump"
    end

    evaluate_override_step(config, %{
      index: next_index,
      value: value,
      paths: paths,
      evaluation: evaluation
    })
  end

  defp default_global_variable_evaluation(key, variable) do
    %Featurevisor.Evaluation{
      type: :variable,
      variable_key: key,
      variable: variable,
      variable_value: variable["defaultValue"],
      reason: :variable_default
    }
  end

  defp condition_leaf?(instance, %{"variable" => _} = condition, dependencies) do
    value = dependency_value(instance, condition, dependencies, :condition)

    try do
      {value, present} = required_path_value(value, Map.get(condition, "path", []))
      Conditions.value_matches?(value, condition, dependencies.regex_cache, present)
    rescue
      error ->
        reraise Featurevisor.RequirementError, [message: Exception.message(error)], __STACKTRACE__
    end
  end

  defp condition_leaf?(instance, %{"feature" => _} = condition, dependencies) do
    dependency_value(instance, Map.delete(condition, "variation"), dependencies, :condition) ==
      Map.get(condition, "enabled", true) and
      (not Map.has_key?(condition, "variation") or
         dependency_value(
           instance,
           Map.put(condition, "variation", true),
           dependencies,
           :condition
         ) == condition["variation"])
  end

  defp dependency_value(instance, reference, dependencies, purpose) do
    features_source =
      if dependencies[:sticky_features_token],
        do: fn -> dependencies.sticky_features end,
        else: dependencies[:sticky_features_source]

    variables_source =
      if dependencies[:sticky_variables_token],
        do: fn -> dependencies.sticky_variables end,
        else: dependencies[:sticky_variables_source]

    getter_options = %{
      __sticky_features_source: features_source,
      __sticky_variables_source: variables_source,
      __sticky_features_token: dependencies[:sticky_features_token],
      __sticky_variables_token: dependencies[:sticky_variables_token],
      __child_signature: dependencies[:child_signature],
      __session: dependencies[:session],
      __prerequisite: true,
      __effective_context: true,
      __dependency_purpose: purpose
    }

    cond do
      Map.has_key?(reference, "variable") and Map.has_key?(reference, "feature") ->
        get_variable(
          instance,
          reference["feature"],
          reference["variable"],
          dependencies.context,
          getter_options
        )

      Map.has_key?(reference, "variable") ->
        get_global_variable(
          instance,
          reference["variable"],
          dependencies.context,
          getter_options
        )

      reference["variation"] == true ->
        get_variation(instance, reference["feature"], dependencies.context, getter_options)

      true ->
        enabled?(instance, reference["feature"], dependencies.context, getter_options)
    end
  end

  defp required_path_value(value, path) when is_list(path) do
    Enum.reduce_while(path, {value, true}, fn part, {current, _present} ->
      case required_path_part(current, part) do
        {:ok, next} -> {:cont, {next, true}}
        :missing -> {:halt, {nil, false}}
      end
    end)
  end

  defp required_path_value(_value, _path),
    do: raise(ArgumentError, "Variable requirement path must be compiled")

  defp required_path_part(value, part) when is_binary(part) and is_map(value) do
    if part in ["__proto__", "prototype", "constructor"] do
      raise ArgumentError, "Unsafe variable requirement path"
    end

    Map.fetch(value, part)
    |> case do
      {:ok, next} -> {:ok, next}
      :error -> :missing
    end
  end

  defp required_path_part(value, "length") when is_list(value), do: {:ok, length(value)}

  defp required_path_part(value, part) when is_binary(part) and is_list(value) do
    if Regex.match?(~r/^(0|[1-9][0-9]*)$/, part) do
      required_path_part(value, String.to_integer(part))
    else
      :missing
    end
  end

  defp required_path_part(value, part) when is_number(part) do
    case safe_array_index(part) do
      {:ok, index} when is_list(value) ->
        if index < length(value), do: {:ok, Enum.at(value, index)}, else: :missing

      {:ok, _index} ->
        :missing

      :error ->
        raise ArgumentError, "Invalid variable requirement path"
    end
  end

  defp required_path_part(_value, part) when is_binary(part), do: :missing

  defp required_path_part(_value, _part),
    do: raise(ArgumentError, "Invalid variable requirement path")

  defp safe_array_index(value)
       when is_integer(value) and value >= 0 and value <= 9_007_199_254_740_991,
       do: {:ok, value}

  defp safe_array_index(value) when is_float(value) do
    if abs(value) < 1.797_693_134_862_315_7e308 and value >= 0 and
         value <= 9_007_199_254_740_991 and value == trunc(value),
       do: {:ok, trunc(value)},
       else: :error
  end

  defp safe_array_index(_value), do: :error

  defp matched_global_override(instance, snap, overrides, context, options) do
    overrides
    |> Enum.with_index()
    |> Enum.find_value(fn {override, index} ->
      if global_override_matches?(instance, snap, override, context, options),
        do: {override, index}
    end)
  end

  defp global_override_matches?(instance, snap, override, context, options) do
    not Map.has_key?(override, "conditions") or
      Conditions.matches?(
        override["conditions"],
        global_dependencies(instance, snap, context, options)
      )
  end

  defp typed(value, :boolean) when is_boolean(value), do: value
  defp typed(value, :string) when is_binary(value), do: value
  defp typed(value, :integer) when is_integer(value), do: value
  defp typed(value, :integer) when is_float(value) and value == trunc(value), do: trunc(value)
  defp typed(value, :number) when is_number(value), do: value
  defp typed(value, :array) when is_list(value), do: value
  defp typed(value, :object) when is_map(value), do: value
  defp typed(_, _), do: nil

  defp snapshot(instance), do: Server.snapshot(instance.table)
  defp open?(instance), do: Process.alive?(instance.pid) and not snapshot(instance).closed
  defp normalize_options(options) when is_list(options), do: Map.new(options)
  defp normalize_options(options) when is_map(options), do: options

  defp evaluation_sources(instance, options) do
    options
    |> Map.put_new(:__sticky_features_source, fn ->
      Server.snapshot(instance.table).sticky_features
    end)
    |> Map.put_new(:__sticky_variables_source, fn ->
      Server.snapshot(instance.table).sticky_variables
    end)
    |> Map.put_new(:__state_signature, fn ->
      snap = Server.snapshot(instance.table)

      {snap.regex_cache, snap.generation}
    end)
  end

  defp with_request_session(options, fun) do
    case options[:__session] do
      nil ->
        session = EvaluationSession.new()

        try do
          Server.with_request_cache(fn ->
            Featurevisor.Child.with_request_cache(options[:__child_snapshot], fn ->
              fun.(Map.put(options, :__session, session))
            end)
          end)
        after
          EvaluationSession.close(session)
        end

      _ ->
        fun.(options)
    end
  end

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
  catch
    kind, reason ->
      IO.puts(:stderr, "[Featurevisor] Callback failed: #{Exception.format_banner(kind, reason)}")
  end

  defp once(fun) do
    ref = :atomics.new(1, [])
    fn -> if :atomics.compare_exchange(ref, 1, 0, 1) == :ok, do: fun.(), else: :ok end
  end
end
