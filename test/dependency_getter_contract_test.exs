defmodule Featurevisor.DependencyGetterContractTest do
  use ExUnit.Case, async: true

  defp feature do
    %{
      "bucketBy" => "id",
      "traffic" => [%{"key" => "all", "conditions" => "*", "percentage" => 100_000}]
    }
  end

  defp datafile(features, variables \\ %{}) do
    %{
      "schemaVersion" => "4",
      "revision" => "getters",
      "segments" => %{},
      "features" => features,
      "variables" => variables
    }
  end

  test "internal flag gating preserves the outer variable and variation requester" do
    for kind <- [:variable, :variation] do
      parent = self()

      subject =
        feature()
        |> Map.merge(%{
          "conditions" => %{"feature" => "gate"},
          "variations" => [%{"value" => "on"}],
          "variablesSchema" => %{"value" => %{"type" => "string", "defaultValue" => "hello"}}
        })
        |> put_in(["traffic", Access.at(0), "variation"], "on")

      f =
        Featurevisor.create_featurevisor(%{
          datafile: datafile(%{"gate" => feature(), "subject" => subject}),
          log_level: :fatal,
          modules: [
            %Featurevisor.Module{
              before_evaluation: fn options ->
                if options[:feature_key] == "gate" and options[:dependency_of],
                  do: send(parent, {:requester, options.dependency_of})

                options
              end
            }
          ]
        })

      try do
        if kind == :variable,
          do: Featurevisor.get_variable(f, "subject", "value"),
          else: Featurevisor.get_variation(f, "subject")

        expected = %{type: kind, feature_key: "subject"}

        expected =
          if kind == :variable, do: Map.put(expected, :variable_key, "value"), else: expected

        assert_receive {:requester, ^expected}
        refute_receive {:requester, _}

        wire =
          Featurevisor.evaluate_variable(f, "subject", "value")
          |> Featurevisor.Evaluation.to_map()

        refute Map.has_key?(wire, "__getter_value_normalized")

        assert_receive {:requester,
                        %{type: :variable, feature_key: "subject", variable_key: "value"}}

        refute_receive {:requester, _}
      after
        Featurevisor.close(f)
      end
    end
  end

  test "condition memo keeps the normalized JSON failure once per public call" do
    parent = self()
    leaf = %{"variable" => "source", "operator" => "isNull"}
    subject = Map.put(feature(), "conditions", [leaf, leaf])

    f =
      Featurevisor.create_featurevisor(%{
        datafile:
          datafile(%{"subject" => subject}, %{
            "source" => %{"type" => "json", "defaultValue" => "{oops"}
          }),
        log_level: :error,
        on_diagnostic: fn diagnostic ->
          if diagnostic.message == "getVariable failed", do: send(parent, :json_failure)
        end
      })

    try do
      for _ <- 1..2 do
        assert Featurevisor.enabled?(f, "subject")
        assert_receive :json_failure
        refute_receive :json_failure
      end
    after
      Featurevisor.close(f)
    end
  end
end
