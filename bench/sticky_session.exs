# Serial, per getter benchmark with a constructed sticky handoff corpus.
# Run with: mix run bench/sticky_session.exs 5000

iterations =
  case Enum.drop_while(System.argv(), &(&1 == "--")) do
    [value | _] -> String.to_integer(value)
    _ -> 5000
  end

if iterations < 1, do: raise("positive iteration count required")

datafile = %{
  "schemaVersion" => "2",
  "revision" => "sticky-bench",
  "segments" => %{},
  "features" => %{
    "gate" => %{
      "bucketBy" => "userId",
      "traffic" => [%{"key" => "all", "segments" => "*", "percentage" => 100_000}]
    }
  },
  "variables" => %{
    "leaf" => %{"type" => "integer", "defaultValue" => 1},
    "root" => %{
      "type" => "integer",
      "defaultValue" => 1,
      "disabledValue" => 0,
      "requiredFeatures" => ["gate", "gate"],
      "requiredVariables" => [
        %{"variable" => "leaf", "operator" => "equals", "value" => 1},
        %{"variable" => "leaf", "operator" => "equals", "value" => 1}
      ]
    }
  }
}

IO.puts("kind,size,scope,iterations,mean_us")

for kind <- [:features, :variables], size <- [0, 100, 1000, 5000], scope <- [:instance, :child] do
  filler =
    if size <= 1,
      do: %{},
      else: for(index <- 1..(size - 1), into: %{}, do: {"unrelated#{index}", index})

  features =
    if kind == :features and size > 0,
      do:
        Map.put(Map.new(filler, fn {key, _} -> {key, %{"enabled" => true}} end), "gate", %{
          "enabled" => true
        }),
      else: %{}

  variables = if kind == :variables and size > 0, do: Map.put(filler, "leaf", 1), else: %{}
  sticky = %{sticky_features: features, sticky_variables: variables}

  options =
    %{datafile: datafile, log_level: :fatal}
    |> Map.merge(if(scope == :instance, do: sticky, else: %{}))

  f = Featurevisor.create_featurevisor(options)
  child = if scope == :child, do: Featurevisor.spawn(f, %{"userId" => "bench"}, sticky), else: nil

  getter =
    if child,
      do: fn -> Featurevisor.Child.get_global_variable(child, "root") end,
      else: fn -> Featurevisor.get_global_variable(f, "root", %{"userId" => "bench"}) end

  for _ <- 1..100 do
    if getter.() != 1, do: raise("unexpected gated value")
  end

  total_ns =
    Enum.reduce(1..iterations, 0, fn _, total ->
      started = System.monotonic_time(:nanosecond)
      value = getter.()
      elapsed = System.monotonic_time(:nanosecond) - started
      if value != 1, do: raise("unexpected gated value")
      total + elapsed
    end)

  IO.puts(
    "#{kind},#{size},#{scope},#{iterations},#{Float.round(total_ns / iterations / 1000, 3)}"
  )

  if child, do: Featurevisor.Child.close(child)
  Featurevisor.close(f)
end
