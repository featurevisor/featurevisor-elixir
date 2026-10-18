defmodule Featurevisor.Evaluator do
  @moduledoc false

  alias Featurevisor.{
    Bucketer,
    Conditions,
    Evaluation,
    EvaluationSession,
    RequirementCycleError,
    RequirementError,
    StickyStore
  }

  @private_options [
    :session,
    :prerequisite,
    :state_signature,
    :state_source,
    :entity_source,
    :child_signature,
    :sticky_owner,
    :sticky_features_token,
    :sticky_variables_token,
    :sticky_features_source,
    :sticky_variables_source,
    :condition_leaf,
    :regex_cache,
    :default_variation_present,
    :default_variable_present
  ]

  def evaluate_with_modules(options) do
    options =
      if options[:prerequisite] == true do
        current = options.state_source.()

        options
        |> then(fn options ->
          if options[:sticky_features_token],
            do: options,
            else: Map.put(options, :sticky_features, options.sticky_features_source.())
        end)
        |> then(fn options ->
          if options[:sticky_variables_token],
            do: options,
            else: Map.put(options, :sticky_variables, options.sticky_variables_source.())
        end)
        |> Map.put(:modules, current.modules)
      else
        options
      end

    options =
      if options.modules == [] do
        options
      else
        options
        |> Map.update!(:sticky_features, &StickyStore.materialize/1)
        |> Map.update!(:sticky_variables, &StickyStore.materialize/1)
      end

    EvaluationSession.run(options.session, options, options[:prerequisite] == true, fn options ->
      options =
        if options.modules == [],
          do: refresh_inherited_sticky(options, options, false, false),
          else: before_modules(options)

      if options.modules != [], do: EvaluationSession.update_current(options.session, options)

      evaluation = evaluate(options)
      evaluation = apply_default(evaluation, options)

      modules = options.state_source.().modules

      after_options =
        if modules == [],
          do: options,
          else:
            options
            |> Map.update!(:datafile, &Featurevisor.Server.materialize_datafile/1)
            |> Map.update!(:sticky_features, &StickyStore.materialize/1)
            |> Map.update!(:sticky_variables, &StickyStore.materialize/1)

      Enum.reduce(modules, evaluation, fn module, current ->
        if module.after_evaluation,
          do: module.after_evaluation.(current, Map.drop(after_options, @private_options)),
          else: current
      end)
    end)
  rescue
    error in [RequirementCycleError, RequirementError] ->
      reraise error, __STACKTRACE__

    error ->
      evaluation = %Evaluation{
        type: options.type,
        feature_key: options.feature_key,
        variable_key: options[:variable_key],
        reason: :error,
        error: error
      }

      EvaluationSession.remember(
        options.session,
        options,
        evaluation,
        options[:prerequisite] == true
      )

      report_evaluation(
        options.report,
        evaluation,
        "Error during evaluation",
        :error,
        "evaluation_error"
      )

      evaluation
  end

  defp before_modules(original_options) do
    module_options =
      Enum.reduce(
        original_options.modules,
        Map.drop(original_options, @private_options),
        fn module, current ->
          if module.before_evaluation, do: module.before_evaluation.(current), else: current
        end
      )

    replaced_features = module_options[:sticky_features] != original_options[:sticky_features]
    replaced_variables = module_options[:sticky_variables] != original_options[:sticky_variables]

    if replaced_features or replaced_variables,
      do: EvaluationSession.bypass_memo(original_options.session)

    module_options
    |> Map.drop(@private_options)
    |> Map.merge(Map.take(original_options, @private_options))
    |> refresh_inherited_sticky(original_options, replaced_features, replaced_variables)
  end

  defp refresh_inherited_sticky(options, original_options, replaced_features, replaced_variables) do
    options =
      cond do
        replaced_features ->
          Map.put(options, :sticky_features_token, make_ref())

        original_options[:sticky_features_token] ->
          options

        true ->
          Map.put(options, :sticky_features, original_options.sticky_features_source.())
      end

    cond do
      replaced_variables ->
        Map.put(options, :sticky_variables_token, make_ref())

      original_options[:sticky_variables_token] ->
        options

      true ->
        Map.put(options, :sticky_variables, original_options.sticky_variables_source.())
    end
  end

  defp apply_default(
         %Evaluation{type: :variation, variation: nil, variation_value: nil} = evaluation,
         %{default_variation_present: true} = options
       ),
       do: %{evaluation | variation_value: options.default_variation_value}

  defp apply_default(
         %Evaluation{type: :variable} = evaluation,
         %{default_variable_present: true} = options
       ) do
    if variable_value_present?(evaluation),
      do: evaluation,
      else: %{evaluation | variable_value: options.default_variable_value}
  end

  defp apply_default(evaluation, _), do: evaluation

  defp evaluate(options) do
    type = options.type
    feature_key = options.feature_key
    variable_key = options[:variable_key]

    with :continue <- enabled_dependency(options),
         :continue <- sticky(options),
         {:ok, feature} <- feature(options) do
      evaluate_feature(options, feature)
    else
      {:return, evaluation} ->
        evaluation

      {:error, :feature_not_found} ->
        evaluation = %Evaluation{
          type: type,
          feature_key: feature_key,
          variable_key: variable_key,
          reason: :feature_not_found
        }

        report_evaluation(
          options.report,
          evaluation,
          "Feature not found",
          :warn,
          "feature_not_found"
        )

        evaluation
    end
  rescue
    error in [RequirementCycleError, RequirementError] ->
      reraise error, __STACKTRACE__

    error ->
      evaluation = %Evaluation{
        type: options.type,
        feature_key: options.feature_key,
        variable_key: options[:variable_key],
        reason: :error,
        error: error
      }

      report_evaluation(
        options.report,
        evaluation,
        "Error during evaluation",
        :error,
        "evaluation_error"
      )

      evaluation
  end

  defp enabled_dependency(%{type: :flag}), do: :continue

  defp enabled_dependency(options) do
    flag = evaluate(%{options | type: :flag})
    if flag.enabled == false, do: {:return, disabled_evaluation(options)}, else: :continue
  end

  defp disabled_evaluation(options) do
    feature = read_feature(options)

    base = %Evaluation{
      type: options.type,
      feature_key: options.feature_key,
      variable_key: options[:variable_key],
      reason: :disabled
    }

    evaluation =
      cond do
        (options.type == :variable and feature) && options[:variable_key] &&
            get_in(feature, ["variablesSchema", options.variable_key]) ->
          schema = get_in(feature, ["variablesSchema", options.variable_key])

          cond do
            Map.has_key?(schema, "disabledValue") ->
              %{
                base
                | reason: :variable_disabled,
                  variable_schema: schema,
                  variable_value: schema["disabledValue"],
                  enabled: false
              }

            schema["useDefaultWhenDisabled"] ->
              %{
                base
                | reason: :variable_default,
                  variable_schema: schema,
                  variable_value: schema["defaultValue"],
                  enabled: false
              }

            true ->
              base
          end

        (options.type == :variation and feature) &&
            Map.has_key?(feature, "disabledVariationValue") ->
          %{
            base
            | reason: :variation_disabled,
              variation_value: feature["disabledVariationValue"],
              enabled: false
          }

        true ->
          base
      end

    report_evaluation(options.report, evaluation, "feature is disabled")
    evaluation
  end

  defp sticky(options) do
    sticky = options.sticky_features && options.sticky_features[options.feature_key]

    cond do
      is_nil(sticky) ->
        :continue

      options.type == :flag and Map.has_key?(sticky, "enabled") ->
        return_sticky(options, %{enabled: sticky["enabled"], sticky_feature: sticky})

      options.type == :variation and Map.has_key?(sticky, "variation") ->
        return_sticky(options, %{variation_value: sticky["variation"]})

      (options.type == :variable and options[:variable_key]) && is_map(sticky["variables"]) &&
          Map.has_key?(sticky["variables"], options.variable_key) ->
        return_sticky(options, %{
          variable_key: options.variable_key,
          variable_value: sticky["variables"][options.variable_key]
        })

      true ->
        :continue
    end
  end

  defp return_sticky(options, values) do
    evaluation =
      struct(
        Evaluation,
        Map.merge(
          %{type: options.type, feature_key: options.feature_key, reason: :sticky},
          values
        )
      )

    report_evaluation(options.report, evaluation, "using sticky value")
    {:return, evaluation}
  end

  defp feature(options) do
    case read_feature(options) do
      nil -> {:error, :feature_not_found}
      feature -> {:ok, feature}
    end
  end

  defp read_feature(%{entity_source: read} = options),
    do: read.("features", options.feature_key)

  defp read_feature(options),
    do:
      Featurevisor.Normalize.get(
        options.datafile,
        "features",
        options.feature_key,
        options.regex_cache,
        options.report
      )

  defp evaluate_feature(options, feature) do
    maybe_report_deprecated(options, feature)

    with {:ok, variable_schema} <- variable_schema(options, feature),
         :ok <- variations_available(options, feature),
         :continue <- forced(options, feature, variable_schema),
         :continue <- root_conditions(options, feature) do
      bucket_and_evaluate(options, feature, variable_schema)
    else
      {:return, evaluation} -> evaluation
      {:error, :variable_not_found} -> missing_variable(options)
      {:error, :no_variations} -> no_variations(options)
    end
  end

  defp maybe_report_deprecated(%{type: :flag} = options, %{"deprecated" => true}),
    do:
      options.report.(%{
        level: :warn,
        code: "deprecated_feature",
        message: "Feature is deprecated",
        details: %{featureKey: options.feature_key}
      })

  defp maybe_report_deprecated(_, _), do: :ok

  defp variable_schema(%{variable_key: key} = options, feature) when is_binary(key) do
    case get_in(feature, ["variablesSchema", key]) do
      nil ->
        {:error, :variable_not_found}

      %{"deprecated" => true} = schema ->
        options.report.(%{
          level: :warn,
          code: "deprecated_variable",
          message: "Variable is deprecated",
          details: %{featureKey: options.feature_key, variableKey: key}
        })

        {:ok, schema}

      schema ->
        {:ok, schema}
    end
  end

  defp variable_schema(_, _), do: {:ok, nil}

  defp variations_available(%{type: :variation}, feature) do
    if is_list(feature["variations"]) and feature["variations"] != [],
      do: :ok,
      else: {:error, :no_variations}
  end

  defp variations_available(_, _), do: :ok

  defp missing_variable(options) do
    evaluation = %Evaluation{
      type: options.type,
      feature_key: options.feature_key,
      variable_key: options.variable_key,
      reason: :variable_not_found
    }

    report_evaluation(
      options.report,
      evaluation,
      "Variable schema not found",
      :warn,
      "variable_not_found"
    )

    evaluation
  end

  defp no_variations(options) do
    evaluation = %Evaluation{
      type: :variation,
      feature_key: options.feature_key,
      reason: :no_variations
    }

    report_evaluation(options.report, evaluation, "No variations", :warn, "no_variations")
    evaluation
  end

  defp forced(options, feature, schema) do
    case matched_force(options, feature) do
      nil ->
        :continue

      {force, index} ->
        evaluation =
          cond do
            options.type == :flag and Map.has_key?(force, "enabled") ->
              %Evaluation{
                type: :flag,
                feature_key: options.feature_key,
                reason: :forced,
                force: force,
                force_index: index,
                enabled: force["enabled"]
              }

            options.type == :variation and force["variation"] ->
              variation =
                Enum.find(feature["variations"] || [], &(&1["value"] == force["variation"]))

              if variation,
                do: %Evaluation{
                  type: :variation,
                  feature_key: options.feature_key,
                  reason: :forced,
                  force: force,
                  force_index: index,
                  variation: variation
                }

            options.type == :variable and is_map(force["variables"]) and
                Map.has_key?(force["variables"], options.variable_key) ->
              %Evaluation{
                type: :variable,
                feature_key: options.feature_key,
                reason: :forced,
                force: force,
                force_index: index,
                variable_key: options.variable_key,
                variable_schema: schema,
                variable_value: force["variables"][options.variable_key]
              }

            true ->
              nil
          end

        if evaluation do
          report_evaluation(options.report, evaluation, "forced value found")
          {:return, evaluation}
        else
          :continue
        end
    end
  end

  defp matched_force(options, feature) do
    feature
    |> Map.get("force", [])
    |> Enum.with_index()
    |> Enum.find_value(fn {force, index} ->
      matched = Conditions.matches?(force["conditions"], options)

      if matched, do: {force, index}
    end)
  end

  defp root_conditions(%{type: :flag} = options, feature) do
    if Map.has_key?(feature, "conditions") and
         not Conditions.matches?(feature["conditions"], options) do
      evaluation = %Evaluation{
        type: :flag,
        feature_key: options.feature_key,
        reason: :conditions_unmet,
        conditions: Featurevisor.Normalize.public(feature["conditions"]),
        enabled: false
      }

      report_evaluation(options.report, evaluation, "root conditions did not match")
      {:return, evaluation}
    else
      :continue
    end
  end

  defp root_conditions(_, _), do: :continue

  defp bucket_and_evaluate(options, feature, schema) do
    bucket_key =
      Bucketer.bucket_key(
        options.feature_key,
        feature["bucketBy"],
        options.context,
        options.report
      )

    bucket_key =
      Enum.reduce(options.state_source.().modules, bucket_key, fn module, value ->
        if module.bucket_key,
          do:
            module.bucket_key.(%{
              feature_key: options.feature_key,
              context: options.context,
              bucket_by: feature["bucketBy"],
              bucket_key: value
            }),
          else: value
      end)

    bucket_value = Bucketer.bucketed_number(bucket_key)

    bucket_value =
      Enum.reduce(options.state_source.().modules, bucket_value, fn module, value ->
        if module.bucket_value,
          do:
            module.bucket_value.(%{
              feature_key: options.feature_key,
              bucket_key: bucket_key,
              context: options.context,
              bucket_value: value
            }),
          else: value
      end)

    traffic = matched_traffic(options, feature["traffic"] || [])
    allocation = traffic && matched_allocation(traffic, bucket_value)
    traffic_evaluation(options, feature, schema, bucket_key, bucket_value, traffic, allocation)
  end

  defp matched_traffic(options, traffic) do
    Enum.find(traffic, fn rule ->
      Conditions.matches?(rule["conditions"], options)
    end)
  end

  defp matched_allocation(%{"allocation" => allocations}, value) when is_list(allocations),
    do:
      Enum.find(allocations, fn %{"range" => [start_value, end_value]} ->
        start_value <= value and end_value >= value
      end)

  defp matched_allocation(_, _), do: nil

  defp traffic_evaluation(options, feature, schema, key, value, traffic, allocation) do
    result =
      cond do
        traffic && traffic["percentage"] == 0 ->
          evaluation(options, :rule, key, value, traffic, %{enabled: false})

        options.type == :flag ->
          flag_traffic(options, key, value, traffic)

        options.type == :variation ->
          variation_traffic(options, feature, key, value, traffic, allocation)

        options.type == :variable ->
          variable_traffic(options, feature, schema, key, value, traffic, allocation)
      end

    report_evaluation(options.report, result, diagnostic_message(result))
    result
  end

  defp flag_traffic(options, key, value, traffic) do
    cond do
      traffic && Map.has_key?(traffic, "enabled") ->
        evaluation(options, :rule, key, value, traffic, %{enabled: traffic["enabled"]})

      traffic && value <= traffic["percentage"] ->
        evaluation(options, :rule, key, value, traffic, %{enabled: true})

      true ->
        evaluation(options, :no_match, key, value, nil, %{enabled: false})
    end
  end

  defp variation_traffic(options, feature, key, value, traffic, allocation) do
    variation_value = (traffic && traffic["variation"]) || (allocation && allocation["variation"])

    variation =
      variation_value && Enum.find(feature["variations"] || [], &(&1["value"] == variation_value))

    cond do
      variation && traffic && traffic["variation"] ->
        evaluation(options, :rule, key, value, traffic, %{variation: variation})

      variation ->
        evaluation(options, :allocated, key, value, traffic, %{variation: variation})

      true ->
        evaluation(options, :no_match, key, value, nil, %{})
    end
  end

  defp variable_traffic(options, feature, schema, key, value, traffic, allocation) do
    variable_key = options.variable_key

    traffic_override =
      override_value(options, traffic && get_in(traffic, ["variableOverrides", variable_key]))

    traffic_value = map_value(traffic && traffic["variables"], variable_key)
    force = matched_force(options, feature)

    force_variation =
      case force do
        {matched, _index} -> matched["variation"]
        nil -> nil
      end

    variation_value =
      force_variation || (traffic && traffic["variation"]) ||
        (allocation && allocation["variation"])

    variation =
      variation_value && Enum.find(feature["variations"] || [], &(&1["value"] == variation_value))

    variation_override =
      override_value(options, variation && get_in(variation, ["variableOverrides", variable_key]))

    variation_value_result = map_value(variation && variation["variables"], variable_key)

    cond do
      match?({:override, _, _}, traffic_override) ->
        {:override, override, index} = traffic_override

        evaluation(options, :variable_override_rule, key, value, traffic, %{
          variable_key: variable_key,
          variable_schema: schema,
          variable_value: override["value"],
          variable_override_index: index,
          variable_override_key: override["key"],
          variable_override_path: override["keyPath"]
        })

      match?({:value, _}, traffic_value) ->
        {:value, variable_value} = traffic_value

        evaluation(options, :rule, key, value, traffic, %{
          variable_key: variable_key,
          variable_schema: schema,
          variable_value: variable_value
        })

      match?({:override, _, _}, variation_override) ->
        {:override, override, index} = variation_override

        evaluation(options, :variable_override_variation, key, value, traffic, %{
          variable_key: variable_key,
          variable_schema: schema,
          variable_value: override["value"],
          variable_override_index: index,
          variable_override_key: override["key"],
          variable_override_path: override["keyPath"]
        })

      match?({:value, _}, variation_value_result) ->
        {:value, variable_value} = variation_value_result

        evaluation(options, :allocated, key, value, traffic, %{
          variable_key: variable_key,
          variable_schema: schema,
          variable_value: variable_value
        })

      true ->
        evaluation(options, :variable_default, key, value, nil, %{
          variable_key: variable_key,
          variable_schema: schema,
          variable_value: schema["defaultValue"]
        })
    end
  end

  defp override_value(_options, nil), do: nil

  defp override_value(options, overrides) when is_list(overrides) do
    overrides
    |> Enum.with_index()
    |> Enum.find_value(fn {override, index} ->
      if feature_override_matches?(options, override), do: {:override, override, index}
    end)
  end

  defp feature_override_matches?(options, override),
    do:
      Map.has_key?(override, "conditions") and
        Conditions.matches?(override["conditions"], options)

  defp map_value(map, key) when is_map(map),
    do: if(Map.has_key?(map, key), do: {:value, map[key]}, else: :missing)

  defp map_value(_, _), do: :missing

  defp evaluation(options, reason, key, value, traffic, extras) do
    base = %{
      type: options.type,
      feature_key: options.feature_key,
      reason: reason,
      bucket_key: key,
      bucket_value: value,
      rule_key: traffic && traffic["key"],
      traffic: traffic
    }

    struct(Evaluation, Map.merge(base, extras))
  end

  defp variable_value_present?(%Evaluation{variable_value: value}) when not is_nil(value),
    do: true

  defp variable_value_present?(%Evaluation{reason: reason})
       when reason in [
              :sticky,
              :forced,
              :rule,
              :allocated,
              :variable_disabled,
              :variable_override_rule,
              :variable_override_variation
            ],
       do: true

  defp variable_value_present?(%Evaluation{reason: :variable_default, variable_schema: schema})
       when is_map(schema),
       do: Map.has_key?(schema, "defaultValue")

  defp variable_value_present?(_), do: false

  defp diagnostic_message(%Evaluation{reason: reason}), do: Atom.to_string(reason)

  defp report_evaluation(report, evaluation, message, level \\ :debug, code \\ nil) do
    report.(%{
      level: level,
      code: code || Atom.to_string(evaluation.reason),
      message: message,
      originalError: evaluation.error,
      details: %{
        featureKey: evaluation.feature_key,
        variableKey: evaluation.variable_key,
        reason: Atom.to_string(evaluation.reason),
        evaluation: Evaluation.to_map(evaluation)
      }
    })
  end
end
