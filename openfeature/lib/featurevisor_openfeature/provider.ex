defmodule FeaturevisorOpenFeature.Provider do
  @moduledoc """
  OpenFeature provider backed by a Featurevisor Elixir SDK instance.

  The provider can create and own a Featurevisor instance or borrow an existing
  instance supplied through `new/1`. Borrowed instances are never closed by the
  provider.
  """

  @behaviour OpenFeature.Provider

  alias OpenFeature.ResolutionDetails

  @type option ::
          {:featurevisor, Featurevisor.t()}
          | {:featurevisor_options, Featurevisor.options() | keyword()}
          | {:targeting_key_field, String.t()}
          | {:key_separator, String.t()}
          | {:variation_key, String.t()}
          | {:global_variable_prefix, String.t()}

  @type t :: %__MODULE__{}
  defstruct name: "Featurevisor",
            domain: nil,
            state: :not_ready,
            hooks: [],
            featurevisor: nil,
            owns_featurevisor: false,
            targeting_key_field: "userId",
            key_separator: ":",
            variation_key: "variation",
            global_variable_prefix: "variable",
            lifecycle: nil

  @doc "Creates a Featurevisor OpenFeature provider."
  @spec new([option()] | map()) :: t()
  def new(options \\ []) do
    options = Map.new(options)
    separator = Map.get(options, :key_separator, ":")
    prefix = Map.get(options, :global_variable_prefix, "variable")

    if separator == "", do: raise(ArgumentError, "keySeparator cannot be empty")
    if prefix == "", do: raise(ArgumentError, "globalVariablePrefix cannot be empty")

    if String.contains?(prefix, separator) do
      raise ArgumentError, "globalVariablePrefix cannot contain keySeparator"
    end

    {f, owns?, initial_error} = featurevisor_instance(options)

    {:ok, lifecycle} =
      Agent.start(fn -> %{closed: false, error: initial_error, subscriptions: []} end)

    error_unsubscribe =
      Featurevisor.on(f, :error, fn
        %{diagnostic: %{code: "invalid_datafile", message: message}} ->
          update_lifecycle(lifecycle, &%{&1 | error: message})

        _details ->
          :ok
      end)

    datafile_unsubscribe =
      Featurevisor.on(f, :datafile_set, fn _details ->
        update_lifecycle(lifecycle, &%{&1 | error: nil})
      end)

    update_lifecycle(lifecycle, fn state ->
      %{state | subscriptions: [error_unsubscribe, datafile_unsubscribe]}
    end)

    %__MODULE__{
      featurevisor: f,
      owns_featurevisor: owns?,
      targeting_key_field: Map.get(options, :targeting_key_field, "userId"),
      key_separator: separator,
      variation_key: Map.get(options, :variation_key, "variation"),
      global_variable_prefix: prefix,
      lifecycle: lifecycle
    }
  end

  @doc "Initializes the provider for an OpenFeature domain."
  @impl true
  def initialize(provider, domain, _context) do
    {:ok, %{provider | domain: domain, state: :ready}}
  end

  @doc "Releases subscriptions and closes an owned Featurevisor instance."
  @impl true
  def shutdown(%__MODULE__{} = provider) do
    case close_lifecycle(provider.lifecycle) do
      {:close, subscriptions} ->
        Enum.each(subscriptions, & &1.())
        if provider.owns_featurevisor, do: Featurevisor.close(provider.featurevisor)
        if Process.alive?(provider.lifecycle), do: Agent.stop(provider.lifecycle, :normal)
        :ok

      :already_closed ->
        :ok
    end
  end

  @doc "Resolves a boolean feature flag or variable."
  @impl true
  def resolve_boolean_value(provider, key, default, context),
    do: resolve_as(provider, key, default, context, :boolean)

  @doc "Resolves a string variation or variable."
  @impl true
  def resolve_string_value(provider, key, default, context),
    do: resolve_as(provider, key, default, context, :string)

  @doc "Resolves an integer or floating point variable."
  @impl true
  def resolve_number_value(provider, key, default, context),
    do: resolve_as(provider, key, default, context, :number)

  @doc "Resolves an object or JSON object variable."
  @impl true
  def resolve_map_value(provider, key, default, context),
    do: resolve_as(provider, key, default, context, :map)

  defp featurevisor_instance(options) do
    case Map.fetch(options, :featurevisor) do
      {:ok, %Featurevisor{} = f} ->
        {f, false, nil}

      :error ->
        featurevisor_options = options |> Map.get(:featurevisor_options, %{}) |> Map.new()
        error = initial_datafile_error(Map.get(featurevisor_options, :datafile))
        {Featurevisor.create_featurevisor(featurevisor_options), true, error}
    end
  end

  defp initial_datafile_error(nil), do: nil

  defp initial_datafile_error(datafile) when is_binary(datafile) do
    case Jason.decode(datafile) do
      {:ok, %{"revision" => revision}} when is_binary(revision) and revision != "" -> nil
      _error -> "Could not parse datafile"
    end
  end

  defp initial_datafile_error(%{"revision" => revision})
       when is_binary(revision) and revision != "",
       do: nil

  defp initial_datafile_error(_datafile), do: "Could not parse datafile"

  defp resolve_as(provider, key, default, context, expected) do
    case datafile_error(provider.lifecycle) do
      nil ->
        {evaluation, value} = evaluate(provider, key, context)
        details = details(provider, evaluation, default)

        cond do
          error = evaluation_error(evaluation) ->
            {:ok, struct(details, error)}

          is_nil(value) ->
            {:ok, details}

          type_matches?(value, expected) ->
            {:ok, %{details | value: value}}

          true ->
            {:ok,
             %{
               details
               | reason: :error,
                 error_code: :type_mismatch,
                 error_message:
                   "Flag \"#{key}\" did not resolve to a #{expected_name(expected)} value"
             }}
        end

      message ->
        {:ok,
         %ResolutionDetails{
           value: default,
           reason: :error,
           error_code: :parse_error,
           error_message: message
         }}
    end
  rescue
    error -> {:error, :unexpected_error, error}
  end

  defp evaluate(provider, key, context) do
    {feature_key, selector} = split_key(key, provider.key_separator)
    context = featurevisor_context(context, provider.targeting_key_field)

    cond do
      feature_key == provider.global_variable_prefix and not is_nil(selector) ->
        evaluation =
          Featurevisor.evaluate_global_variable(provider.featurevisor, selector, context)

        {evaluation,
         normalize_variable(
           evaluation.variable_value,
           get_in(evaluation.variable || %{}, ["type"])
         )}

      is_nil(selector) ->
        evaluation = Featurevisor.evaluate_flag(provider.featurevisor, feature_key, context)
        {evaluation, evaluation.enabled}

      selector == provider.variation_key ->
        evaluation = Featurevisor.evaluate_variation(provider.featurevisor, feature_key, context)
        {evaluation, evaluation.variation_value || get_in(evaluation.variation || %{}, ["value"])}

      true ->
        evaluation =
          Featurevisor.evaluate_variable(provider.featurevisor, feature_key, selector, context)

        {evaluation,
         normalize_variable(
           evaluation.variable_value,
           get_in(evaluation.variable_schema || %{}, ["type"])
         )}
    end
  end

  defp split_key(key, separator) do
    case String.split(key, separator, parts: 2) do
      [feature] -> {feature, nil}
      [feature, selector] -> {feature, selector}
    end
  end

  defp featurevisor_context(context, targeting_key_field) when is_map(context) do
    normalized =
      Map.new(context, fn {key, value} -> {normalize_key(key), normalize_value(value)} end)

    case targeting_key(context) do
      {:ok, targeting_key} ->
        normalized
        |> Map.put("targetingKey", targeting_key)
        |> Map.put(targeting_key_field, targeting_key)

      :error ->
        normalized
    end
  end

  defp targeting_key(context) do
    Enum.find_value(["targetingKey", "targeting_key", :targeting_key], :error, fn key ->
      case Map.fetch(context, key) do
        {:ok, value} when is_binary(value) -> {:ok, value}
        _other -> false
      end
    end)
  end

  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  defp normalize_value(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp normalize_value(%NaiveDateTime{} = value) do
    value |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
  end

  defp normalize_value(%Date{} = value), do: Date.to_iso8601(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)

  defp normalize_value(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {normalize_key(key), normalize_value(item)} end)
  end

  defp normalize_value(value), do: value

  defp normalize_variable(value, "json") when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _error -> value
    end
  end

  defp normalize_variable(value, _type), do: value

  defp details(provider, evaluation, default) do
    %ResolutionDetails{
      value: default,
      reason: reason_for(evaluation.reason),
      variant: evaluation.variation_value || get_in(evaluation.variation || %{}, ["value"]),
      flag_metadata: metadata(provider, evaluation)
    }
  end

  defp reason_for(reason)
       when reason in [
              :required,
              :forced,
              :sticky,
              :rule,
              :variable_override_variation,
              :variable_override_rule
            ],
       do: :targeting_match

  defp reason_for(:allocated), do: :split

  defp reason_for(reason)
       when reason in [
              :disabled,
              :variation_disabled,
              :variable_disabled,
              :required_features_unmet
            ],
       do: :disabled

  defp reason_for(reason)
       when reason in [:feature_not_found, :variable_not_found, :no_variations, :error],
       do: :error

  defp reason_for(_reason), do: :default

  defp evaluation_error(%{reason: :feature_not_found, feature_key: feature_key}) do
    %{
      reason: :error,
      error_code: :flag_not_found,
      error_message: "Feature \"#{feature_key}\" was not found"
    }
  end

  defp evaluation_error(%{reason: :variable_not_found} = evaluation) do
    message =
      if evaluation.feature_key in [nil, ""] do
        "Global variable \"#{evaluation.variable_key}\" was not found"
      else
        "Variable \"#{evaluation.variable_key}\" was not found for feature \"#{evaluation.feature_key}\""
      end

    %{reason: :error, error_code: :flag_not_found, error_message: message}
  end

  defp evaluation_error(%{reason: :no_variations, feature_key: feature_key}) do
    %{
      reason: :error,
      error_code: :flag_not_found,
      error_message: "Feature \"#{feature_key}\" has no variations"
    }
  end

  defp evaluation_error(%{reason: :error, error: error}) do
    %{
      reason: :error,
      error_code: :general,
      error_message: error_message(error)
    }
  end

  defp evaluation_error(_evaluation), do: nil

  defp error_message(%{__exception__: true} = error), do: Exception.message(error)
  defp error_message(error) when is_binary(error), do: error
  defp error_message(_error), do: "Featurevisor evaluation failed"

  defp metadata(provider, evaluation) do
    %{
      "featurevisorReason" => Atom.to_string(evaluation.reason),
      "schemaVersion" => Featurevisor.get_schema_version(provider.featurevisor),
      "revision" => Featurevisor.get_revision(provider.featurevisor),
      "featureKey" => evaluation.feature_key,
      "variableKey" => evaluation.variable_key,
      "ruleKey" => evaluation.rule_key,
      "bucketKey" => evaluation.bucket_key,
      "bucketValue" => evaluation.bucket_value,
      "forceIndex" => evaluation.force_index,
      "variableOverrideIndex" => evaluation.variable_override_index,
      "variableOverrideKey" => evaluation.variable_override_key
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp type_matches?(value, :boolean), do: is_boolean(value)
  defp type_matches?(value, :string), do: is_binary(value)
  defp type_matches?(value, :number), do: is_number(value)
  defp type_matches?(value, :map), do: is_map(value)

  defp expected_name(:boolean), do: "boolean"
  defp expected_name(:string), do: "string"
  defp expected_name(:number), do: "number"
  defp expected_name(:map), do: "map"

  defp datafile_error(lifecycle) do
    if Process.alive?(lifecycle), do: Agent.get(lifecycle, & &1.error), else: nil
  end

  defp update_lifecycle(lifecycle, function) do
    if Process.alive?(lifecycle), do: Agent.update(lifecycle, function)
  catch
    :exit, _reason -> :ok
  end

  defp close_lifecycle(lifecycle) do
    if Process.alive?(lifecycle) do
      Agent.get_and_update(lifecycle, fn
        %{closed: true} = state -> {:already_closed, state}
        state -> {{:close, state.subscriptions}, %{state | closed: true, subscriptions: []}}
      end)
    else
      :already_closed
    end
  catch
    :exit, _reason -> :already_closed
  end
end
