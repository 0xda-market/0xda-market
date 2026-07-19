# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-07-19

### Added

- Provider-agnostic intent, quote and order lifecycle with synchronous,
  deferred and idempotent execution.
- PostgreSQL persistence, transactional migrations and a durable manual
  fulfillment queue.
- Authenticated public and operator JSON APIs, health reporting and Telegram
  identity authentication with provider-independent user UUIDs.
- Database-backed product catalog, append-only USDT price history and current
  price snapshots with editor audit data.
- Product localization records with `en_US` as the canonical fallback and a
  complete `uk_UA` catalog.
- Separate Render test and production environments sourced from `master` and
  `release` respectively.

### Changed

- **Breaking:** replaced the `premium_9m` SKU with `premium_12m`; existing
  price history is migrated to the new SKU.
- Moved full product names and Telegram button labels out of `products` and
  into `product_localizations`.
- Price writes now attribute editors to internal user UUIDs instead of using
  Telegram IDs as domain identifiers.

### Fixed

- Recovered stale PostgreSQL connections and aligned Render environment names,
  variables and deployment branches.
- Retained a temporary, read-only-compatible copy of legacy catalog columns so
  the previous core can be redeployed during the v0.1 rollback window.

### Security

- Enforced bearer authentication on public and operator APIs and persisted
  admin-role authorization for privileged operations.

[Unreleased]: https://github.com/0x0sky/0xda-market/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/0x0sky/0xda-market/releases/tag/v0.1.0
