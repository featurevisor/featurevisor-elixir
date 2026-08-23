defmodule Featurevisor.CLITest do
  use ExUnit.Case, async: true
  alias Featurevisor.CLI.Project

  test "datafile cache keys match the JavaScript runner" do
    assert Project.datafile_key(nil, nil) == "false"
    assert Project.datafile_key("production", nil) == "production"
    assert Project.datafile_key(nil, "checkout") == "false-target-checkout"
    assert Project.datafile_key("production", "checkout") == "production-target-checkout"
  end

  test "validates commands before delegating to Node" do
    assert {:error, "--feature is required"} = Featurevisor.CLI.execute(["benchmark"])

    assert {:error, "--n must be a positive integer"} =
             Featurevisor.CLI.execute(["benchmark", "--feature=foo", "--n=0"])

    assert {:error, "--context must be a JSON object"} =
             Featurevisor.CLI.execute(["benchmark", "--feature=foo", "--context=[]"])

    assert {:error, _} = Featurevisor.CLI.execute(["benchmark", "--feature=foo", "--unknown"])
  end

  test "legacy flags remain accepted and ignored" do
    assert {:error, "--feature is required"} =
             Featurevisor.CLI.execute([
               "benchmark",
               "--with-scopes",
               "--with-tags",
               "--schemaVersion=1"
             ])

    assert {:error, "--feature is required"} =
             Featurevisor.CLI.execute(["benchmark", "--schema-version=1"])
  end
end
