defmodule Featurevisor.TestFixtures do
  @moduledoc false
  def datafile do
    %{
      "schemaVersion" => "2",
      "featurevisorVersion" => "3.5.0",
      "revision" => "test",
      "segments" => %{
        "nl" => %{
          "conditions" =>
            Jason.encode!([%{"attribute" => "country", "operator" => "equals", "value" => "nl"}])
        },
        "mobile" => %{
          "conditions" => [
            %{"attribute" => "device", "operator" => "equals", "value" => "mobile"}
          ]
        }
      },
      "features" => %{
        "flag" => %{
          "key" => "flag",
          "hash" => "flag-hash",
          "bucketBy" => "userId",
          "traffic" => [
            %{"key" => "nl", "segments" => ["nl"], "percentage" => 100_000, "enabled" => true},
            %{"key" => "everyone", "segments" => "*", "percentage" => 50_000}
          ]
        },
        "experiment" => %{
          "key" => "experiment",
          "hash" => "experiment-hash",
          "bucketBy" => "userId",
          "variations" => [
            %{"value" => "control", "variables" => %{"title" => "Control"}},
            %{"value" => "treatment", "variables" => %{"title" => "Treatment"}}
          ],
          "variablesSchema" => %{
            "title" => %{"type" => "string", "defaultValue" => "Default"},
            "count" => %{"type" => "integer", "defaultValue" => 0},
            "config" => %{"type" => "json", "defaultValue" => "{\"enabled\":true}"}
          },
          "traffic" => [
            %{
              "key" => "everyone",
              "segments" => "*",
              "percentage" => 100_000,
              "allocation" => [
                %{"variation" => "control", "range" => [0, 50_000]},
                %{"variation" => "treatment", "range" => [50_000, 100_000]}
              ]
            }
          ]
        },
        "forced" => %{
          "key" => "forced",
          "bucketBy" => "userId",
          "variablesSchema" => %{"colour" => %{"type" => "string", "defaultValue" => "blue"}},
          "force" => [
            %{"segments" => ["nl"], "enabled" => true, "variables" => %{"colour" => "orange"}}
          ],
          "traffic" => []
        }
      }
    }
  end
end
