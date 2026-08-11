# Provider boundaries

`0xda-market` applies Dependency Inversion through a ports-and-adapters architecture. The domain owns its contracts; infrastructure and external systems implement or consume those contracts from the outside.

## Dependency direction

```text
external channel adapter
        ↓
HTTP transport / application service
        ↓
domain contracts and records
        ↑
persistence and fulfillment adapters
```

Dependencies point inward. Domain code never imports an HTTP framework, a database driver, a channel SDK, a provider protocol client, or another concrete external integration.

## Core domain

`lib/zero_x_da/market/core` owns:

- intent, quote and order records;
- lifecycle rules;
- provider result contracts;
- failures and concurrency rules;
- provider and persistence interfaces consumed by `Core::Kernel`.

A provider is a generic fulfillment port identified by a key and capabilities. Concrete adapters must not require changes to `Core::Kernel`.

## External identities

The identity application model stores:

- an internal `market.users.id`;
- zero or more external identities;
- a provider name, provider user ID and opaque provider data for each identity.

`Identity::Service` authenticates generic external identities. It does not know channel-specific fields or validation rules. Administrator authorization uses only the internal user ID through `Identity::AdminService`.

The public shape is intentionally generic:

```json
{
  "provider": "channel.example",
  "provider_user_id": "123456",
  "provider_data": {
    "username": "example"
  }
}
```

The concrete channel adapter constructs this document. Core treats provider data as opaque JSON.

## Composition root

`config.ru` is the composition root. It may instantiate generic infrastructure adapters, but it only passes them into provider-neutral services and domain ports. It must not mount channel-specific webhooks, own channel credentials, embed provider protocol methods, or encode provider-specific economics.

Concrete channel services own tokens, webhook handling, host-specific input validation, provider SDK integration, and compatibility mapping.

Provider-specific payment configuration is supplied as opaque runtime data to generic composition primitives. Core may validate generic invariants such as positive amounts, exact currency matches, maturity timestamps, and idempotency; it must not encode a concrete provider's rate, hold period, API method, or SKU policy.

## Documentation and research ownership

This repository may document only core-owned, provider-neutral architecture and implementation contracts.

The canonical `0xda-market/docs` repository owns:

- cross-repository research;
- provider-specific research and economic observations;
- provider-specific operational guidance;
- external API and SDK research;
- product/domain documentation that spans multiple services.

Research artifacts, provider SDK probes, provider protocol clients, session tooling, and provider-specific research documents are forbidden in core even when they are placed under a generic `docs` or `tools` directory.

## Historical schema

Applied migration history is immutable. Legacy migration names or opaque provider values may therefore remain in historical database migrations when changing them would violate the migration checksum contract. They do not authorize new provider-specific runtime behavior.

## Enforcement

`test/architecture_boundaries_test.rb` is a build gate. It fails when:

- core imports outward layers;
- a concrete provider leaks into protected runtime source;
- research or research-tooling paths are added to the repository;
- provider-specific documentation is added to core-owned documentation;
- provider SDK or protocol artifacts are added to core tooling;
- operator transport imports a concrete provider implementation.

`PROJECT_INSTRUCTIONS.yaml` records the same ownership rule as a machine-readable project contract. CI runs the architecture test explicitly before integration validation so this boundary is enforced rather than advisory.
