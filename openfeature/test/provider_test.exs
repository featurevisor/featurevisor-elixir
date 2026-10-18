defmodule FeaturevisorOpenFeature.ProviderTest do
  use ExUnit.Case, async: false

  @provider_fixture Path.expand("../conformance/openfeature-provider.json", __DIR__)
                    |> File.read!()
                    |> Jason.decode!()

  alias FeaturevisorOpenFeature.Provider
  alias OpenFeature.ResolutionDetails

  test "invalid initial shapes fail initialization without logging and recover" do
    valid = @provider_fixture["datafile"]

    for invalid <- [
          "{",
          "null",
          "{}",
          %{"schemaVersion" => "2", "revision" => "x", "features" => [], "segments" => %{}},
          Map.put(valid, "variables", [])
        ] do
      provider = Provider.new(featurevisor_options: %{datafile: invalid, log_level: :fatal})
      assert {:error, :parse_error} = Provider.initialize(provider, "initial", %{})

      assert {:ok, %ResolutionDetails{error_code: :parse_error}} =
               Provider.resolve_boolean_value(provider, "checkout", false, %{})

      Featurevisor.set_datafile(provider.featurevisor, valid, true)
      assert {:ok, %{state: :ready}} = Provider.initialize(provider, "initial", %{})
      Provider.shutdown(provider)
    end

    provider =
      Provider.new(
        featurevisor_options: %{datafile: Map.put(valid, "revision", ""), log_level: :fatal}
      )

    assert {:ok, %{state: :ready}} = Provider.initialize(provider, "empty_revision", %{})
    Provider.shutdown(provider)
  end

  test "shared provider conformance" do
    fixture = @provider_fixture
    assert fixture["kind"] == "featurevisor.openfeature-provider"
    assert fixture["schemaVersion"] == 1
    assert length(fixture["cases"]) == 16

    provider =
      Provider.new(featurevisor_options: %{datafile: fixture["datafile"], log_level: :fatal})

    Enum.each(fixture["cases"], fn item ->
      source = item["context"]

      resolver =
        case item["type"] do
          "boolean" -> &Provider.resolve_boolean_value/4
          "string" -> &Provider.resolve_string_value/4
          "object" -> &Provider.resolve_map_value/4
        end

      assert {:ok, result} = resolver.(provider, item["flagKey"], item["default"], source)
      expected = item["expected"]
      assert result.value == expected["value"], item["name"]

      if expected["reason"] do
        assert result.reason == expected["reason"] |> String.downcase() |> String.to_atom(),
               item["name"]
      end

      assert result.variant == expected["variant"], item["name"]

      expected_error =
        expected["errorCode"] && expected["errorCode"] |> String.downcase() |> String.to_atom()

      assert result.error_code == expected_error, item["name"]
      assert source == item["context"], item["name"]
    end)

    Enum.each(fixture["targetingCases"], fn item ->
      source = item["context"]
      assert {:ok, result} = Provider.resolve_boolean_value(provider, "targetOnly", false, source)
      assert result.value == item["expectedValue"], item["name"]
      assert source == item["context"], item["name"]
    end)

    Provider.shutdown(provider)

    custom =
      Provider.new(
        featurevisor_options: %{datafile: fixture["datafile"], log_level: :fatal},
        targeting_key_field: "accountId"
      )

    item = fixture["customTargetingCase"]

    assert {:ok, result} =
             Provider.resolve_boolean_value(custom, item["flagKey"], false, item["context"])

    assert result.value == item["expectedValue"]
    Provider.shutdown(custom)
  end

  @datafile %{
    "schemaVersion" => "2",
    "revision" => "openfeature-test",
    "segments" => %{},
    "features" => %{
      "checkout" => %{
        "bucketBy" => "userId",
        "variations" => [
          %{
            "value" => "on",
            "variables" => %{
              "title" => "Hello",
              "count" => 3,
              "ratio" => 1.5,
              "visible" => true,
              "config" => %{"colour" => "blue"},
              "json" => ~s({"nested":true}),
              "invalidJson" => "not-json"
            }
          }
        ],
        "variablesSchema" => %{
          "title" => %{"type" => "string", "defaultValue" => "Default"},
          "count" => %{"type" => "integer", "defaultValue" => 0},
          "ratio" => %{"type" => "double", "defaultValue" => 0},
          "visible" => %{"type" => "boolean", "defaultValue" => false},
          "config" => %{"type" => "object", "defaultValue" => %{}},
          "json" => %{"type" => "json", "defaultValue" => "{}"},
          "invalidJson" => %{"type" => "json", "defaultValue" => "{}"}
        },
        "force" => [
          %{
            "conditions" => %{
              "attribute" => "userId",
              "operator" => "equals",
              "value" => "forced-user"
            },
            "enabled" => true,
            "variation" => "on"
          },
          %{
            "conditions" => %{
              "attribute" => "userId",
              "operator" => "equals",
              "value" => ""
            },
            "enabled" => true,
            "variation" => "on"
          }
        ],
        "traffic" => [
          %{
            "key" => "all",
            "segments" => "*",
            "percentage" => 100_000,
            "variation" => "on"
          }
        ]
      },
      "empty" => %{
        "bucketBy" => "userId",
        "variations" => [],
        "traffic" => [
          %{
            "key" => "all",
            "segments" => "*",
            "percentage" => 100_000,
            "allocation" => []
          }
        ]
      },
      "disabled" => %{
        "bucketBy" => "userId",
        "disabledVariationValue" => "off",
        "variations" => [%{"value" => "on"}],
        "force" => [
          %{
            "conditions" => %{
              "attribute" => "blocked",
              "operator" => "equals",
              "value" => true
            },
            "enabled" => false
          }
        ],
        "traffic" => [
          %{
            "key" => "all",
            "segments" => "*",
            "percentage" => 100_000,
            "variation" => "on"
          }
        ]
      },
      "allocated" => %{
        "bucketBy" => "userId",
        "variations" => [%{"value" => "on"}],
        "traffic" => [
          %{
            "key" => "all",
            "segments" => "*",
            "percentage" => 100_000,
            "allocation" => [%{"variation" => "on", "range" => [0, 100_000]}]
          }
        ]
      }
    },
    "variables" => %{
      "requirementSource" => %{"type" => "boolean", "defaultValue" => false},
      "requirementGate" => %{
        "type" => "boolean",
        "defaultValue" => true,
        "disabledValue" => false,
        "conditions" => [
          %{"variable" => "requirementSource", "operator" => "equals", "value" => true}
        ]
      },
      "supportEmail" => %{
        "type" => "string",
        "defaultValue" => "support@example.com",
        "overrides" => [
          %{
            "key" => "nl",
            "conditions" => %{
              "attribute" => "country",
              "operator" => "equals",
              "value" => "nl"
            },
            "value" => "nl@example.com"
          }
        ]
      },
      "settings" => %{
        "type" => "object",
        "defaultValue" => %{"enabled" => true, "limits" => [1, 2]}
      },
      "globalJson" => %{
        "type" => "json",
        "defaultValue" => ~s({"source":"global"})
      }
    }
  }

  setup do
    OpenFeature.shutdown()
    OpenFeature.clear_providers()

    on_exit(fn ->
      OpenFeature.shutdown()
      OpenFeature.clear_providers()
    end)
  end

  defp provider(options \\ []) do
    Provider.new(
      Keyword.merge(
        [featurevisor_options: %{datafile: @datafile, log_level: :fatal}],
        options
      )
    )
  end

  test "resolves every OpenFeature type and global variables" do
    provider = provider()
    context = %{"targetingKey" => "forced-user"}

    assert {:ok, %ResolutionDetails{value: true, reason: :targeting_match}} =
             Provider.resolve_boolean_value(provider, "checkout", false, context)

    assert {:ok, %ResolutionDetails{value: "on", variant: "on"}} =
             Provider.resolve_string_value(provider, "checkout:variation", "fallback", context)

    assert {:ok, %ResolutionDetails{value: "Hello"}} =
             Provider.resolve_string_value(provider, "checkout:title", "fallback", context)

    assert {:ok, %ResolutionDetails{value: 3}} =
             Provider.resolve_number_value(provider, "checkout:count", 0, context)

    assert {:ok, %ResolutionDetails{value: 1.5}} =
             Provider.resolve_number_value(provider, "checkout:ratio", 0.0, context)

    assert {:ok, %ResolutionDetails{value: true}} =
             Provider.resolve_boolean_value(provider, "checkout:visible", false, context)

    assert {:ok, %ResolutionDetails{value: %{"colour" => "blue"}}} =
             Provider.resolve_map_value(provider, "checkout:config", %{}, context)

    assert {:ok, %ResolutionDetails{value: %{"nested" => true}}} =
             Provider.resolve_map_value(provider, "checkout:json", %{}, context)

    assert {:ok, %ResolutionDetails{value: "support@example.com"}} =
             Provider.resolve_string_value(
               provider,
               "variable:supportEmail",
               "fallback",
               context
             )

    assert {:ok, %ResolutionDetails{value: %{"enabled" => true, "limits" => [1, 2]}}} =
             Provider.resolve_map_value(provider, "variable:settings", %{}, context)

    assert {:ok, %ResolutionDetails{value: %{"source" => "global"}}} =
             Provider.resolve_map_value(provider, "variable:globalJson", %{}, context)

    assert :ok = Provider.shutdown(provider)
  end

  test "an empty selector resolves the bare flag" do
    provider = provider()

    assert {:ok, %ResolutionDetails{value: true}} =
             Provider.resolve_boolean_value(provider, "checkout:", false, %{})

    Provider.shutdown(provider)
  end

  test "supports custom key grammar and targeting key spellings" do
    provider =
      provider(
        targeting_key_field: "accountId",
        key_separator: "/",
        variation_key: "$variation",
        global_variable_prefix: "$variable"
      )

    assert {:ok, %ResolutionDetails{value: "on"}} =
             Provider.resolve_string_value(
               provider,
               "checkout/$variation",
               "fallback",
               %{"targeting_key" => "forced-user"}
             )

    assert {:ok, %ResolutionDetails{value: "nl@example.com"}} =
             Provider.resolve_string_value(
               provider,
               "$variable/supportEmail",
               "fallback",
               %{targeting_key: "forced-user", country: "nl"}
             )

    assert {:ok, %ResolutionDetails{value: true}} =
             Provider.resolve_boolean_value(provider, "checkout", false, %{"targetingKey" => ""})

    Provider.shutdown(provider)
  end

  test "maps errors, defaults, reasons, and metadata" do
    provider = provider()

    assert {:ok,
            %ResolutionDetails{
              value: true,
              reason: :error,
              error_code: :flag_not_found,
              error_message: ~s(Feature "missing" was not found)
            }} = Provider.resolve_boolean_value(provider, "missing", true, %{})

    assert {:ok, %ResolutionDetails{value: "fallback", error_code: :flag_not_found}} =
             Provider.resolve_string_value(provider, "checkout:missing", "fallback", %{})

    assert {:ok,
            %ResolutionDetails{
              value: "fallback",
              error_code: :flag_not_found,
              error_message: ~s(Feature "variable" was not found)
            }} = Provider.resolve_string_value(provider, "variable:", "fallback", %{})

    assert {:ok, %ResolutionDetails{value: "fallback", error_code: :flag_not_found}} =
             Provider.resolve_string_value(provider, "empty:variation", "fallback", %{})

    assert {:ok, %ResolutionDetails{value: "fallback", error_code: :type_mismatch}} =
             Provider.resolve_string_value(provider, "checkout", "fallback", %{})

    assert {:ok, %ResolutionDetails{value: false, error_code: :type_mismatch}} =
             Provider.resolve_boolean_value(provider, "checkout:title", false, %{})

    assert {:ok, %ResolutionDetails{value: 0, error_code: :type_mismatch}} =
             Provider.resolve_number_value(provider, "checkout:invalidJson", 0, %{})

    assert {:ok,
            %ResolutionDetails{
              value: true,
              flag_metadata: %{
                "revision" => "openfeature-test",
                "schemaVersion" => "2",
                "featurevisorReason" => "forced"
              }
            }} =
             Provider.resolve_boolean_value(
               provider,
               "checkout",
               false,
               %{"targetingKey" => "forced-user"}
             )

    Provider.shutdown(provider)
  end

  test "maps targeting, split, and disabled reasons" do
    provider = provider()

    assert {:ok, %ResolutionDetails{value: "on", reason: :split}} =
             Provider.resolve_string_value(
               provider,
               "allocated:variation",
               "fallback",
               %{"targetingKey" => "allocated-user"}
             )

    assert {:ok, %ResolutionDetails{value: "nl@example.com", reason: :targeting_match}} =
             Provider.resolve_string_value(
               provider,
               "variable:supportEmail",
               "fallback",
               %{"country" => "nl"}
             )

    assert {:ok, %ResolutionDetails{value: false, reason: :targeting_match}} =
             Provider.resolve_boolean_value(provider, "disabled", true, %{"blocked" => true})

    assert {:ok, %ResolutionDetails{value: "off", reason: :disabled}} =
             Provider.resolve_string_value(
               provider,
               "disabled:variation",
               "fallback",
               %{"blocked" => true}
             )

    assert {:ok,
            %ResolutionDetails{
              value: false,
              reason: :disabled,
              flag_metadata: %{
                "featurevisorReason" => "conditions_unmet"
              }
            }} =
             Provider.resolve_boolean_value(provider, "variable:requirementGate", true, %{})

    Provider.shutdown(provider)
  end

  test "real unmet feature prerequisites map to disabled" do
    datafile =
      put_in(@datafile, ["features", "blockedByRequirement"], %{
        "bucketBy" => "userId",
        "requiredFeatures" => ["missing"],
        "traffic" => [%{"key" => "all", "segments" => "*", "percentage" => 100_000}]
      })

    provider = provider(featurevisor_options: %{datafile: datafile, log_level: :fatal})

    assert {:ok,
            %ResolutionDetails{
              value: false,
              reason: :disabled,
              flag_metadata: %{"featurevisorReason" => "conditions_unmet"}
            }} =
             Provider.resolve_boolean_value(provider, "blockedByRequirement", true, %{})

    Provider.shutdown(provider)
  end

  test "reports malformed datafiles and recovers after replacement" do
    provider = provider(featurevisor_options: %{datafile: "{", log_level: :fatal})

    assert {:ok, %ResolutionDetails{value: false, error_code: :parse_error}} =
             Provider.resolve_boolean_value(provider, "checkout", false, %{})

    assert true == Featurevisor.set_datafile(provider.featurevisor, @datafile, true)

    assert {:ok, %ResolutionDetails{value: true}} =
             Provider.resolve_boolean_value(
               provider,
               "checkout",
               false,
               %{"targetingKey" => "forced-user"}
             )

    assert false == Featurevisor.set_datafile(provider.featurevisor, "{", true)

    assert {:ok, %ResolutionDetails{value: false, error_code: :parse_error}} =
             Provider.resolve_boolean_value(provider, "checkout", false, %{})

    Provider.shutdown(provider)
  end

  test "works through the OpenFeature client" do
    {:ok, initialized} = provider() |> OpenFeature.set_provider()
    assert initialized.state == :ready
    client = OpenFeature.get_client()

    details =
      OpenFeature.Client.get_boolean_details(client, "checkout", false,
        context: %{"targetingKey" => "forced-user"}
      )

    assert details.value
    assert details.reason == :targeting_match
    assert details.flag_metadata["revision"] == "openfeature-test"
  end

  test "client registration retry and unchanged data recover after rejection" do
    provider = provider(featurevisor_options: %{datafile: "{", log_level: :fatal})
    on_exit(fn -> Provider.shutdown(provider) end)
    assert {:error, _reason} = OpenFeature.set_provider(provider)
    refute OpenFeature.get_provider().name == "Featurevisor"
    assert Featurevisor.set_datafile(provider.featurevisor, @datafile, true)
    assert {:ok, _registered} = OpenFeature.set_provider(provider)
    client = OpenFeature.get_client()
    context = %{"targetingKey" => "forced-user"}
    assert OpenFeature.Client.get_boolean_value(client, "checkout", false, context: context)

    assert OpenFeature.Client.get_boolean_details(client, "missing", true).error_code ==
             :flag_not_found

    assert OpenFeature.Client.get_boolean_details(client, "checkout:title", false).error_code ==
             :type_mismatch

    refute Featurevisor.set_datafile(provider.featurevisor, "{", true)
    failed = OpenFeature.Client.get_boolean_details(client, "checkout", false, context: context)
    refute failed.value
    assert failed.error_code == :parse_error
    assert Featurevisor.set_datafile(provider.featurevisor, @datafile, true)
    assert OpenFeature.Client.get_boolean_value(client, "checkout", false, context: context)
  end

  test "client preserves explicitly empty targeting keys" do
    fixture = @provider_fixture

    {:ok, _initialized} =
      Provider.new(featurevisor_options: %{datafile: fixture["datafile"], log_level: :fatal})
      |> OpenFeature.set_provider()

    client = OpenFeature.get_client()
    source = %{"userId" => "forced"}

    assert OpenFeature.Client.get_boolean_details(client, "targetOnly", false, context: source).value

    refute OpenFeature.Client.get_boolean_details(client, "targetOnly", false,
             context: Map.put(source, "targetingKey", "")
           ).value

    refute OpenFeature.Client.get_boolean_details(client, "targetOnly", false,
             context: Map.put(source, "targetingKey", "other")
           ).value

    assert source == %{"userId" => "forced"}

    {:ok, _custom} =
      OpenFeature.set_provider(
        "custom-targeting",
        Provider.new(
          featurevisor_options: %{datafile: fixture["datafile"], log_level: :fatal},
          targeting_key_field: "accountId"
        )
      )

    account = %{"targetingKey" => "", "accountId" => "old"}

    assert OpenFeature.Client.get_boolean_details(
             OpenFeature.get_client("custom-targeting"),
             "accountTargeted",
             false,
             context: account
           ).value

    assert account == %{"targetingKey" => "", "accountId" => "old"}
  end

  test "closes owned instances and leaves borrowed instances open" do
    {:ok, owned_count} = Agent.start_link(fn -> 0 end)

    owned =
      provider(
        featurevisor_options: %{
          modules: [
            %Featurevisor.Module{
              name: "owned",
              close: fn -> Agent.update(owned_count, &(&1 + 1)) end
            }
          ]
        }
      )

    assert :ok = Provider.shutdown(owned)
    assert :ok = Provider.shutdown(owned)
    assert Agent.get(owned_count, & &1) == 1

    {:ok, borrowed_count} = Agent.start_link(fn -> 0 end)

    f =
      Featurevisor.create_featurevisor(%{
        datafile: @datafile,
        modules: [
          %Featurevisor.Module{
            name: "borrowed",
            close: fn -> Agent.update(borrowed_count, &(&1 + 1)) end
          }
        ]
      })

    borrowed = Provider.new(featurevisor: f)
    assert :ok = Provider.shutdown(borrowed)
    assert Agent.get(borrowed_count, & &1) == 0
    assert Featurevisor.enabled?(f, "checkout")
    Featurevisor.close(f)
    assert Agent.get(borrowed_count, & &1) == 1
  end

  test "rejects invalid key grammar" do
    assert_raise ArgumentError, "globalVariablePrefix cannot contain keySeparator", fn ->
      Provider.new(global_variable_prefix: "global:variable")
    end

    assert_raise ArgumentError, "keySeparator cannot be empty", fn ->
      Provider.new(key_separator: "")
    end
  end

  test "normalizes nested dates without mutating the OpenFeature context" do
    parent = self()

    module = %Featurevisor.Module{
      name: "capture",
      before_evaluation: fn options ->
        send(parent, {:context, options.context})
        options
      end
    }

    provider = provider(featurevisor_options: %{datafile: @datafile, modules: [module]})
    date = ~U[2026-01-02 03:04:05.123Z]
    context = %{"targetingKey" => "forced-user", "nested" => %{"dates" => [date]}}

    Provider.resolve_boolean_value(provider, "checkout", false, context)

    assert_receive {:context,
                    %{
                      "targetingKey" => "forced-user",
                      "userId" => "forced-user",
                      "nested" => %{"dates" => ["2026-01-02T03:04:05.123Z"]}
                    }}

    assert context["nested"]["dates"] == [date]
    Provider.shutdown(provider)
  end
end
