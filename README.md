# 0xda-market Core

Provider-agnostic execution and catalog core for turning a client intent into a
quoted, accepted and fulfilled order.

The core does not know which channel submitted a request, which external
identity provider authenticated a user, or which concrete provider fulfills an
order. Capabilities, payloads, quote terms and private provider state remain
opaque documents.

## Architecture

The project follows Dependency Inversion and ports-and-adapters architecture:

```text
channel adapter
    ↓
HTTP transport / application services
    ↓
core domain contracts
    ↑
persistence and fulfillment adapters
```

Dependencies point inward:

- `Core::Kernel` owns intent, quote and order lifecycle rules;
- providers implement the generic `key`, `quote` and `execute` port;
- stores implement persistence ports consumed by domain/application services;
- external identity providers are represented by generic identity records;
- concrete channels belong in dedicated adapter services;
- browser UI and state live in the peer `0xda-market/webapp-core` repository;
- `config.ru` is the composition root and serves backend APIs, not channel webhooks or browser assets.

The detailed boundary contract is documented in
[`docs/architecture/provider-boundaries.md`](docs/architecture/provider-boundaries.md)
and enforced by architecture tests.

## Current capabilities

- immutable intent, quote and order records;
- synchronous and deferred provider execution;
- idempotent quote acceptance and order execution;
- normalized retryable and terminal provider failures;
- optimistic concurrency and transactional PostgreSQL persistence;
- public and operator JSON APIs protected by separate bearer tokens;
- durable manual fulfillment through `ManualProvider`;
- provider-neutral users and external identities;
- internal-UUID administrator authorization;
- localized product catalog and append-only price history;
- market-owned automatic client pricing with broker-safe routing headroom and a server-side profitability gate;
- private price-ranked broker routing with bounded reserve traffic;
- provider-backed, append-only FX snapshots with a hard freshness gate;
- exact localized conversion followed by currency-aware upward presentation;
- broker-owned asset listings with exact quantity and price amounts;
- PostgreSQL and in-memory adapters;
- health-gated development VPS deployment with HTTPS and channel routing.

## Domain lifecycle

```text
intent -> quote -> accepted -> processing -> succeeded
                              |
                              +-> pending -> processing -> succeeded
                              |
                              +-> failed
                              |
                              +-> cancelled
```

A fulfillment provider implements:

```ruby
provider.key
provider.quote(intent:)
provider.execute(order:, idempotency_key:)
```

`quote` returns `Core::Contracts::QuoteResult`. `execute` returns either
`ExecutionResult` or `PendingResult`. Adding a new concrete fulfillment adapter
must not require changing `Core::Kernel`.

## Users and external identities

`market.users` owns the stable internal UUID, role and status.
`market.user_identities` links a user to one or more external identities:

```text
market.users.id
    ├── provider=channel.example, provider_user_id=...
    ├── provider=identity.example, provider_user_id=...
    └── provider=<future adapter>, provider_user_id=...
```

Authenticate an external identity through the generic public endpoint:

```sh
curl -sS http://localhost:9292/v1/auth/external \
  -H 'authorization: Bearer client-secret' \
  -H 'content-type: application/json' \
  -d '{
    "provider": "channel.example",
    "provider_user_id": "123456789",
    "provider_data": {
      "username": "example",
      "language_code": "uk"
    }
  }'
```

The channel adapter validates and constructs provider data. Core stores it as
opaque JSON and returns a stable internal user UUID. Repeated authentication
updates that external identity without replacing the internal user.

Trusted operator clients use the same contract under `/operator` and receive the
`broker` role:

```sh
curl -sS http://localhost:9292/operator/v1/auth/external \
  -H 'authorization: Bearer operator-secret' \
  -H 'content-type: application/json' \
  -d '{
    "provider": "channel.example",
    "provider_user_id": "123456789",
    "provider_data": {"username":"example"}
  }'
```

The request cannot select `admin`. Authentication never grants administrator
rights.

## Administrator authorization

Roles are persisted on internal users. Bootstrap the first administrator once,
after the user has authenticated and received a `market.users.id`:

```sh
DATABASE_URL='postgresql://...' \
  bundle exec ruby bin/bootstrap_admin USER_ID
```

The command is idempotent and accepts only an existing internal user ID.
Administrator operations also use internal IDs:

```sh
curl -sS http://localhost:9292/v1/admin/users/set-admin \
  -H 'authorization: Bearer client-secret' \
  -H 'content-type: application/json' \
  -d '{
    "actor_user_id": "ACTOR_UUID",
    "target_user_id": "TARGET_UUID"
  }'
```

External usernames, external IDs and profile links are resolved by the channel
adapter before this request reaches core.

## Product catalog and pricing

`market.products` stores locale-neutral product state, stable SKU, position,
status, metadata and current USDT price snapshot.

`market.product_localizations` stores display copy per locale. The default locale
is `en_US`; `uk_UA` is seeded for the initial catalog. Resolution falls back from
the requested locale to `en_US`, then to the product short name.

`market.product_prices` is append-only history. Administrator prices use source
`admin`; automatic market prices use `core`; provider FX rows use `fx:<provider>`.
The latest row is the authoritative current price.

For active + marketable products, automatic pricing anchors on the best valid
unit-executable broker ask, adds a bounded market-owned routing headroom, then
uses the same profitability policy enforced during reservation. The default
headroom is 500 bps (5%), so brokers close to the best ask can remain executable
without allowing an expensive competitor to push the buyer price upward. The
worker may create or raise a price but does not automatically lower a profitable
price. See [`docs/architecture/automatic-pricing.md`](docs/architecture/automatic-pricing.md).

The marketable catalog is data owned by database migrations and product
configuration. Core treats product SKUs, provider metadata and fulfillment
metadata as domain data rather than channel implementation behavior.

Currency products are non-marketable catalog rows whose prices represent USDT
paid per unit.

```sh
curl -sS 'http://localhost:9292/v1/products?locale=uk_UA' \
  -H 'authorization: Bearer client-secret'

curl -sS 'http://localhost:9292/v1/currencies?locale=uk_UA' \
  -H 'authorization: Bearer client-secret'
```

## Broker asset listings

Users with role `broker` or `admin` can publish one active listing per asset and
quote currency. Listings store exact decimal quantity and unit price values,
remain owned by the internal `market.users.id`, and use optimistic concurrency
for edits and withdrawal. Channel adapters authenticate the external user before
calling this provider-neutral contract.

The browser never receives database credentials or an internal user ID. It
calls its signed host adapter, which supplies the verified actor ID to core.

## Manual fulfillment

`ManualProvider` converts execution into an operator task:

1. create an intent with capability `manual.fulfillment`;
2. request and accept a quote;
3. execute the order to create an idempotent task;
4. let an operator claim, complete or reject the task;
5. execute the pending order again to resolve the result.

The operator transport depends on a task-service port, not on the concrete
provider class. Production stores tasks in PostgreSQL.

## Provider payment settlement

Core supports provider-neutral settlement terms and generic integer-unit payment
composition. Concrete provider identifiers, unit codes, valuations, SKU policy,
maturity delays, SDKs, protocol methods, and provider-side event validation are
owned by adapter or deployment configuration, not by core defaults.

See
[`docs/architecture/provider-payment-settlement.md`](docs/architecture/provider-payment-settlement.md).

## Research and documentation ownership

Core owns only service-specific, provider-neutral implementation and architecture
documentation. Cross-repository research, provider-specific research, economic
observations, SDK experiments, protocol probes, and provider-specific operating
guidance belong in `0xda-market/docs` or the owning adapter repository.

Research and research-tooling directories are forbidden in this repository. The
boundary is enforced by `test/architecture_boundaries_test.rb` and the required
CI path.

## Run locally

Ruby `3.3.11` is required.

```sh
bundle install

DEPLOY_ENV=development \
PUBLIC_API_TOKEN=client-secret \
MANUAL_PROVIDER_TOKEN=operator-secret \
MARKETPLACE_MIN_MARGIN_BPS=100 \
MARKETPLACE_SUPPLY_BUFFER_BPS=100 \
MARKETPLACE_ROUTING_HEADROOM_BPS=500 \
DATABASE_URL='postgresql://postgres:password@localhost:5432/0xda_market' \
bundle exec rackup
```

Without `MANUAL_PROVIDER_TOKEN`, the application starts with no registered
fulfillment capability but keeps `/health` available. Production requires both
API tokens and `DATABASE_URL`.

Core runtime variables do not include channel tokens or webhook secrets.

Automatic marketplace pricing treats the best valid broker ask as an anchor,
not as the buyer price. `MARKETPLACE_ROUTING_HEADROOM_BPS` creates bounded room
for competitive broker routing; `MARKETPLACE_MIN_MARGIN_BPS` and
`MARKETPLACE_SUPPLY_BUFFER_BPS` then protect market solvency.
`MARKETPLACE_VARIABLE_FEE_BPS` and `MARKETPLACE_FIXED_COST_USDT` add the same
provider-neutral settlement costs used by execution. Automatic pricing never
reduces the broker's promised ask and reservation profitability is revalidated
against the actual selected broker before inventory mutation.

FX acquisition is step 0 of localized pricing. A separate `fx-refresh` process
reads an outward USDT exchange-rate snapshot every five minutes, inverts it into
the core `USDT per unit` contract and appends the complete set with provider
provenance. API requests use only persisted rates. Non-USDT conversion fails
closed when the latest rate exceeds `FX_RATE_MAX_AGE_SECONDS` (one hour by
default); client-facing smart rounding then runs as step 1. See
[`docs/architecture/fx-rate-refresh.md`](docs/architecture/fx-rate-refresh.md).

## Public API lifecycle

```sh
curl -sS http://localhost:9292/v1/intents \
  -H 'authorization: Bearer client-secret' \
  -H 'content-type: application/json' \
  -d '{
    "capability": "manual.fulfillment",
    "payload": {"action": "deliver", "item": "example"},
    "context": {"client_id": "client-1"}
  }'

curl -sS -X POST http://localhost:9292/v1/intents/INTENT_ID/quotes \
  -H 'authorization: Bearer client-secret' \
  -H 'content-type: application/json' -d '{}'

curl -sS -X POST http://localhost:9292/v1/quotes/QUOTE_ID/accept \
  -H 'authorization: Bearer client-secret' \
  -H 'content-type: application/json' -d '{}'

curl -sS -X POST http://localhost:9292/v1/orders/ORDER_ID/execute \
  -H 'authorization: Bearer client-secret' \
  -H 'content-type: application/json' -d '{}'
```

## Operator API

```sh
curl -sS 'http://localhost:9292/operator/v1/tasks?status=pending' \
  -H 'authorization: Bearer operator-secret'

curl -sS -X POST http://localhost:9292/operator/v1/tasks/TASK_ID/claim \
  -H 'authorization: Bearer operator-secret' \
  -H 'content-type: application/json' \
  -d '{"assignee":"operator-1"}'

curl -sS -X POST http://localhost:9292/operator/v1/tasks/TASK_ID/complete \
  -H 'authorization: Bearer operator-secret' \
  -H 'content-type: application/json' \
  -d '{"reference":"external-result-1","data":{"delivered":true}}'
```

## Project operating contract

This repository is the canonical project hub for a solo, mobile-first workflow.
Repository and database work should be completed through the available GitHub and
Supabase connectors instead of delegating connector-capable steps to the owner.

The default delivery path is feature branch → draft pull request → green `test`
check → owner review → merge. The core must remain provider-agnostic, database
changes must be verified against the test Supabase project first, and merge,
deployment or irreversible production actions require explicit owner review.

The complete machine-readable contract, including canonical repositories,
Supabase project references, migration rules, domain invariants and deployment
fallbacks, is stored in
[`PROJECT_INSTRUCTIONS.yaml`](PROJECT_INSTRUCTIONS.yaml).

## Tests

```sh
bundle exec rake
```

CI runs:

- the database-independent Ruby suite;
- PostgreSQL migrations and persistence tests;
- architecture-boundary tests;
- VPS operational script tests;
- the production Docker build.

## Deployment

The VPS is the canonical runtime:

- after green CI, `master` stages or refreshes `development`;
- the shared edge serves `https://0xda-market.nilx.one` and routes channel paths
to their adapter services over the private network;
- active refreshes are health-gated and attempt to restart the previous release
  on failure;
- production directories remain reserved, but production deployment is not
  enabled by the current automatic workflows;
- environment switches, webhook changes, DNS changes and retirement of the old
  host remain separate reviewed operations.

See [`deploy/vps/README.md`](deploy/vps/README.md) for deployment setup and
[`deploy/vps/OPERATIONS.md`](deploy/vps/OPERATIONS.md) for reboot verification,
HTTPS, health, logs, backups and rollback.

## Versioning

Stable releases use Semantic Versioning tags such as `v0.1.0`. Release and
rollback procedures are documented in [RELEASING.md](RELEASING.md), with notable
changes curated in [CHANGELOG.md](CHANGELOG.md).
