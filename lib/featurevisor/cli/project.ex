defmodule Featurevisor.CLI.Project do
  @moduledoc false

  def json(project, command, args \\ []) do
    case System.cmd("npx", ["featurevisor", command | args ++ ["--json"]],
           cd: project,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case Jason.decode(String.trim(output)) do
          {:ok, value} ->
            {:ok, value}

          {:error, error} ->
            {:error, "Could not parse #{command} output: #{Exception.message(error)}"}
        end

      {output, status} ->
        {:error, "Featurevisor #{command} failed with status #{status}: #{String.trim(output)}"}
    end
  rescue
    error -> {:error, "Could not run npx featurevisor: #{Exception.message(error)}"}
  end

  def targets(project) do
    with {:ok, values} <- json(project, "list", ["--targets"]) do
      {:ok, values |> Enum.map(& &1["key"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()}
    end
  end

  def environments(project) do
    with {:ok, config} <- json(project, "config") do
      values = config["environments"] || []
      {:ok, if(values == [], do: [nil], else: values)}
    end
  end

  def build(project, environment, target, inflate \\ 1) do
    args = []
    args = if environment, do: args ++ ["--environment=#{environment}"], else: args
    args = if target, do: args ++ ["--target=#{target}"], else: args
    args = if inflate > 1, do: args ++ ["--inflate=#{inflate}"], else: args
    json(project, "build", args)
  end

  def datafile_key(environment, nil), do: environment || "false"
  def datafile_key(environment, target), do: "#{environment || "false"}-target-#{target}"
end
