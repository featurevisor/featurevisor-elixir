defmodule Featurevisor.CLI.Project do
  @moduledoc false

  @doc false
  # Node starts the project's own CLI entry directly. Without a local package,
  # npx resolves the CLI as before.
  def node_command(project) do
    project
    |> Path.expand()
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.reduce_while(nil, fn directory, _ ->
      entry = Path.join([directory, "node_modules", "@featurevisor", "cli", "bin.js"])

      cond do
        File.regular?(entry) -> {:halt, ["node", entry]}
        Path.dirname(directory) == directory -> {:halt, ["npx", "featurevisor"]}
        true -> {:cont, nil}
      end
    end)
  end

  def json(project, command, args \\ []) do
    stderr_path =
      Path.join(
        System.tmp_dir!(),
        "featurevisor-stderr-#{System.pid()}-#{:erlang.unique_integer([:positive])}"
      )

    case File.open(stderr_path, [:write, :exclusive]) do
      {:ok, file} ->
        File.close(file)

        try do
          File.chmod!(stderr_path, 0o600)
          # Arguments remain positional, so project values never become shell syntax.
          [executable | prefix] = node_command(project)

          {output, status} =
            if match?({:win32, _}, :os.type()) do
              # Preserve native Windows invocation without requiring a POSIX shell.
              # System.cmd forwards stderr to the terminal without mixing JSON.
              System.cmd(executable, prefix ++ [command | args ++ ["--json"]], cd: project)
            else
              System.cmd(
                "sh",
                [
                  "-c",
                  "stderr_file=$1; shift; exec \"$@\" 2>\"$stderr_file\"",
                  "featurevisor",
                  stderr_path,
                  executable
                ] ++ prefix ++ [command | args ++ ["--json"]],
                cd: project
              )
            end

          stderr = File.read!(stderr_path)

          case status do
            0 ->
              if stderr != "", do: IO.write(:stderr, stderr)

              case Jason.decode(String.trim(output)) do
                {:ok, value} ->
                  {:ok, value}

                {:error, error} ->
                  {:error, "Could not parse #{command} output: #{Exception.message(error)}"}
              end

            _ ->
              diagnostics =
                if stderr == "" and match?({:win32, _}, :os.type()),
                  do: "Diagnostics were written to standard error.\n" <> output,
                  else: stderr <> "\n" <> output

              {:error,
               "Featurevisor #{command} failed with status #{status}: #{String.trim(diagnostics)}"}
          end
        after
          File.rm(stderr_path)
        end

      {:error, reason} ->
        {:error, "Could not capture npx diagnostics: #{:file.format_error(reason)}"}
    end
  rescue
    error -> {:error, "Could not run npx featurevisor: #{Exception.message(error)}"}
  end

  def targets(project, set \\ nil) do
    with {:ok, values} <- json(project, "list", ["--targets"] ++ set_args(set)) do
      {:ok, values |> Enum.map(& &1["key"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()}
    end
  end

  def environments(project) do
    with {:ok, config} <- json(project, "config") do
      values = config["environments"] || []
      {:ok, if(values == [], do: [nil], else: values)}
    end
  end

  def sets(project, selected) do
    with {:ok, config} <- json(project, "config") do
      cond do
        config["sets"] == false and is_binary(selected) ->
          {:error, "This project does not use Sets. Omit --set."}

        is_binary(selected) ->
          {:ok, [selected]}

        config["sets"] == true ->
          case File.ls(config["setsDirectoryPath"]) do
            {:ok, entries} ->
              sets =
                entries
                |> Enum.filter(&File.dir?(Path.join(config["setsDirectoryPath"], &1)))
                |> Enum.sort()

              if sets == [],
                do: {:error, "No sets found in #{config["setsDirectoryPath"]}."},
                else: {:ok, sets}

            {:error, reason} ->
              {:error, "Could not list project sets: #{:file.format_error(reason)}"}
          end

        true ->
          {:ok, [nil]}
      end
    end
  end

  def build(project, environment, target, inflate \\ 1, set \\ nil) do
    args = []
    args = if environment, do: args ++ ["--environment=#{environment}"], else: args
    args = if target, do: args ++ ["--target=#{target}"], else: args
    args = if inflate > 1, do: args ++ ["--inflate=#{inflate}"], else: args
    args = args ++ set_args(set)
    json(project, "build", args)
  end

  def evaluation_selections(options) do
    with :ok <- validate_iterations(options),
         {:ok, config} <- json(options.project_directory_path, "config"),
         :ok <- validate_environment(config, options.environment),
         {:ok, sets} <- sets(options.project_directory_path, options.set) do
      targets = if options.target == [], do: [nil], else: Enum.uniq(options.target)
      {:ok, for(set <- sets, target <- targets, do: {set, target})}
    end
  end

  defp validate_iterations(%{n: n, inflate: inflate}) when n > 0 and inflate > 0, do: :ok

  defp validate_iterations(_), do: {:error, "--n and --inflate must be positive integers"}

  defp validate_environment(%{"environments" => environments}, environment)
       when is_list(environments) do
    cond do
      is_nil(environment) ->
        {:error, "--environment is required for a project with configured environments"}

      environment in environments ->
        :ok

      true ->
        {:error, "Unknown environment #{inspect(environment)}"}
    end
  end

  defp validate_environment(%{"environments" => _}, _),
    do: {:error, "Invalid configured environments"}

  defp validate_environment(_, nil), do: :ok

  defp validate_environment(_, _),
    do: {:error, "--environment cannot be used in a project without environments"}

  def datafile_key(environment, target), do: {environment, target}

  defp set_args(nil), do: []
  defp set_args(set), do: ["--set=#{set}"]
end
