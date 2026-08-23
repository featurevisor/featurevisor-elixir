defmodule Featurevisor.ConditionsTest do
  use ExUnit.Case, async: true
  alias Featurevisor.Conditions

  setup do
    cache = :ets.new(:regex, [:set, :public, write_concurrency: true])
    %{cache: cache, report: fn _ -> :ok end}
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
               "operator" => "semverGreaterThan",
               "value" => "1.0.0-2beta"
             },
             Map.put(context, "version", "1.0.0-10beta"),
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
