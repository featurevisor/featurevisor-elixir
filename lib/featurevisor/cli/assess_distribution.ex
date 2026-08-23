defmodule Featurevisor.CLI.AssessDistribution do
  @moduledoc false
  alias Featurevisor.CLI.Project

  def run(options) do
    targets = if options.target == [], do: [nil], else: Enum.uniq(options.target)

    Enum.reduce_while(targets, :ok, fn target, :ok ->
      case Project.build(
             options.project_directory_path,
             options.environment,
             target,
             options.inflate
           ) do
        {:ok, datafile} ->
          f = Featurevisor.create_featurevisor(%{datafile: datafile, log_level: :fatal})
          base_context = Jason.decode!(options.context)

          counts =
            Enum.reduce(
              1..options.n,
              %{enabled: 0, disabled: 0, variations: %{}, unassigned: 0},
              fn index, counts ->
                context =
                  Enum.reduce(
                    options.populate_uuid,
                    base_context,
                    &Map.put(&2, &1, deterministic_uuid(index, &1))
                  )

                enabled = Featurevisor.enabled?(f, options.feature, context)
                variation = Featurevisor.get_variation(f, options.feature, context)

                counts =
                  Map.update!(counts, if(enabled, do: :enabled, else: :disabled), &(&1 + 1))

                if variation,
                  do: update_in(counts, [:variations, variation], &((&1 || 0) + 1)),
                  else: Map.update!(counts, :unassigned, &(&1 + 1))
              end
            )

          IO.puts("\nAssess Featurevisor distribution")
          IO.puts("Feature: #{options.feature}")
          IO.puts("Environment: #{options.environment || false}")
          if target, do: IO.puts("Target: #{target}")
          IO.puts("Iterations: #{options.n}")
          IO.puts("\nFlag evaluations")
          print_count("enabled", counts.enabled, options.n)
          print_count("disabled", counts.disabled, options.n)

          IO.puts("\nVariation evaluations")

          Enum.each(counts.variations, fn {variation, count} ->
            print_count(variation, count, options.n)
          end)

          print_count("unassigned", counts.unassigned, options.n)
          Featurevisor.close(f)
          {:cont, :ok}

        error ->
          {:halt, error}
      end
    end)
  end

  defp print_count(label, count, total) do
    percentage = :erlang.float_to_binary(count / total * 100, decimals: 2)
    IO.puts("#{label}: #{count} (#{percentage}%)")
  end

  defp deterministic_uuid(index, key) do
    hash =
      for salt <- 0..3, into: <<>> do
        value = :erlang.phash2({key, index, salt}, 4_294_967_295)
        <<value::32>>
      end
      |> Base.encode16(case: :lower)

    "#{String.slice(hash, 0, 8)}-#{String.slice(hash, 8, 4)}-4#{String.slice(hash, 13, 3)}-a#{String.slice(hash, 17, 3)}-#{String.slice(hash, 20, 12)}"
  end
end
