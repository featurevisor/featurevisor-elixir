defmodule Featurevisor.ModulesAndChildTest do
  use ExUnit.Case, async: true
  alias Featurevisor.Module

  test "module lifecycle, diagnostics, transformations, removal, and duplicate names" do
    parent = self()

    f =
      Featurevisor.create_featurevisor(%{
        datafile: Featurevisor.TestFixtures.datafile(),
        log_level: :debug,
        on_diagnostic: fn diagnostic -> send(parent, {:instance, diagnostic}) end
      })

    module = %Module{
      name: "audit",
      setup: fn api ->
        send(parent, {:revision, api.get_revision.()})

        api.on_diagnostic.(fn diagnostic -> send(parent, {:module, diagnostic}) end, %{
          log_level: :debug
        })

        api.report_diagnostic.(%{level: :info, code: "ready", message: "ready", details: %{}})
      end,
      before: fn options -> %{options | context: Map.put(options.context, "country", "nl")} end,
      bucket_key: fn options -> options.bucket_key <> ".module" end,
      bucket_value: fn _ -> 75_000 end,
      after: fn evaluation, _ -> evaluation end,
      close: fn -> send(parent, :closed) end
    }

    unsubscribe = Featurevisor.add_module(f, module)
    assert_receive {:revision, "test"}
    assert_receive {:instance, %{code: "ready", module: "audit"}}
    assert Featurevisor.enabled?(f, "flag", %{"userId" => "1"})
    assert Featurevisor.get_variation(f, "experiment", %{"userId" => "1"}) == "treatment"

    assert Featurevisor.add_module(f, %{module | close: nil}) == nil
    assert_receive {:instance, %{code: "duplicate_module", module_name: "audit"}}
    unsubscribe.()
    unsubscribe.()
    assert_receive :closed
    Featurevisor.close(f)
  end

  test "child snapshots existing parent keys, inherits new keys, and owns sticky" do
    f =
      Featurevisor.create_featurevisor(%{
        datafile: Featurevisor.TestFixtures.datafile(),
        context: %{"country" => "nl", "plan" => "free"},
        log_level: :fatal
      })

    child =
      Featurevisor.spawn(f, %{"country" => "de"}, %{sticky: %{"flag" => %{"enabled" => true}}})

    Featurevisor.set_context(f, %{"country" => "us", "plan" => "pro", "region" => "eu"}, true)

    assert Featurevisor.Child.get_context(child) == %{
             "country" => "de",
             "plan" => "free",
             "region" => "eu"
           }

    assert Featurevisor.Child.enabled?(child, "flag")
    Featurevisor.Child.close(child)
    Featurevisor.Child.close(child)
    Featurevisor.close(f)
  end

  test "callbacks may re-enter the instance without deadlocking" do
    parent = self()

    f =
      Featurevisor.create_featurevisor(%{
        datafile: Featurevisor.TestFixtures.datafile(),
        log_level: :debug,
        on_diagnostic: fn _ -> :ok end
      })

    Featurevisor.on(f, :context_set, fn _ ->
      send(parent, {:revision, Featurevisor.get_revision(f)})
    end)

    Featurevisor.set_context(f, %{"country" => "nl"})
    assert_receive {:revision, "test"}
    Featurevisor.close(f)
  end

  test "concurrent module registration reserves names and returned unsubscribers survive close" do
    parent = self()
    f = Featurevisor.create_featurevisor(%{log_level: :fatal})
    gate = make_ref()

    module = %Module{
      name: "one",
      setup: fn _ ->
        send(parent, {:setup, self()})

        receive do
          {:continue, ^gate} -> :ok
        end
      end
    }

    first = Task.async(fn -> Featurevisor.add_module(f, module) end)
    assert_receive {:setup, setup_process}
    assert Featurevisor.add_module(f, module) == nil
    send(setup_process, {:continue, gate})
    unsubscribe = Task.await(first)

    event_unsubscribe = Featurevisor.on(f, :context_set, fn _ -> :ok end)
    Featurevisor.close(f)
    assert unsubscribe.() == :ok
    assert event_unsubscribe.() == :ok
  end
end
