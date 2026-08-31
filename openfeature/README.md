# Featurevisor OpenFeature provider for Elixir

This Hex package adapts the Featurevisor Elixir SDK to the official OpenFeature Elixir SDK.

## Installation

```elixir
def deps do
  [
    {:featurevisor, "~> 1.2"},
    {:featurevisor_openfeature, "~> 1.2"},
    {:open_feature, "~> 0.1.3"}
  ]
end
```

The provider is a separate package, so applications that only use
`featurevisor` do not install or compile OpenFeature.

## Usage

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

You can also pass an existing Featurevisor instance. The provider borrows it
and does not close it:

```elixir
provider = FeaturevisorOpenFeature.Provider.new(featurevisor: f)
```

Featurevisor supports several evaluation types through one OpenFeature key:

| OpenFeature key | Featurevisor evaluation |
| --- | --- |
| `checkout` | Flag for feature `checkout` |
| `checkout:variation` | Variation for feature `checkout` |
| `checkout:title` | Variable `title` inside feature `checkout` |
| `variable:supportEmail` | Global variable `supportEmail` |

`targeting_key_field`, `key_separator`, `variation_key`, and
`global_variable_prefix` customize this mapping. The targeting key maps to
`userId` by default. The provider accepts `"targetingKey"`,
`"targeting_key"`, and `:targeting_key` in the OpenFeature context.

The provider implements boolean, string, number, and map resolution.
Featurevisor reasons and evaluation metadata are mapped to OpenFeature
resolution details. Missing definitions, type mismatches, and invalid
datafiles use standard OpenFeature errors. Replacing an invalid datafile with
a valid one recovers the provider.

Calling `shutdown/1` releases provider subscriptions. It also closes a
Featurevisor instance created by the provider, but never closes a borrowed
instance.

The current OpenFeature Elixir SDK does not expose provider tracking.
Featurevisor modules and diagnostics continue to run inside the Featurevisor
instance.

See the [Featurevisor Elixir SDK documentation](https://featurevisor.com/docs/sdks/elixir/#openfeature)
and the [shared OpenFeature provider guide](https://featurevisor.com/docs/sdks/openfeature/)
for more details.
