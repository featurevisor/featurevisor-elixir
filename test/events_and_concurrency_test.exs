defmodule Featurevisor.EventsAndConcurrencyTest do
  use ExUnit.Case, async: true

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
end
