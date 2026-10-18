defmodule Featurevisor.NativeTimestampTest do
  use ExUnit.Case, async: true
  alias Featurevisor.Conditions

  setup do
    %{cache: :ets.new(:native_dates, [:set, :public])}
  end

  test "native values truncate rather than round around the epoch", %{cache: cache} do
    for stamp <- ["2026-01-01T00:00:00Z", "1969-12-31T23:59:59.999Z"] do
      {:ok, boundary, 0} = DateTime.from_iso8601(stamp)
      fractional = DateTime.add(boundary, 999, :microsecond)

      for op <- ["before", "after"] do
        refute matches(fractional, op, stamp, cache)

        assert matches(
                 fractional,
                 op,
                 DateTime.to_iso8601(DateTime.add(boundary, 1, :millisecond)),
                 cache
               ) == (op == "before")

        assert matches(
                 fractional,
                 op,
                 DateTime.to_iso8601(DateTime.add(boundary, -1, :millisecond)),
                 cache
               ) == (op == "after")
      end
    end
  end

  test "native ranges and types reject invalid operands", %{cache: cache} do
    assert matches(~U[0001-01-01 00:00:00Z], "before", "2026-01-01T00:00:00Z", cache)
    assert matches(~U[9999-12-31 23:59:59.999999Z], "after", "2026-01-01T00:00:00Z", cache)
    host = ~U[2026-01-01 00:00:00Z]

    for offset <- [-50_400, 50_400] do
      assert matches(%{host | utc_offset: offset}, "before", "2026-01-02T00:00:00Z", cache)
    end

    invalid = [
      ~D[2026-01-01],
      ~N[2026-01-01 00:00:00],
      %{host | year: 0},
      %{host | year: 10_000},
      %{host | utc_offset: 50_401},
      %{host | utc_offset: -50_401},
      %{host | utc_offset: 50_400, std_offset: 3600},
      %{~U[0001-01-01 00:00:00Z] | utc_offset: 3600},
      %{~U[9999-12-31 23:59:59Z] | utc_offset: -3600},
      "2026-01-01",
      "2026-01-01T00:00:00",
      1_767_225_600_000,
      nil
    ]

    for actual <- invalid, op <- ["before", "after"] do
      refute matches(actual, op, "2026-01-01T00:00:00Z", cache)
      refute matches(host, op, actual, cache)
    end
  end

  defp matches(actual, op, expected, cache) do
    Conditions.value_matches?(actual, %{"operator" => op, "value" => expected}, cache)
  end
end
