defmodule Featurevisor.EventsAndConcurrencyTest do
  use ExUnit.Case, async: true
  alias Featurevisor.Module

  test "events and unsubscribe functions are idempotent" do
    parent = self()
    f = Featurevisor.create_featurevisor(%{log_level: :fatal})

    unsubscribe =
      Featurevisor.on(f, :datafile_set, fn details -> send(parent, {:datafile, details}) end)

    Featurevisor.set_datafile(f, Featurevisor.TestFixtures.datafile(), true)

    assert_receive {:datafile,
                    %{
                      revision: "test",
                      previousRevision: "unknown",
                      revisionChanged: true,
                      replaced: true
                    }}

    unsubscribe.()
    unsubscribe.()
    Featurevisor.set_datafile(f, Featurevisor.TestFixtures.datafile(), true)
    refute_receive {:datafile, _}
    Featurevisor.close(f)
  end

  test "many callers evaluate concurrently against one immutable snapshot" do
    f =
      Featurevisor.create_featurevisor(%{
        datafile: Featurevisor.TestFixtures.datafile(),
        log_level: :fatal
      })

    tasks =
      for index <- 1..2_000,
          do:
            Task.async(fn ->
              Featurevisor.enabled?(f, "flag", %{
                "userId" => Integer.to_string(index),
                "country" => "nl"
              })
            end)

    assert Enum.all?(Task.await_many(tasks, 10_000))
    Featurevisor.close(f)
  end

  test "supervision owns lifecycle and closes modules on shutdown" do
    parent = self()
    name = {:global, {__MODULE__, make_ref()}}

    options = %{
      name: name,
      datafile: Featurevisor.TestFixtures.datafile(),
      log_level: :info,
      on_diagnostic: fn
        %{code: "sdk_initialized"} ->
          send(parent, {:sdk_initialized, Featurevisor.instance(name).pid})

        _ ->
          :ok
      end,
      modules: [%Module{name: "lifecycle", close: fn -> send(parent, :module_closed) end}]
    }

    assert Featurevisor.child_spec(options).id == name
    {:ok, supervisor} = Supervisor.start_link([{Featurevisor, options}], strategy: :one_for_one)

    f = Featurevisor.instance(name)
    first_pid = f.pid
    assert_receive {:sdk_initialized, ^first_pid}, 5_000
    assert Featurevisor.enabled?(f, "flag", %{"country" => "nl"})

    monitor = Process.monitor(first_pid)
    Process.exit(first_pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^first_pid, :killed}, 5_000

    # Name registration precedes datafile loading in the child start callback.
    # Wait for SDK initialization rather than treating a new PID as ready.
    assert_receive {:sdk_initialized, restarted_pid}, 5_000
    assert restarted_pid != first_pid

    restarted = Featurevisor.instance(name)
    assert restarted.pid == restarted_pid
    assert Featurevisor.enabled?(restarted, "flag", %{"country" => "nl"})

    Supervisor.stop(supervisor)
    assert_receive :module_closed, 5_000

    assert_raise ArgumentError, "Featurevisor instance is not running", fn ->
      Featurevisor.instance(name)
    end
  end
end
