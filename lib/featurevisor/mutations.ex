defmodule Featurevisor.Mutations do
  @moduledoc false

  @operations ~w(set append prepend appendUnique removeValue before after remove)
  @dangerous_keys ~w(__proto__ prototype constructor)
  @max_safe_integer 9_007_199_254_740_991

  def apply(value, operations) when is_list(operations) do
    Enum.reduce(operations, value, fn operation, current ->
      validate_operation!(operation)
      update_at_path(current, operation, 0)
    end)
  end

  def apply(_value, _operations), do: raise(ArgumentError, "Invalid variable mutation operations")

  def primitive_equal?(left, right) when is_number(left) and is_number(right), do: left == right
  def primitive_equal?(left, right), do: left === right

  defp validate_operation!(%{"op" => op, "path" => path} = operation)
       when op in @operations do
    if not is_list(path), do: raise(ArgumentError, "Invalid variable mutation path")

    if op != "remove" and not Map.has_key?(operation, "value") do
      raise ArgumentError, "Variable mutation operation requires a value"
    end

    if op in ["appendUnique", "removeValue"] do
      value = operation["value"]

      if not primitive?(value) or (is_float(value) and not finite?(value)) do
        raise ArgumentError, "Variable mutation operation requires a primitive value"
      end
    end

    Enum.each(path, &validate_path_part!/1)
  end

  defp validate_operation!(_), do: raise(ArgumentError, "Invalid variable mutation operation")

  defp validate_path_part!(part) when is_binary(part) do
    if part in @dangerous_keys, do: raise(ArgumentError, "Unsafe variable mutation key")
  end

  defp validate_path_part!(%{
         "select" => %{"property" => property, "values" => values}
       })
       when is_binary(property) and is_list(values) do
    if property in @dangerous_keys or not Enum.all?(values, &primitive?/1) do
      raise ArgumentError, "Invalid variable mutation path"
    end
  end

  defp validate_path_part!(part) do
    case array_index(part) do
      {:ok, _index} -> :ok
      :error -> raise(ArgumentError, "Invalid variable mutation path")
    end
  end

  defp update_at_path(value, %{"op" => op, "path" => path} = operation, offset)
       when offset == length(path) do
    case op do
      "set" ->
        operation["value"]

      "remove" ->
        raise ArgumentError, "Cannot remove the root variable value"

      op when op in ["before", "after"] ->
        raise ArgumentError, "Variable mutation before/after requires an array element path"

      _ when is_nil(value) ->
        value

      _ when is_list(value) ->
        update_array(value, op, operation["value"])

      _ ->
        raise ArgumentError, "Variable mutation expected an array"
    end
  end

  defp update_at_path(nil, _operation, _offset), do: nil

  defp update_at_path(value, %{"op" => op, "path" => path} = operation, offset) do
    part = Enum.at(path, offset)
    final? = offset == length(path) - 1

    if final? and op in ["before", "after"] and is_binary(part) do
      raise ArgumentError, "Variable mutation before/after requires an array element path"
    end

    {kind, key} = path_key!(value, part)
    found? = found?(value, kind, key)

    cond do
      not final? ->
        if not found? or is_nil(fetch(value, kind, key)) do
          value
        else
          put(value, kind, key, update_at_path(fetch(value, kind, key), operation, offset + 1))
        end

      op == "remove" ->
        if found?, do: remove(value, kind, key), else: value

      op == "set" ->
        set(value, kind, key, operation["value"])

      op in ["before", "after"] ->
        if found? do
          List.insert_at(value, key + if(op == "after", do: 1, else: 0), operation["value"])
        else
          value
        end

      true ->
        current = if found?, do: fetch(value, kind, key), else: nil

        cond do
          is_nil(current) and kind == :list ->
            value

          is_nil(current) and op == "removeValue" ->
            value

          not is_nil(current) and not is_list(current) ->
            raise ArgumentError, "Variable mutation expected an array"

          true ->
            put(value, kind, key, update_array(current || [], op, operation["value"]))
        end
    end
  end

  defp path_key!(value, part) when is_binary(part) and is_map(value), do: {:map, part}

  defp path_key!(_value, part) when is_binary(part),
    do: raise(ArgumentError, "Variable mutation expected an object")

  defp path_key!(value, %{"select" => selector}) when is_list(value),
    do: {:list, selected_index(value, selector)}

  defp path_key!(value, part) when is_list(value) do
    case array_index(part) do
      {:ok, index} -> {:list, index}
      :error -> raise(ArgumentError, "Variable mutation expected an array")
    end
  end

  defp path_key!(_value, _part), do: raise(ArgumentError, "Variable mutation expected an array")

  defp selected_index(value, %{"property" => property, "values" => expected}) do
    Enum.find_index(value, fn
      candidate when is_map(candidate) ->
        case Map.fetch(candidate, property) do
          {:ok, actual}
          when is_binary(actual) or is_number(actual) or is_boolean(actual) or is_nil(actual) ->
            Enum.any?(expected, &primitive_equal?(actual, &1))

          _ ->
            false
        end

      _ ->
        false
    end) || -1
  end

  defp found?(value, :map, key), do: Map.has_key?(value, key)
  defp found?(value, :list, key), do: key >= 0 and key < length(value)
  defp fetch(value, :map, key), do: Map.fetch!(value, key)
  defp fetch(value, :list, key), do: Enum.at(value, key)
  defp put(value, :map, key, item), do: Map.put(value, key, item)
  defp put(value, :list, key, item), do: List.replace_at(value, key, item)
  defp remove(value, :map, key), do: Map.delete(value, key)
  defp remove(value, :list, key), do: List.delete_at(value, key)

  defp set(value, :map, key, item), do: Map.put(value, key, item)
  defp set(value, :list, key, item) when key == length(value), do: value ++ [item]

  defp set(value, :list, key, item) when key >= 0 and key < length(value),
    do: List.replace_at(value, key, item)

  defp set(value, :list, _key, _item), do: value

  defp update_array(value, "removeValue", item),
    do: Enum.reject(value, &primitive_equal?(&1, item))

  defp update_array(value, "appendUnique", item) do
    if Enum.any?(value, &primitive_equal?(&1, item)), do: value, else: value ++ [item]
  end

  defp update_array(value, "prepend", item), do: [item | value]
  defp update_array(value, _op, item), do: value ++ [item]

  defp primitive?(value),
    do: is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value)

  defp array_index(value)
       when is_integer(value) and value >= 0 and value <= @max_safe_integer,
       do: {:ok, value}

  defp array_index(value) when is_float(value) do
    if finite?(value) and value >= 0 and value <= @max_safe_integer and value == trunc(value),
      do: {:ok, trunc(value)},
      else: :error
  end

  defp array_index(_value), do: :error

  defp finite?(value), do: abs(value) < 1.797_693_134_862_315_7e308
end
