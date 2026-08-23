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
      log_level: :fatal,
      modules: [%Module{name: "lifecycle", close: fn -> send(parent, :module_closed) end}]
    }

    assert Featurevisor.child_spec(options).id == name
    {:ok, supervisor} = Supervisor.start_link([{Featurevisor, options}], strategy: :one_for_one)

    f = Featurevisor.instance(name)
    assert Featurevisor.enabled?(f, "flag", %{"country" => "nl"})

    first_pid = f.pid
    Process.exit(first_pid, :kill)
    restarted_pid = wait_for_restart(name, first_pid, 50)
    assert restarted_pid != first_pid

    restarted = Featurevisor.instance(name)
    assert restarted.pid == restarted_pid
    assert Featurevisor.enabled?(restarted, "flag", %{"country" => "nl"})

    Supervisor.stop(supervisor)
    assert_receive :module_closed

    assert_raise ArgumentError, "Featurevisor instance is not running", fn ->
      Featurevisor.instance(name)
    end
  end

  defp wait_for_restart(_name, _previous, 0), do: flunk("Featurevisor child did not restart")

  defp wait_for_restart(name, previous, attempts) do
    case GenServer.whereis(name) do
      pid when is_pid(pid) and pid != previous ->
        pid

      _ ->
        Process.sleep(10)
        wait_for_restart(name, previous, attempts - 1)
    end
  end
end
