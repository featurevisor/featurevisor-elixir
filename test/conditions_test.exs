defmodule Featurevisor.ConditionsTest do
  use ExUnit.Case, async: true
  alias Featurevisor.Conditions

  setup do
    cache = :ets.new(:regex, [:set, :public, write_concurrency: true])
    %{cache: cache, report: fn _ -> :ok end}
  end

  test "host dates floor pre epoch milliseconds", %{cache: cache} do
    {:ok, host, 0} = DateTime.from_iso8601("1969-12-31T23:59:59.999500Z")

    refute Conditions.value_matches?(
             host,
             %{"operator" => "before", "value" => "1969-12-31T23:59:59.999Z"},
             cache
           )

    assert Conditions.value_matches?(
             host,
             %{"operator" => "before", "value" => "1970-01-01T00:00:00Z"},
             cache
           )
  end

  test "string dates truncate one to nine fractional digits", %{cache: cache} do
    condition = %{"operator" => "before", "value" => "2024-01-01T00:00:00.124Z"}

    for digits <- ["1239", "123999", "1239999", "123999999"] do
      assert Conditions.value_matches?("2024-01-01T00:00:00.#{digits}Z", condition, cache)
    end

    refute Conditions.value_matches?("2024-01-01T00:00:00.1239999999Z", condition, cache)

    refute Conditions.value_matches?(
             "1969-12-31T23:59:59.999999999Z",
             %{"operator" => "before", "value" => "1969-12-31T23:59:59.999Z"},
             cache
           )

    assert Conditions.value_matches?(
             "1969-12-31T23:59:59.999999999Z",
             %{"operator" => "before", "value" => "1970-01-01T00:00:00Z"},
             cache
           )
  end

  test "supports every condition group and implicit AND negation", %{cache: cache, report: report} do
    plain = %{"attribute" => "country", "operator" => "equals", "value" => "nl"}
    mobile = %{"attribute" => "device", "operator" => "equals", "value" => "mobile"}
    assert Conditions.all_conditions?(plain, %{"country" => "nl"}, cache, report)

    assert Conditions.all_conditions?(
             [plain, mobile],
             %{"country" => "nl", "device" => "mobile"},
             cache,
             report
           )

    assert Conditions.all_conditions?(
             %{"or" => [plain, mobile]},
             %{"device" => "mobile"},
             cache,
             report
           )

    assert Conditions.all_conditions?(
             %{"not" => [plain, mobile]},
             %{"country" => "nl", "device" => "desktop"},
             cache,
             report
           )

    refute Conditions.all_conditions?(
             %{"not" => [plain, mobile]},
             %{"country" => "nl", "device" => "mobile"},
             cache,
             report
           )

    refute Conditions.all_conditions?(%{"not" => []}, %{}, cache, report)
  end

  test "supports portable regex flags and fresh repeated matches", %{cache: cache, report: report} do
    condition = %{
      "attribute" => "browser",
      "operator" => "matches",
      "value" => "^chrome$",
      "regexFlags" => "gi"
    }

    assert Conditions.all_conditions?(condition, %{"browser" => "Chrome"}, cache, report)
    assert Conditions.all_conditions?(condition, %{"browser" => "Chrome"}, cache, report)
  end

  test "supports nested values, arrays, dates, numbers, and semver", %{
    cache: cache,
    report: report
  } do
    context = %{
      "profile" => %{"age" => 20},
      "roles" => ["admin"],
      "date" => "2024-01-01T00:00:00.250Z",
      "nativeDate" => ~U[2024-01-01 00:00:00.250Z],
      "version" => "2.0.0-beta.1"
    }

    assert Conditions.all_conditions?(
             %{"attribute" => "profile.age", "operator" => "greaterThanOrEquals", "value" => 20},
             context,
             cache,
             report
           )

    assert Conditions.all_conditions?(
             %{
               "attribute" => "nativeDate",
               "operator" => "after",
               "value" => "2023-12-31T23:59:59Z"
             },
             context,
             cache,
             report
           )

    assert Conditions.all_conditions?(
             %{"attribute" => "roles", "operator" => "includes", "value" => "admin"},
             context,
             cache,
             report
           )

    assert Conditions.all_conditions?(
             %{
               "attribute" => "date",
               "operator" => "before",
               "value" => "2024-01-01T01:00:00+00:00"
             },
             context,
             cache,
             report
           )

    assert Conditions.all_conditions?(
             %{"attribute" => "version", "operator" => "semverLessThan", "value" => "2.0.0"},
             context,
             cache,
             report
           )

    assert Conditions.all_conditions?(
             %{
               "attribute" => "version",
               "operator" => "semverGreaterThan",
               "value" => "1.9.9.9"
             },
             Map.put(context, "version", "1.9.9.10"),
             cache,
             report
           )

    assert Conditions.all_conditions?(
             %{
               "attribute" => "version",
               "operator" => "semverLessThan",
               "value" => "1.0.0-2beta"
             },
             Map.put(context, "version", "1.0.0-10beta"),
             cache,
             report
           )
  end

  test "matches empty and notEmpty only for supported shallow values", %{
    cache: cache,
    report: report
  } do
    context = %{
      "emptyString" => "",
      "space" => " ",
      "emptyArray" => [],
      "arrayWithNull" => [nil],
      "emptyObject" => %{},
      "objectWithNull" => %{"value" => nil},
      "nested" => %{"items" => []},
      "null" => nil,
      "number" => 0,
      "host" => ~D[2026-09-18],
      "hostMap" => %{value: 1}
    }

    for {attribute, operator} <- [
          {"emptyString", "empty"},
          {"emptyArray", "empty"},
          {"emptyObject", "empty"},
          {"nested.items", "empty"},
          {"space", "notEmpty"},
          {"arrayWithNull", "notEmpty"},
          {"objectWithNull", "notEmpty"}
        ] do
      assert Conditions.all_conditions?(
               %{"attribute" => attribute, "operator" => operator},
               context,
               cache,
               report
             )
    end

    for attribute <- ["missing", "null", "number", "host", "hostMap"],
        operator <- ["empty", "notEmpty"] do
      refute Conditions.all_conditions?(
               %{"attribute" => attribute, "operator" => operator},
               context,
               cache,
               report
             )
    end

    refute Conditions.all_conditions?(
             %{"attribute" => "emptyString", "operator" => "notEmpty"},
             context,
             cache,
             report
           )

    refute Conditions.all_conditions?(
             %{"attribute" => "emptyArray", "operator" => "notEmpty"},
             context,
             cache,
             report
           )

    refute Conditions.all_conditions?(
             %{"attribute" => "emptyObject", "operator" => "notEmpty"},
             context,
             cache,
             report
           )
  end

  test "supports stringified wildcard segments", %{cache: cache, report: report} do
    segments = %{"everyone" => %{"conditions" => "*"}}
    assert Conditions.all_segments?("everyone", %{}, segments, cache, report)
    refute Conditions.all_segments?("missing", %{}, segments, cache, report)
  end

  test "formats native lists and maps in bucket keys like JavaScript" do
    assert Featurevisor.Bucketer.bucket_string([1, 2]) == "1,2"
    assert Featurevisor.Bucketer.bucket_string(["a", "b"]) == "a,b"
    assert Featurevisor.Bucketer.bucket_string([1, [2, 3], nil]) == "1,2,3,"
    assert Featurevisor.Bucketer.bucket_string(%{"a" => 1}) == "[object Object]"
  end
end
