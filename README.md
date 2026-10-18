# Featurevisor SDK for Elixir <!-- omit in toc -->

Use the Featurevisor Elixir SDK to evaluate flags, variations and variables in Elixir applications. It consumes Featurevisor schema version 4 datafiles and retains compatibility with legacy schema version 2 datafiles.

The SDK supports concurrent evaluations, structured diagnostics, lifecycle modules, child instances, and the Featurevisor project test runner.

## Table of contents <!-- omit in toc -->

- [Installation](#installation)
- [Initialization](#initialization)
  - [Public API](#public-api)
- [Supervision](#supervision)
  - [Evaluation types](#evaluation-types)
- [Context](#context)
  - [Setting initial context](#setting-initial-context)
  - [Setting after initialization](#setting-after-initialization)
  - [Passing context for one evaluation](#passing-context-for-one-evaluation)
- [Check if enabled](#check-if-enabled)
- [Getting variation](#getting-variation)
- [Getting variables](#getting-variables)
  - [Getting feature variables](#getting-feature-variables)
  - [Getting global variables](#getting-global-variables)
  - [Type specific getters](#type-specific-getters)
- [Conditions](#conditions)
- [Composed variables](#composed-variables)
- [Getting evaluations](#getting-evaluations)
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
- [OpenFeature](#openfeature)
- [CLI usage](#cli-usage)
  - [Test](#test)
  - [Benchmark](#benchmark)
  - [Assess distribution](#assess-distribution)
- [GitHub repositories](#github-repositories)
- [Development](#development)
- [Publishing](#publishing)
- [License](#license)

<!-- FEATUREVISOR_DOCS_BEGIN -->

## Installation

Upgrading an existing application? Follow the [Elixir migration guide](https://featurevisor.com/docs/migrations/v4/elixir/).

Add `featurevisor` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:featurevisor, "~> 2.0"}
  ]
end
```

Then install dependencies:

```sh
mix deps.get
```

## Initialization

Initialize with a decoded datafile:

```elixir
datafile =
  "featurevisor-all.json"
  |> File.read!()
  |> Jason.decode!()

f = Featurevisor.create_featurevisor(%{datafile: datafile})

try do
  IO.puts(Featurevisor.enabled?(f, "checkout", %{"userId" => "123"}))
after
  Featurevisor.close(f)
end
```

File read and JSON parsing errors raise before initialization. This example closes the instance after evaluation.

Create one long lived instance for your application and share it between processes. The convenience constructor is not linked to the calling process, so its owner must call `Featurevisor.close/1` during application shutdown.

You may pass the JSON string directly:

```elixir
f = Featurevisor.create_featurevisor(%{datafile: File.read!("featurevisor-all.json")})
```

Invalid datafiles do not replace the active datafile. They report an `invalid_datafile` diagnostic with the stable message `Could not parse datafile`.

### Public API

Create instances with `Featurevisor.create_featurevisor/1`. The returned `Featurevisor` handle is the main SDK instance.

Most applications use:

- `Featurevisor.create_featurevisor/1`
- `Featurevisor.start_link/1` and `Featurevisor.instance/1` for supervision
- `Featurevisor.enabled?/2`
- `Featurevisor.get_variation/2`
- `Featurevisor.get_variable/3`
- `Featurevisor.close/1`
- `Featurevisor.Module` for extensions
- `Featurevisor.Diagnostic` for observability
- `Featurevisor.Evaluation` for detailed results

The datafile and context use Elixir maps with string keys. This preserves the JSON wire format and avoids a second public reader API.

## Supervision

Use a supervised instance in long running OTP applications:

```elixir
children = [
  {Featurevisor,
   name: MyApp.Featurevisor,
   datafile: datafile,
   log_level: :warn}
]

Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
```

Resolve its Featurevisor handle wherever it is needed:

```elixir
f = Featurevisor.instance(MyApp.Featurevisor)
Featurevisor.enabled?(f, "checkout", %{"userId" => "123"})
```

The supervisor owns shutdown and restart. Module close callbacks run during supervised shutdown. Resolve the handle again after a restart to use the new instance.

### Evaluation types

Featurevisor evaluates four kinds of values:

- [**Flag**](#check-if-enabled) (`boolean()`): whether the feature is enabled or not
- [**Variation**](#getting-variation) (`String.t()`): the variation of the feature (if any)
- [**Feature variable**](#getting-feature-variables): a configuration value owned by a feature
- [**Global variable**](#getting-global-variables): a configuration value evaluated independently of a feature

Every evaluation uses the active datafile and the effective context.

## Context

Contexts are maps of attributes used by conditions and bucketing. Use string keys so nested paths and datafile attribute names match exactly.

Conditions compare these attributes using the [operators](https://featurevisor.com/docs/operators/), including `empty` and `notEmpty`.

Date comparisons accept portable timestamp strings and `DateTime` values, not `Date` or `NaiveDateTime`. Offsets must stay within 14 hours and both local and UTC years within 0001 to 9999. Fractions are truncated to milliseconds. Invalid values make both `before` and `after` return `false`.

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
Featurevisor.set_context(f, %{"userId" => "456"}, true) # replace
```

### Passing context for one evaluation

```elixir
context = %{"country" => "de"}

Featurevisor.enabled?(f, "checkout", context)
Featurevisor.get_variation(f, "checkout", context)
Featurevisor.get_variable(f, "checkout", "title", context)
```

Evaluation context wins over stored context for matching keys.

## Check if enabled

```elixir
if Featurevisor.enabled?(f, "checkout", %{"userId" => "123"}) do
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

Provide a fallback when no variation is selected:

```elixir
Featurevisor.get_variation(
  f,
  "checkout_experiment",
  context,
  %{default_variation_value: "control"}
)
```

## Getting variables

### Getting feature variables

```elixir
title = Featurevisor.get_variable(f, "checkout", "title", context)
```

JSON variables are decoded before they are returned.

### Getting global variables

Global variables use separate function names so feature ownership remains clear:

```elixir
email = Featurevisor.get_global_variable(f, "supportEmail", context)
evaluation = Featurevisor.evaluate_global_variable(f, "supportEmail", context)
```

Overrides and conditions are applied for you. See [Variables](https://featurevisor.com/docs/variables/#global-variables) and [Conditions](https://featurevisor.com/docs/conditions/) for how to define them. To see which overrides changed a value, read `variable_override_paths` from `evaluate_global_variable/3`.

Modules should return the same result for the same input during one evaluation. Pass values that change through context.

### Type specific getters

Use a typed getter when your application wants runtime type validation:

```elixir
enabled = Featurevisor.get_variable_boolean(f, "checkout", "enabled", context)
title = Featurevisor.get_variable_string(f, "checkout", "title", context)
count = Featurevisor.get_variable_integer(f, "checkout", "count", context)
ratio = Featurevisor.get_variable_number(f, "checkout", "ratio", context)
items = Featurevisor.get_variable_array(f, "checkout", "items", context)
config = Featurevisor.get_variable_object(f, "checkout", "config", context)
json = Featurevisor.get_variable_json(f, "checkout", "json", context)
```

Typed getters return `nil` for a mismatched value and do not coerce strings, booleans, or collections.

`get_variable_number/5` and `get_global_variable_number/4` read a variable of type `number`, whether it holds `3` or `4.5`. Datafiles built before v4 call that type `double`, and it reads the same way. The v3 names `get_variable_double/5` and `get_global_variable_double/4` were removed in v4.

## Conditions

[Conditions](https://featurevisor.com/docs/conditions/) provide one expression grammar for segments, feature and global variable root gates, force entries, traffic rules and variable overrides. Leaves compare an attribute, name a segment, check a feature or compare a global or feature variable. A bare string is a segment key. Feature checks default to enabled. Variable comparisons may include a compiled path array, with the variable key treated literally.

Arrays imply AND. Logical groups use `and`, `or` and `not`. NOT negates the AND of its direct children. Empty new arrays and groups do not match. Evaluation preserves expression order and short circuits. The builder compiles authored paths and stringified selectors for SDK consumption.

Sticky state wins first. Feature force entries precede root conditions. Otherwise roots must match before traffic rules. Global variable roots run before sources and overrides. An unmet root returns `:conditions_unmet` with `evaluation.conditions`. Disabled variations and feature variables keep their ordinary fallback reasons and values.

Condition dependencies use ordinary getters, modules, effective context and sticky state without inheriting the outer getter's explicit defaults. Missing values and explicit null remain distinct during path comparisons. Cycles and more than 256 combined internal handoffs fail the complete evaluation, and the next public call starts a fresh session.

## Composed variables

[Composed variables](https://featurevisor.com/docs/variables/#compose-values) read other values at runtime. A string composition is an alias of a literal global variable key. A map composition collects feature enabled state, variations, feature variables and global variables under literal property names.

For example, a generated datafile may contain:

```elixir
variables = %{
  "policy" => %{"type" => "object", "defaultValue" => %{"limit" => 50}},
  "policyAlias" => %{"type" => "object", "compose" => "policy"},
  "screen" => %{
    "type" => "object",
    "compose" => [
      %{"key" => "enabled", "feature" => "checkout"},
      %{"key" => "policy", "variable" => "policyAlias"},
      %{"key" => "variation", "feature" => "checkout", "variation" => true}
    ]
  }
}
```

Use the familiar getters after loading the datafile:

```elixir
Featurevisor.get_global_variable(f, "policyAlias", context)
Featurevisor.get_global_variable_object(f, "screen", context)
```

An alias returns its source value directly, preserving false, zero, empty strings, arrays and null. JSON sources decode exactly once, even if their decoded value resembles JSON text. Map composition creates an outer map without flattening member values. Elixir values are immutable, and runtime mutations cannot change a source, sibling property or sticky value.

Compositions have no `defaultValue` or `useDefaultWhenDisabled`. Optional root conditions can return `disabledValue`, otherwise null, without reading sources or overrides. Whole variable sticky state bypasses assembly. All sources are read before an override program runs. Nested compositions and overrides use the same getter pipeline and mutation interpreter as ordinary variables.

Detailed results use `:variable_composed`, or `:variable_override_rule` when an override matches. Ordinary missing or failed source getters retain their normal false or null fallback. Dependency cycles and depth errors fail the whole composition.

## Getting evaluations

```elixir
features = Featurevisor.get_feature_evaluations(f, context)
variables = Featurevisor.get_global_variable_evaluations(f, context)
```

Pass feature keys to evaluate a selected set:

```elixir
features = Featurevisor.get_feature_evaluations(f, context, ["checkout", "pricing"])
variables = Featurevisor.get_global_variable_evaluations(f, context, ["supportEmail"])
```

## Sticky

Treat sticky values supplied at creation or through setters as read only inputs. Use a setter to change sticky state. Returned evaluation values can be used independently.

Sticky values keep selected evaluations stable for the lifetime of an instance or child instance.

### Setting initial sticky values

```elixir
f = Featurevisor.create_featurevisor(%{
  datafile: datafile,
  sticky_features: %{
    "checkout" => %{
      "enabled" => true,
      "variation" => "treatment",
      "variables" => %{"title" => "Welcome back"}
    }
  },
  sticky_variables: %{"supportEmail" => "sticky@example.com"}
})
```

### Updating sticky values

```elixir
Featurevisor.set_sticky_features(f, sticky_features)
Featurevisor.set_sticky_variables(f, sticky_variables)
Featurevisor.set_sticky_features(f, replacement, true) # replace
```

Sticky values are instance state. They are not accepted as public per evaluation options.

## Setting datafile

`set_datafile/3` accepts a decoded map or JSON string.

It returns `true` when the datafile is accepted, including when its revision and contents are unchanged. It returns `false` when the input is rejected or the instance is closed. Accepted input still emits `:datafile_set`, even when unchanged. Diagnostic and event callback failures do not change the return value.

Invalid input retains the last valid datafile and reports the existing error diagnostic without emitting `:datafile_set`. The return value is a boolean, not `:ok` or `{:error, reason}`. Read `diagnostic.original_error` through your diagnostic callback or the `:error` event when you need the rejection reason. Closed instances do not emit diagnostics or events for attempted updates.

### Merging by default

Incoming features, global variables, and segments are merged into the stored datafile. Incoming entries replace entries with the same key. Legacy schema version 2 selectors normalize eagerly before merging, without changing the supplied map. Schema version 4 entities normalize lazily on their first read. Informational schema version metadata is retained. A partial update invalidates incoming entity caches only. Complete replacement clears them all.

```elixir
accepted = Featurevisor.set_datafile(f, next_datafile)
```

### Replacing

Pass `true` to replace the complete datafile:

```elixir
accepted = Featurevisor.set_datafile(f, next_datafile, true) # replace
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

Malformed stringified selector JSON fails that complete selector, including through negated segment aliases, without rejecting the accepted datafile or affecting unrelated entities. A broken root reports `:conditions_unmet`. The error level `conditions_parse_error` diagnostic appears once per malformed selector per incoming entity load: during schema version 2 setting, after accepted storage, or on the first schema version 4 entity read, after caching. Its details contain exactly `conditions`, `entityType` and `entityKey`. There is no location field. Diagnostic callbacks can safely reenter getters.

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
- `:sticky_features_set`
- `:sticky_variables_set`
- `:error`

The `:datafile_set` details include changed `features` and `variables`, including dependants affected by changed feature, variable and segment conditions or composition sources. Additions and removals propagate through transitive mixed dependencies.

## Evaluation details

Use detailed methods when you need reasons, rule keys, bucket values, or matched definitions:

```elixir
flag = Featurevisor.evaluate_flag(f, "checkout", context)
variation = Featurevisor.evaluate_variation(f, "checkout", context)
variable = Featurevisor.evaluate_variable(f, "checkout", "title", context)
global_variable = Featurevisor.evaluate_global_variable(f, "supportEmail", context)
```

Each method returns a `Featurevisor.Evaluation` struct. Common fields include `type`, `reason`, entity keys, `conditions`, selected rule and force metadata, value and schema metadata, and matched override keys, paths and indexes. Accumulation includes `variable_override_paths`. Unmet root conditions use `:conditions_unmet`. Successful compositions use `:variable_composed`. Use `Featurevisor.Evaluation.to_map/1` for camelCase wire field names.

## Modules

The before evaluation and after evaluation phases each use the module membership at the start of that phase. Where an evaluation uses bucketing, the bucket key and bucket value phases each use their own starting membership. Adding or removing a module during a phase does not change the iteration already in progress. The next phase uses the membership then installed. A module added before the after phase can receive after callbacks for evaluations already in progress, even if it did not receive their before callbacks. A module removed before the after phase receives no after callback.

Module options expose `dependency_of` on internal reads. It identifies the immediate requesting evaluation with `type`, optional `feature_key` and optional `variable_key`. `dependency_purpose` is `:condition` or `:composition`. Independent application calls have neither marker and never receive private session state. Memoization is local to a public call and separates purposes, requester identities, context and current instance state.

Modules extend evaluation and lifecycle behaviour without changing evaluation methods.

```elixir
module = %Featurevisor.Module{
  name: "audit",
  setup: fn api ->
    IO.puts("Revision: #{api.get_revision.()}")
  end,
  before_evaluation: fn options ->
    %{options | context: Map.put_new(options.context, "service", "checkout")}
  end,
  bucket_value: fn options ->
    options.bucket_value
  end,
  after_evaluation: fn evaluation, _options ->
    evaluation
  end,
  close: fn ->
    :ok
  end
}

remove = Featurevisor.add_module(f, module)
remove.()
```

Module callbacks are `setup`, `before_evaluation`, `bucket_key`, `bucket_value`, `after_evaluation`, and `close`. Evaluation callbacks run in registration order and surround the complete evaluation once, including accumulating global override programs. Condition dependencies and composition sources use the same module pipeline. Callback option maps use idiomatic snake case keys such as `bucket_key` and `bucket_value`.

Named duplicates are rejected with a `duplicate_module` diagnostic. A failed setup is removed, its diagnostic subscriptions are cleared, and its close callback is invoked.

## Child instance

A child has isolated context, sticky state, and local listeners while sharing its parent's datafile, modules, and diagnostics.

```elixir
child = Featurevisor.spawn(
  f,
  %{"accountId" => "account-123"},
  %{sticky_features: sticky_features, sticky_variables: sticky_variables}
)

Featurevisor.Child.enabled?(child, "checkout", %{"userId" => "user-456"})
Featurevisor.Child.get_variation(child, "checkout")
Featurevisor.Child.get_variable(child, "checkout", "title")
Featurevisor.Child.get_variable_string(child, "checkout", "title")
Featurevisor.Child.get_global_variable(child, "supportEmail")
Featurevisor.Child.get_feature_evaluations(child)
Featurevisor.Child.get_global_variable_evaluations(child)

Featurevisor.Child.close(child)
```

Existing parent context keys are snapshotted when the child is created. Parent keys added later are inherited. Child context wins over parent context, and per evaluation context wins over child context.

## Close

Close an instance when its owner stops:

```elixir
Featurevisor.close(f)
```

Close invokes module close callbacks and removes listeners, diagnostic subscriptions, and caches. Calling close more than once is safe.

An evaluation already in progress can finish using its retained datafile. Its resources are released when it finishes.

Do not call `close/1` directly for a supervised instance. Stop its supervisor or remove its child instead. A closed handle evaluates against an empty datafile, so flags return `false`, variations and variables return `nil`, and the revision returns `"unknown"`.

## OpenFeature

The OpenFeature provider is published as a separate Hex package. Applications that only use the Featurevisor SDK do not install or compile OpenFeature or the provider code.

```elixir
def deps do
  [
    {:featurevisor, "~> 2.0"},
    {:featurevisor_openfeature, "~> 2.0"},
    {:open_feature, "~> 0.1.3"}
  ]
end
```

Create a provider that owns its Featurevisor instance:

```elixir
provider =
  FeaturevisorOpenFeature.Provider.new(
    featurevisor_options: %{datafile: datafile}
  )

{:ok, provider} = OpenFeature.set_provider(provider)
client = OpenFeature.get_client()

enabled =
  OpenFeature.Client.get_boolean_value(client, "checkout", false,
    context: %{"targetingKey" => "user-123"}
  )
```

Pass an existing Featurevisor instance for the provider to borrow. The provider does not close it:

```elixir
provider = FeaturevisorOpenFeature.Provider.new(featurevisor: f)
```

OpenFeature uses one flag key while Featurevisor supports flags, variations, feature variables, and global variables:

| OpenFeature key | Featurevisor evaluation |
| --- | --- |
| `checkout` | Flag for feature `checkout` |
| `checkout:variation` | Variation for feature `checkout` |
| `checkout:title` | Variable `title` inside feature `checkout` |
| `variable:supportEmail` | Global variable `supportEmail` |

`targeting_key_field`, `key_separator`, `variation_key`, and `global_variable_prefix` customize this mapping. The targeting key maps to `userId` by default. The global variable prefix defaults to `variable` and cannot contain the separator.

The official OpenFeature Elixir SDK represents evaluation context as a map. The provider accepts `"targetingKey"`, `"targeting_key"`, or `:targeting_key` and copies its string value to the configured Featurevisor targeting field.

The provider implements boolean, string, number, and map resolution. Root `conditions_unmet` maps to OpenFeature `DISABLED`. Compositions and matched overrides map to `TARGETING_MATCH`. Composed values are already evaluated and are not JSON decoded again. Featurevisor evaluation reasons, variation values, revision, schema version, rule keys, bucket information, and override information are mapped to OpenFeature resolution details and flag metadata. Missing definitions, type mismatches, and invalid datafiles use standard OpenFeature errors. Replacing an invalid datafile with a valid one recovers the provider.

The OpenFeature Elixir SDK does not currently expose provider tracking. Featurevisor modules and diagnostics continue to run inside the Featurevisor instance.

An invalid initial datafile makes provider initialization return `{:error, :parse_error}`, independently of `log_level`. A valid update restores evaluation health. Initialize or register the provider again after a failed registration. Shutdown removes provider subscriptions and closes only an owned instance.

See the [OpenFeature provider guide](https://featurevisor.com/docs/sdks/openfeature/) for the shared key convention and providers for other languages.

## CLI usage

Build the escript from this SDK repository:

```bash
mix deps.get
mix escript.build
```

The native test runner requires `@featurevisor/cli` 4.0.0 or later and Node.js 24 or later. Install the Node.js CLI in your Featurevisor project:

```bash
npm install --save-dev @featurevisor/cli@^4.0.0
```

Project parsing, test definitions, execution protocol, matrix expansion and datafile generation use `npx featurevisor`. Evaluations run through this Elixir SDK. Use the Node.js CLI directly for authoring commands. This native CLI provides only test, benchmark and distribution commands. The SDK runtime has no Node.js dependency.

Options use kebab case, such as `--project-directory-path`. The camelCase forms from earlier releases still work, and `--root-directory-path` is an alias for `--project-directory-path`. Pass values as `--name=value` or `--name value`. Repeat `--target` to select several targets in order. Run `<command> --help` to list every option.

Duplicate targets are evaluated once, at their first position.

### Test

```bash
./featurevisor test \
  --project-directory-path=/path/to/featurevisor-project \
  --only-failures
```

See [Testing](https://featurevisor.com/docs/testing/) for authoring specs and [Checks](https://featurevisor.com/docs/testing/#checks) for check syntax and operators.

Useful test options:

- `--key-pattern=<pattern>` and `--assertion-pattern=<pattern>` filter tests.
- `--entity-type=scenario` selects scenarios. `--set=<set>` selects one project set. Omitting `--set` runs all sets.
- `--case=<id>` reruns one expanded case. Copy the opaque ID or rerun command from a failure report.
- `--json --pretty` produces an indented JSON report.
- `--coverage` reports observed rule and override selections. `--uncovered` lists features and global variables without associated specs.
- `--only-failures`, `--quiet`, `--verbose` and `--show-datafile` control diagnostic output.

Segment owners and checks evaluate through ordinary SDK gates with the selected environment, Target, fixed bucket, effective context and sticky state. Selected compiled Target segments remain authoritative. The execution protocol restores missing definitions from its compiled transitive `_segments` map. Attribute only segment chains can run without an environment, while dependent segments require the selected datafile. Check references are preflighted transitively before any getter runs. Synthetic segment helper features are excluded from coverage.

Linting remains a separate authoring step. The native `test` command does not automatically run `lint`.

Printed rerun commands use POSIX shell quoting. JSON reports also include raw argument arrays.

### Benchmark

The examples below use a project without environments. Add `--environment=<name>` if your project configures environments. In a sets project, omit `--set` to run every set or pass `--set=<name>`. Repeat `--target=<key>` to evaluate specific target datafiles. The Node.js CLI validates these options and builds the datafiles. Elixir evaluates them. Replace `checkout` with a feature defined in your project.

```bash
./featurevisor benchmark \
  --project-directory-path=/path/to/featurevisor-project \
  --feature=checkout \
  --context='{"country":"nl"}' \
  --n=1000
```

Use `--variation` for a variation or `--variable=<key>` for a feature variable. Omit `--feature` to benchmark a global variable. Do not combine `--variation` with `--variable`. See [Benchmarking](https://featurevisor.com/docs/cli/#benchmarking).

### Assess distribution

```bash
./featurevisor assess-distribution \
  --project-directory-path=/path/to/featurevisor-project \
  --feature=checkout \
  --populate-uuid=userId \
  --n=1000
```

Repeat `--populate-uuid=<key>` or `--populate-uuid <key>` to generate UUID values for multiple context attributes. Add `--verbose` to print generated contexts. Both measurement commands accept `--n=1000`, `--n 1000`, `-n=1000` and `-n 1000`. Counts must be positive integers. Quote JSON context and paths containing spaces as one shell argument. See [Assess distribution](https://featurevisor.com/docs/cli/#assess-distribution).

## GitHub repositories

- SDK: [featurevisor/featurevisor-elixir](https://github.com/featurevisor/featurevisor-elixir)
- Example application: [featurevisor/featurevisor-example-elixir](https://github.com/featurevisor/featurevisor-example-elixir)

<!-- FEATUREVISOR_DOCS_END -->

<a id="getting-all-evaluations"></a>

The aggregate evaluation reference has moved to [Getting evaluations](#getting-evaluations).

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

The native tests cover runtime conformance and project integration.

Run `mix test test/readme_initialization_test.exs` to execute the actual initialization snippet with an isolated local datafile. The check covers evaluation, cleanup and failures, and also runs in the ordinary SDK suite and CI.

`make check` verifies both the base SDK and OpenFeature provider. The separate `make test-example-1` target requires the sibling Featurevisor monorepo, so checks and publishing workflows run that integration after the package gate.

## Publishing

Before tagging a release:

```sh
make check
mix hex.publish --dry-run
```

The repository publishes `featurevisor` and `featurevisor_openfeature` with the same version. The release workflow verifies the tag, package contents, documentation, and `example-1` integration, then publishes the base package before the provider package.

Hex can only resolve the provider's exact base package dependency after the matching `featurevisor` release is visible. The workflow waits for that release before it performs the final provider dry run and publication.

The published Hex package includes runtime source, tests, both canonical conformance fixtures, `mix.exs`, the README, and the licence so its source distribution can run the same verification.

## License

MIT © [Fahad Heylaal](https://fahad19.com)
