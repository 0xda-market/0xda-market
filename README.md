# 0xda Market

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
- concrete channels such as Telegram belong in dedicated adapter services;
- `config.ru` is the composition root and does not mount channel webhooks.

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
- PostgreSQL and in-memory adapters;
- health-gated development VPS deployment with Caddy HTTPS and bot routing.

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
`ExecutionResult` or `PendingResult`. Adding TON, Binance, Ethereum or another
provider must not require changing `Core::Kernel`.

## Users and external identities

`market.users` owns the stable internal UUID, role and status.
`market.user_identities` links a user to one or more external identities:

```text
market.users.id
    ├── provider=telegram, provider_user_id=...
    ├── provider=github, provider_user_id=...
    └── provider=<future adapter>, provider_user_id=...
```

Authenticate an external identity through the generic public endpoint:

```sh
curl -sS http://localhost:9292/v1/auth/external \
  -H 'authorization: Bearer client-secret' \
  -H 'content-type: application/json' \
  -d '{
    "provider": "telegram",
    "provider_user_id": "123456789",
    "provider_data": {
      "chat_id": "123456789",
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
    "provider": "telegram",
    "provider_user_id": "123456789",
    "provider_data": {"chat_id": "123456789"}
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

External usernames, chat IDs and profile links are resolved by the channel
adapter before this request reaches core.

## Product catalog and pricing

`market.products` stores locale-neutral product state, stable SKU, position,
status, metadata and current USDT price snapshot.

`market.product_localizations` stores display copy per locale. The default locale
is `en_US`; `uk_UA` is seeded for the initial catalog. Resolution falls back from
the requested locale to `en_US`, then to the product short name.

`market.product_prices` is append-only history. Every editor is recorded through
`market.users.id`, never through an external provider identifier.

The initial marketable catalog contains:

- Telegram Premium for 3, 6 and 12 months;
- Telegram Stars 500, 1000 and 3000;
- TON, BTC and ETH.

Currency products `USDT`, `USD`, `UAH` and `RUB` are non-marketable catalog rows
whose prices represent USDT paid per unit.

```sh
curl -sS 'http://localhost:9292/v1/products?locale=uk_UA' \
  -H 'authorization: Bearer client-secret'

curl -sS 'http://localhost:9292/v1/currencies?locale=uk_UA' \
  -H 'authorization: Bearer client-secret'
```

## Manual fulfillment

`ManualProvider` converts execution into an operator task:

1. create an intent with capability `manual.fulfillment`;
2. request and accept a quote;
3. execute the order to create an idempotent task;
4. let an operator claim, complete or reject the task;
5. execute the pending order again to resolve the result.

The operator transport depends on a task-service port, not on the concrete
provider class. Production stores tasks in PostgreSQL.

## Run locally

Ruby `3.3.11` is required.

```sh
bundle install

DEPLOY_ENV=development \
PUBLIC_API_TOKEN=client-secret \
MANUAL_PROVIDER_TOKEN=operator-secret \
DATABASE_URL='postgresql://postgres:password@localhost:5432/0xda_market' \
bundle exec rackup
```

Without `MANUAL_PROVIDER_TOKEN`, the application starts with no registered
fulfillment capability but keeps `/health` available. Production requires both
API tokens and `DATABASE_URL`.

Core runtime variables do not include channel tokens or webhook secrets.

## Public API lifecycle

```sh
curl -sS http://localhost:9292/v1/intents \
  -H 'authorization: Bearer client-secret' \
  -H 'content-type: application/json' \
  -d '{
    "capability": "manual.fulfillment",
    "payload": {"action": "deliver", "item": "example"},
    "context": {"customer_id": "customer-1"}
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
- Caddy serves `https://0xda-market.nilx.one` and forwards `/bot/*` to the client
  bot over the private edge network;
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
