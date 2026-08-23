defmodule Featurevisor.Bucketer do
  @moduledoc false
  alias Featurevisor.MurmurHash

  @max 100_000
  def max_bucketed_number, do: @max
  def bucketed_number(key), do: floor(MurmurHash.hash(key) / 4_294_967_296 * @max)

  def bucket_key(feature_key, bucket_by, context, report) do
    case bucket_attributes(bucket_by) do
      {:ok, type, attributes} ->
        values =
          Enum.reduce(attributes, [], fn attribute, values ->
            case context_value(context, attribute) do
              :missing -> values
              _value when type == :or and values != [] -> values
              value -> values ++ [bucket_string(value)]
            end
          end)

        Enum.join(values ++ [feature_key], ".")

      :error ->
        report.(%{
          level: :error,
          code: "invalid_bucket_by",
          message: "Invalid bucketBy",
          details: %{featureKey: feature_key, bucketBy: bucket_by}
        })

        raise ArgumentError, "invalid bucketBy"
    end
  end

  def context_value(context, path) do
    path
    |> String.split(".")
    |> Enum.reduce_while(context, fn part, current ->
      if is_map(current) and Map.has_key?(current, part),
        do: {:cont, Map.get(current, part)},
        else: {:halt, :missing}
    end)
  end

  def bucket_string(value) when is_binary(value), do: value
  def bucket_string(value) when is_boolean(value), do: Atom.to_string(value)
  def bucket_string(nil), do: ""
  def bucket_string(value) when is_integer(value), do: Integer.to_string(value)
  def bucket_string(value) when is_float(value), do: javascript_number(value)
  def bucket_string(value), do: to_string(value)

  def javascript_number(value) do
    cond do
      value == 0.0 -> "0"
      abs(value) >= 1.0e-6 and abs(value) < 1.0e21 -> fixed_number(value)
      true -> scientific_number(value)
    end
  end

  defp fixed_number(value) do
    value
    |> :erlang.float_to_binary([:short])
    |> expand_exponent()
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end

  defp scientific_number(value) do
    value
    |> :erlang.float_to_binary([:short])
    |> String.downcase()
    |> String.replace(~r/\.0(?=e)/, "")
    |> String.replace(~r/e(-?)0+/, "e\\1")
    |> then(fn value ->
      if String.contains?(value, "e-") or not String.contains?(value, "e"),
        do: value,
        else: String.replace(value, "e", "e+")
    end)
  end

  defp expand_exponent(value) do
    case Regex.run(~r/^(-?)(\d+)(?:\.(\d+))?e([+-]?\d+)$/i, value) do
      nil ->
        value

      [_, sign, whole, fraction, exponent] ->
        digits = whole <> fraction
        point = String.length(whole) + String.to_integer(exponent)

        cond do
          point <= 0 ->
            sign <> "0." <> String.duplicate("0", -point) <> digits

          point >= String.length(digits) ->
            sign <> digits <> String.duplicate("0", point - String.length(digits))

          true ->
            sign <> String.slice(digits, 0, point) <> "." <> String.slice(digits, point..-1//1)
        end
    end
  end

  defp bucket_attributes(value) when is_binary(value), do: {:ok, :plain, [value]}
  defp bucket_attributes(value) when is_list(value), do: {:ok, :and, value}
  defp bucket_attributes(%{"or" => value}) when is_list(value), do: {:ok, :or, value}
  defp bucket_attributes(_), do: :error
end
