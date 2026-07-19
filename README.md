# 0xda Market

Provider-agnostic execution core for turning a client intent into a quoted,
accepted and fulfilled order.

The core does not know what is being bought, sold or performed. Capabilities,
payloads, quote terms and provider state remain opaque JSON documents, so a
provider can represent a blockchain operation, a digital product or a human
workflow without changing the lifecycle engine.

## Current status

The repository contains a runnable Rack application with:

- immutable intent, quote and order records;
- provider contracts and normalized provider failures;
- idempotent quote acceptance and order execution;
- synchronous and deferred execution;
- optimistic concurrency and transactional PostgreSQL storage;
- an optionally authenticated public JSON API;
- an authenticated operator API for `ManualProvider`;
- a durable manual fulfillment workflow;
- two webhook-based Telegram demo bots for the client and broker roles.
- provider-independent users with Telegram identity authentication.
- a database-backed, provider-independent product catalog.

When `DATABASE_URL` is configured, intents, quotes, orders and manual tasks are
stored in the private PostgreSQL schema `market` and survive deploys and
process restarts. Development can still run without PostgreSQL using the
in-memory adapters.

## User identities

`market.users` owns the stable internal UUID, role and account status.
`market.user_identities` links that user to external authentication providers.
Transactions and other domain records should reference the internal user UUID,
never a Telegram ID.

The client bot authenticates a Telegram user through the protected public API:

```sh
curl -sS http://localhost:9292/v1/auth/telegram \
  -H 'authorization: Bearer client-secret' \
  -H 'content-type: application/json' \
  -d '{
    "telegram_user_id": "123456789",
    "chat_id": "123456789",
    "username": "example",
    "first_name": "Sasha",
    "language_code": "uk"
  }'
```

The first request creates a `client` user and Telegram identity and returns
`201`. Later requests return `200`, preserve the same internal user UUID and
refresh provider profile data. The model can add Apple, email or other
identities without changing the user record.

An authenticated service can list active users without exposing Telegram
profile data:

```sh
curl -sS 'http://localhost:9292/v1/users?status=active' \
  -H 'authorization: Bearer client-secret'
```

Each item contains only the internal UUID, Telegram user ID, role and account
status. `/health` also returns the current UTC server time.

The initial administrator is bootstrapped with `ADMIN_TELEGRAM_IDS`, a
comma-separated list of numeric Telegram IDs. An authenticated admin can then
promote another registered Telegram user by ID or current username:

```sh
curl -sS http://localhost:9292/v1/admin/users/set-admin \
  -H 'authorization: Bearer client-secret' \
  -H 'content-type: application/json' \
  -d '{"actor_telegram_user_id":"77","target":"@example"}'
```

The target must have authenticated through `/start`. Role assignment is
transactional and idempotent; the endpoint returns `403` unless the actor has
the persisted `admin` role.

## Product catalog

`market.products` stores the locale-neutral current state: stable SKU, short
name, ordering, status, opaque metadata, current USDT price snapshot, update
timestamps and the internal UUID of the user who edited it. The lifecycle
kernel does not interpret product families, amounts, currencies or fulfillment
semantics.

User-facing names live in `market.product_localizations`, keyed by
`(product_sku, locale)`. Each row contains the full name and Telegram button
label. The default locale is `en_US`; `uk_UA` is seeded for the entire initial
catalog. Resolution follows `requested locale -> en_US -> products.short_name`,
so missing translations never remove a product from the catalog.

`market.product_prices` remains an append-only price history for audit and the
daily previous/current comparison. A database trigger updates the current
snapshot in `market.products` after each price insertion. Editors are stored as
provider-independent `market.users.id` values; legacy Telegram IDs remain only
on historical rows created before the UUID migration.

The initial test catalog contains nine active products:

- Telegram Premium 3, 6 and 12 months;
- Stars 500, 1000 and 3000;
- TON, BTC and ETH.

Both bot-facing APIs expose the same ordered catalog:

```sh
curl -sS 'http://localhost:9292/v1/products?locale=uk_UA' \
  -H 'authorization: Bearer client-secret'

curl -sS 'http://localhost:9292/operator/v1/products?locale=uk_UA' \
  -H 'authorization: Bearer operator-secret'
```

Only active products are returned. Omitting `locale` returns `en_US`.
Product-specific behavior remains in providers and consumers; adding a catalog
row never adds knowledge to the provider-agnostic kernel.

## Lifecycle

```text
intent -> quote -> accepted order -> processing -> succeeded
                                      |
                                      +-> pending -> processing -> succeeded
                                      |
                                      +-> failed (retryable or terminal)
                                      |
                                      +-> cancelled
```

Providers implement three methods:

```ruby
provider.key
provider.quote(intent:)
provider.execute(order:, idempotency_key:)
```

`execute` returns either a final `ExecutionResult` or a `PendingResult`. A
pending order can be executed again to poll or resume provider work. Polling a
pending execution does not increase the attempt counter.

## ManualProvider

`ManualProvider` turns execution into an operator task. This allows an iOS
app, CLI, WhatsApp bot or another operator-facing client to fulfill orders
without coupling that client to the core.

1. A consumer creates an intent with capability `manual.fulfillment`.
2. The consumer creates and accepts a quote.
3. Executing the order creates one idempotent manual task and returns `pending`.
4. An authenticated operator client claims, completes or rejects the task.
5. Executing the pending order again resolves it from the operator decision.

The provider delegates its task queue to a storage adapter. Production uses
PostgreSQL while the provider and the core remain database-agnostic.

## Run

Ruby `3.3.11` is required.

```sh
bundle install
PUBLIC_API_TOKEN=client-secret \
MANUAL_PROVIDER_TOKEN=operator-secret \
DATABASE_URL='postgresql://postgres:password@localhost:5432/0xda_market' \
bundle exec rackup
```

Without `MANUAL_PROVIDER_TOKEN`, the application starts in health-only mode
with no registered capability. `PUBLIC_API_TOKEN` protects every public route
except `/health`. With the API tokens set, the application exposes:

- public API: `http://localhost:9292/v1/...`
- operator API: `http://localhost:9292/operator/v1/...`
- health check: `http://localhost:9292/health`

Production boot requires the two API tokens and `DATABASE_URL`. Telegram bot
tokens are optional and belong in dedicated bot services. Do not reuse the same
value for consumer and operator access.

## Versioning and releases

Stable releases use Semantic Versioning tags such as `v0.1.0`. Notable changes
are curated in [CHANGELOG.md](CHANGELOG.md); the promotion, tag, draft-release
and rollback procedure is documented in [RELEASING.md](RELEASING.md).

## Telegram demo bots

The public product name shown in both bots is `zeroxda-market`:

- `zeroxda_market_client_bot` accepts a free-form request, waits for a broker,
  performs a mock payment and reports fulfillment;
- `zeroxda_market_broker_bot` becomes `ready` on `/start`, receives every open
  request, atomically accepts one and marks it complete after mock payment.

The demo lifecycle is:

```text
client request -> broadcast to ready brokers -> one broker accepts
               -> mock payment -> broker completes -> client receives result
```

The legacy in-process Telegram demo transport is optional. Dedicated bot
services should call the public API and keep their bot tokens outside this core
service. To run the legacy transport locally, configure all three values:

```sh
TELEGRAM_CLIENT_BOT_TOKEN='BotFather client token' \
TELEGRAM_BROKER_BOT_TOKEN='BotFather broker token' \
TELEGRAM_WEBHOOK_BASE_URL='https://zeroxda-market.onrender.com' \
bundle exec ruby bin/configure_telegram_webhooks
```

The command derives separate webhook secrets from the bot tokens and registers
these HTTPS endpoints:

- `/telegram/client`
- `/telegram/broker`

The Docker startup command applies migrations and registers both webhooks
before Puma starts. Broker presence, task assignment, mock-payment state and
Telegram update deduplication are persisted in PostgreSQL.

Apply migrations before starting a non-containerized production process:

```sh
DATABASE_URL='postgresql://...' bundle exec ruby bin/migrate
```

The Docker image performs this migration step automatically before Puma
starts. `/health` returns `503` if PostgreSQL is unavailable.

## Public API example

Create an intent:

```sh
curl -sS http://localhost:9292/v1/intents \
  -H 'authorization: Bearer client-secret' \
  -H 'content-type: application/json' \
  -d '{
    "capability": "manual.fulfillment",
    "payload": {"action": "deliver", "item": "example"},
    "context": {"customer_id": "customer-1"}
  }'
```

Continue the lifecycle using the returned identifiers:

```sh
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

The first execution returns an order with status `pending` and a manual task
identifier in `data.attributes.progress.reference`.

## Operator API example

```sh
curl -sS http://localhost:9292/operator/v1/tasks?status=pending \
  -H 'authorization: Bearer operator-secret'

curl -sS -X POST \
  http://localhost:9292/operator/v1/tasks/TASK_ID/claim \
  -H 'authorization: Bearer operator-secret' \
  -H 'content-type: application/json' \
  -d '{"assignee":"operator-1"}'

curl -sS -X POST \
  http://localhost:9292/operator/v1/tasks/TASK_ID/complete \
  -H 'authorization: Bearer operator-secret' \
  -H 'content-type: application/json' \
  -d '{
    "reference": "external-result-1",
    "data": {"delivered": true}
  }'
```

An operator can reject a task instead:

```sh
curl -sS -X POST \
  http://localhost:9292/operator/v1/tasks/TASK_ID/reject \
  -H 'authorization: Bearer operator-secret' \
  -H 'content-type: application/json' \
  -d '{
    "message": "cannot fulfill",
    "code": "out_of_scope",
    "details": {"category": "unsupported"}
  }'
```

The dedicated broker service authenticates Telegram identities through the
operator API. The operator token selects the trusted `broker` role; callers
cannot choose or escalate the role in the request body:

```sh
curl -sS -X POST \
  http://localhost:9292/operator/v1/auth/telegram \
  -H 'authorization: Bearer operator-secret' \
  -H 'content-type: application/json' \
  -d '{"telegram_user_id":"77","chat_id":"770","username":"example"}'
```

An existing client is promoted to `broker`; existing brokers and admins are
never downgraded by later authentication through the client bot.

## Test

```sh
bundle exec rake
```

The GitHub CI workflow runs the Ruby suite against PostgreSQL, verifies restart
persistence, and builds the production Docker image. The Docker build also runs
the database-independent suite before producing its runtime stage.

## Docker

```sh
docker build --tag 0xda-market .
docker run --rm -p 10000:10000 \
  -e PUBLIC_API_TOKEN=client-secret \
  -e MANUAL_PROVIDER_TOKEN=operator-secret \
  -e DATABASE_URL='postgresql://...' \
  0xda-market
```

The image runs as an unprivileged user, binds Puma to `0.0.0.0:$PORT`, and
includes a container health check. Migrations use a PostgreSQL advisory lock,
so concurrent deploy starts cannot apply the same migration twice.

## Render

`render.yaml` uses Render's project model for the two core web services:

| Render environment | service | branch | URL |
| --- | --- | --- | --- |
| `Test` | `0xda-market-test` | `master` | `https://zeroxda-market-test.onrender.com` |
| `Prod` | `0xda-market` | `release` | `https://zeroxda-market.onrender.com` |

Both services are built from the repository Dockerfile, use `/health` for
health checks and deploy only after GitHub CI checks pass. Runtime secrets stay
in Render and are marked with `sync: false` in the Blueprint:

- `PUBLIC_API_TOKEN`
- `MANUAL_PROVIDER_TOKEN`
- `DATABASE_URL`
- `ADMIN_TELEGRAM_IDS`

Use distinct token and database values for production and test. Enter Supabase
Session Pooler URIs as `DATABASE_URL` and append `?sslmode=require`.

Keep Telegram bot tokens and webhook secrets in the dedicated bot services, not
in the core Render services. The client bot services call the public API and
select their database indirectly through `MARKET_API_URL`:

- production bot -> `https://zeroxda-market.onrender.com`
- test bot -> `https://zeroxda-market-test.onrender.com`

The optional `Provision Render test service` GitHub workflow creates or updates
only the test core service and places it in the Render `Test` environment.
Bot service environment variables are managed separately in Render or by the
client bot repository Blueprint.

The `market` schema is private to the backend connection; no domain tables are
created in Supabase's API-exposed `public` schema.

## Architecture

```text
Consumer clients                 Operator clients
iOS / CLI / Telegram / HTTP      iOS / CLI / Telegram / WhatsApp
        |                                  |
        v                                  v
Public JSON API                     Manual operator API
        |                                  |
        v                                  v
Provider-agnostic core  <----->       ManualProvider
        |
        v
Store adapter
```

Provider-specific behavior lives under `lib/zero_x_da/market/providers`.
The core never imports a provider implementation.

## Next boundaries

- operator lease expiry and task reassignment;
- consumer identities and per-resource ownership;
- capability-specific quote policies;
- durable observability and audit events;
- external providers added independently of the core.

## License

MIT
