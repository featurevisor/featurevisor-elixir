# Featurevisor SDK for Elixir <!-- omit in toc -->

This is the official Featurevisor SDK for Elixir. It evaluates feature flags, variations, and variables in Elixir applications using Featurevisor schema version 2 datafiles.

The SDK supports concurrent evaluations, structured diagnostics, lifecycle modules, child instances, and the Featurevisor project test runner.

## Table of contents <!-- omit in toc -->

- [Installation](#installation)
- [Public API](#public-api)
- [Initialization](#initialization)
- [Evaluation types](#evaluation-types)
- [Context](#context)
  - [Setting initial context](#setting-initial-context)
  - [Setting after initialization](#setting-after-initialization)
  - [Passing context for one evaluation](#passing-context-for-one-evaluation)
- [Check if enabled](#check-if-enabled)
- [Getting variation](#getting-variation)
- [Getting variables](#getting-variables)
  - [Type specific getters](#type-specific-getters)
- [Getting all evaluations](#getting-all-evaluations)
- [Sticky](#sticky)
  - [Setting initial sticky values](#setting-initial-sticky-values)
  - [Updating sticky values](#updating-sticky-values)
- [Setting datafile](#setting-datafile)
  - [Merging by default](#merging-by-default)
  - [Replacing](#replacing)
  - [Loading datafiles](#loading-datafiles)
- [Diagnostics](#diagnostics)
  - [Levels](#levels)
  - [Handler](#handler)
- [Events](#events)
- [Evaluation details](#evaluation-details)
- [Modules](#modules)
- [Child instance](#child-instance)
- [Close](#close)
- [CLI usage](#cli-usage)
  - [Test](#test)
  - [Benchmark](#benchmark)
  - [Assess distribution](#assess-distribution)
- [Development](#development)
- [Publishing](#publishing)
- [License](#license)

<!-- FEATUREVISOR_DOCS_BEGIN -->

## Installation

Add `featurevisor` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:featurevisor, "~> 0.1"}
  ]
end
```

Then install dependencies:

```sh
mix deps.get
```

## Public API

Create instances with `Featurevisor.create_featurevisor/1`. The returned `Featurevisor` handle is the main SDK instance.

Most applications use:

- `Featurevisor.create_featurevisor/1`
- `Featurevisor.enabled?/2`
- `Featurevisor.get_variation/2`
- `Featurevisor.get_variable/3`
- `Featurevisor.close/1`
- `Featurevisor.Module` for extensions
- `Featurevisor.Diagnostic` for observability
- `Featurevisor.Evaluation` for detailed results

The datafile and context use ordinary Elixir maps with string keys. This preserves the JSON wire format and avoids a second public reader API.

## Initialization

Initialize with a decoded datafile:

```elixir
datafile =
  "datafile.json"
  |> File.read!()
  |> Jason.decode!()

f = Featurevisor.create_featurevisor(%{datafile: datafile})
```

Create one long lived instance for your application and share it between processes. Evaluation reads immutable ETS snapshots and does not queue through the instance process. The convenience constructor is not linked to the calling process, so the owner must call `Featurevisor.close/1` during application shutdown.

You may pass the JSON string directly:

```elixir
f = Featurevisor.create_featurevisor(%{datafile: File.read!("datafile.json")})
```

Invalid datafiles do not replace the active datafile. They report an `invalid_datafile` diagnostic with the stable message `Could not parse datafile`.

## Evaluation types

Featurevisor evaluates three kinds of values:

- a flag answers whether a feature is enabled
- a variation returns a variation value
- a variable returns remote configuration for a feature

Every evaluation uses the active datafile and the effective context.

## Context

Contexts are maps of attributes used by conditions and bucketing. Use string keys so nested paths and datafile attribute names match exactly.

Date conditions accept ISO 8601 strings with an explicit time zone and native `DateTime` values.

### Setting initial context

```elixir
f = Featurevisor.create_featurevisor(%{
  datafile: datafile,
  context: %{
    "userId" => "123",
    "country" => "nl"
  }
})
```

### Setting after initialization

Context is merged by default:

```elixir
Featurevisor.set_context(f, %{"device" => "mobile"})
```

Pass `true` to replace all stored context:

```elixir
Featurevisor.set_context(f, %{"userId" => "456"}, true)
```

### Passing context for one evaluation

```elixir
context = %{"country" => "de"}

Featurevisor.enabled?(f, "my_feature", context)
Featurevisor.get_variation(f, "my_feature", context)
Featurevisor.get_variable(f, "my_feature", "title", context)
```

Evaluation context wins over stored context for matching keys.

## Check if enabled

```elixir
if Featurevisor.enabled?(f, "my_feature", %{"userId" => "123"}) do
  # show the enabled experience
end
```

The idiomatic Elixir `enabled?/4` function corresponds to `isEnabled` in the JavaScript SDK and similarly named methods in other Featurevisor SDKs.

## Getting variation

```elixir
case Featurevisor.get_variation(f, "checkout_experiment", context) do
  "control" -> show_control()
  "treatment" -> show_treatment()
  nil -> show_fallback()
end
```

Provide an explicit fallback when no variation is selected:

```elixir
Featurevisor.get_variation(
  f,
  "checkout_experiment",
  context,
  %{default_variation_value: "control"}
)
```

## Getting variables

```elixir
title = Featurevisor.get_variable(f, "checkout", "title", context)
```

JSON variables are decoded before they are returned.

### Type specific getters

Use a typed getter when your application wants runtime type validation:

```elixir
enabled = Featurevisor.get_variable_boolean(f, "checkout", "enabled", context)
title = Featurevisor.get_variable_string(f, "checkout", "title", context)
count = Featurevisor.get_variable_integer(f, "checkout", "count", context)
ratio = Featurevisor.get_variable_double(f, "checkout", "ratio", context)
items = Featurevisor.get_variable_array(f, "checkout", "items", context)
config = Featurevisor.get_variable_object(f, "checkout", "config", context)
json = Featurevisor.get_variable_json(f, "checkout", "json", context)
```

Typed getters return `nil` for a mismatched value and do not coerce strings, booleans, or collections.

## Getting all evaluations

```elixir
evaluations = Featurevisor.get_all_evaluations(f, context)
```

Pass feature keys to evaluate a selected set:

```elixir
evaluations = Featurevisor.get_all_evaluations(f, context, ["checkout", "pricing"])
```

## Sticky

Sticky values keep selected evaluations stable for the lifetime of an instance or child instance.

### Setting initial sticky values

```elixir
f = Featurevisor.create_featurevisor(%{
  datafile: datafile,
  sticky: %{
    "checkout" => %{
      "enabled" => true,
      "variation" => "treatment",
      "variables" => %{"title" => "Welcome back"}
    }
  }
})
```

### Updating sticky values

```elixir
Featurevisor.set_sticky(f, sticky)
Featurevisor.set_sticky(f, replacement, true)
```

Sticky values are instance state. They are not accepted as public per evaluation options.

## Setting datafile

`set_datafile/3` accepts a decoded map or JSON string.

### Merging by default

Incoming features and segments are merged into the stored datafile. Incoming entries replace entries with the same key.

```elixir
Featurevisor.set_datafile(f, next_datafile)
```

### Replacing

Pass `true` to replace the complete datafile:

```elixir
Featurevisor.set_datafile(f, next_datafile, true)
```

### Loading datafiles

Use the HTTP client and scheduling tools already present in your application. Pass each successful response body to `set_datafile/3`. The SDK does not start a background fetch process or choose an HTTP client for you.

## Diagnostics

Diagnostics are the only SDK observability API. There is no separate logger handler.

### Levels

The levels are `:fatal`, `:error`, `:warn`, `:info`, and `:debug`.

```elixir
Featurevisor.set_log_level(f, :warn)
```

### Handler

```elixir
f = Featurevisor.create_featurevisor(%{
  datafile: datafile,
  log_level: :warn,
  on_diagnostic: fn diagnostic ->
    Logger.warning("#{diagnostic.code}: #{diagnostic.message}")
  end
})
```

Every `Featurevisor.Diagnostic` contains `level`, `code`, `message`, and an always present `details` map. Error diagnostics also emit the `:error` event.

Featurevisor project linting enforces the portable regular expression subset shared by all SDKs. The Elixir runtime treats the `g` flag as a compatibility no op. Invalid patterns or flags produce a `condition_match_error` diagnostic and do not match.

## Events

Register event callbacks with `Featurevisor.on/3`. The returned unsubscribe function is idempotent.

```elixir
unsubscribe = Featurevisor.on(f, :datafile_set, fn details ->
  IO.inspect(details, label: "datafile changed")
end)

unsubscribe.()
```

Supported events are:

- `:datafile_set`
- `:context_set`
- `:sticky_set`
- `:error`

## Evaluation details

Use detailed methods when you need reasons, rule keys, bucket values, or matched definitions:

```elixir
flag = Featurevisor.evaluate_flag(f, "checkout", context)
variation = Featurevisor.evaluate_variation(f, "checkout", context)
variable = Featurevisor.evaluate_variable(f, "checkout", "title", context)
```

Each method returns a `Featurevisor.Evaluation` struct.

## Modules

Modules extend evaluation and lifecycle behaviour without changing evaluation methods.

```elixir
module = %Featurevisor.Module{
  name: "audit",
  setup: fn api ->
    IO.puts("Revision: #{api.get_revision.()}")
  end,
  before: fn options ->
    %{options | context: Map.put_new(options.context, "service", "checkout")}
  end,
  bucket_value: fn options ->
    options.bucket_value
  end,
  after: fn evaluation, _options ->
    evaluation
  end,
  close: fn ->
    :ok
  end
}

remove = Featurevisor.add_module(f, module)
remove.()
```

Module callbacks are `setup`, `before`, `bucket_key`, `bucket_value`, `after`, and `close`. Callback option maps use idiomatic snake case keys such as `bucket_key` and `bucket_value`.

Named duplicates are rejected with a `duplicate_module` diagnostic. A failed setup is removed, its diagnostic subscriptions are cleared, and its close callback is invoked.

## Child instance

A child has isolated context, sticky state, and local listeners while sharing its parent's datafile, modules, and diagnostics.

```elixir
child = Featurevisor.spawn(
  f,
  %{"accountId" => "account-123"},
  %{sticky: sticky}
)

Featurevisor.Child.enabled?(child, "checkout", %{"userId" => "user-456"})
Featurevisor.Child.get_variation(child, "checkout")
Featurevisor.Child.get_variable(child, "checkout", "title")
Featurevisor.Child.get_variable_string(child, "checkout", "title")
Featurevisor.Child.get_all_evaluations(child)

Featurevisor.Child.close(child)
```

Existing parent context keys are snapshotted when the child is created. Parent keys added later are inherited. Child context wins over parent context, and per evaluation context wins over child context.

## Close

Close an instance when its owner stops:

```elixir
Featurevisor.close(f)
```

Close invokes module close callbacks and removes listeners, diagnostic subscriptions, and caches. Calling close more than once is safe.

## CLI usage

Build the escript from this repository:

```sh
mix escript.build
```

The Elixir runner delegates project parsing, Target discovery, matrix expansion, and datafile generation to `npx featurevisor`. Evaluations and assertions run through this Elixir SDK.

### Test

```sh
./featurevisor test \
  --projectDirectoryPath=../featurevisor/examples/example-1 \
  --onlyFailures
```

Use one or more Targets when required:

```sh
./featurevisor test \
  --projectDirectoryPath=../featurevisor/examples/example-1 \
  --target=all \
  --target=checkout
```

### Benchmark

```sh
./featurevisor benchmark \
  --projectDirectoryPath=../featurevisor/examples/example-1 \
  --environment=production \
  --feature=allowSignup \
  --variation \
  --context='{"country":"nl"}' \
  --n=1000000
```

Benchmark output reports total duration and the minimum, average, and maximum duration of individual evaluations.

### Assess distribution

```sh
./featurevisor assess-distribution \
  --projectDirectoryPath=../featurevisor/examples/example-1 \
  --environment=production \
  --feature=allowSignup \
  --context='{"country":"nl"}' \
  --populateUuid=userId \
  --n=10000
```

Repeat `--target` and `--populateUuid` where needed.

<!-- FEATUREVISOR_DOCS_END -->

## Development

Install dependencies and run the complete local gate:

```sh
mix deps.get
make check
```

Run the SDK against the sibling Featurevisor example project:

```sh
make test-example-1
```

The integration target executes all expanded `example-1` assertions, including Target datafiles, through the Elixir evaluator.

`make check` remains the fast package gate. The separate `make test-example-1` target requires the sibling Featurevisor monorepo, so checks and publishing workflows run that integration explicitly after the package gate.

## Publishing

Before tagging a release:

```sh
make check
mix hex.publish --dry-run
```

The release workflow verifies the tag, package contents, documentation, and `example-1` integration before publishing to Hex.pm.

The published Hex package intentionally includes runtime source, `mix.exs`, the README, and the licence. Tests and the conformance fixture remain repository verification assets and are not shipped to consumers.

## License

MIT. See [LICENSE](LICENSE).
