# Provider boundaries

`0xda-market` applies Dependency Inversion through a ports-and-adapters architecture.
The domain owns its contracts; infrastructure and external systems implement or
consume those contracts from the outside.

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

Dependencies point inward. Domain code never imports an HTTP framework, a
database driver, Telegram, GitHub, a blockchain SDK, or another concrete
provider.

## Core domain

`lib/zero_x_da/market/core` owns:

- intent, quote and order records;
- lifecycle rules;
- provider result contracts;
- failures and concurrency rules;
- the provider and persistence interfaces consumed by `Core::Kernel`.

A provider is a generic fulfillment port identified by a key and capabilities.
`ManualProvider` is one adapter for that port; future TON, Binance, Ethereum or
other adapters must not change `Core::Kernel`.

## External identities

The identity application model stores:

- an internal `market.users.id`;
- zero or more external identities;
- a provider name, provider user ID and opaque provider data for each identity.

`Identity::Service` authenticates generic external identities. It does not know
Telegram fields or validation rules. Administrator authorization uses only the
internal user ID through `Identity::AdminService`.

The public contract is:

```json
{
  "provider": "telegram",
  "provider_user_id": "123456",
  "provider_data": {
    "chat_id": "123456",
    "username": "example"
  }
}
```

The concrete channel adapter constructs this document. Core treats its provider
data as opaque JSON.

## Composition root

`config.ru` is the composition root. It may instantiate concrete infrastructure
adapters, but it only passes them into provider-neutral services and domain
ports. It must not mount channel-specific webhooks or own channel credentials.

Dedicated bot services own Telegram tokens, webhook handling, Telegram input
validation, clickable profile rendering and compatibility mapping.

## Historical schema

Migration `002_telegram_demo.sql` remains in migration history because applied
migration histories are immutable. Its legacy tables are not part of the core
runtime and may be removed later only through a new forward migration after the
production retention and rollback window has been reviewed.

## Enforcement

`test/architecture_boundaries_test.rb` fails when:

- core imports outward layers;
- a concrete provider name enters the runtime boundary;
- a legacy Telegram runtime file returns;
- operator transport imports a concrete provider implementation.

This makes provider independence a checked build property rather than a naming
convention.
