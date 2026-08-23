defmodule Featurevisor.MurmurHash do
  @moduledoc false
  import Bitwise

  @mask 0xFFFFFFFF

  def hash(key, seed \\ 1) when is_binary(key) do
    bytes = :binary.bin_to_list(key)
    {chunks, tail} = Enum.split(bytes, div(length(bytes), 4) * 4)

    h1 =
      chunks
      |> Enum.chunk_every(4)
      |> Enum.reduce(seed, fn [a, b, c, d], h ->
        k = a ||| b <<< 8 ||| c <<< 16 ||| d <<< 24
        k = mul32(k, 0xCC9E2D51) |> rotl32(15) |> mul32(0x1B873593)
        h = bxor(h, k) |> rotl32(13)
        mask(mul32(h, 5) + 0xE6546B64)
      end)

    k1 =
      case tail do
        [a] -> a
        [a, b] -> a ||| b <<< 8
        [a, b, c] -> a ||| b <<< 8 ||| c <<< 16
        [] -> 0
      end

    h1 =
      if tail == [] do
        h1
      else
        bxor(h1, k1 |> mul32(0xCC9E2D51) |> rotl32(15) |> mul32(0x1B873593))
      end

    h1 = bxor(h1, byte_size(key))
    h1 = bxor(h1, h1 >>> 16) |> mul32(0x85EBCA6B)
    h1 = bxor(h1, h1 >>> 13) |> mul32(0xC2B2AE35)
    mask(bxor(h1, h1 >>> 16))
  end

  defp mul32(a, b), do: mask(a * b)
  defp mask(value), do: value &&& @mask
  defp rotl32(value, count), do: mask(value <<< count ||| value >>> (32 - count))
end
