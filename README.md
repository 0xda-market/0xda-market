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
- a durable manual fulfillment workflow.

When `DATABASE_URL` is configured, intents, quotes, orders and manual tasks are
stored in the private PostgreSQL schema `market` and survive deploys and
process restarts. Development can still run without PostgreSQL using the
in-memory adapters.

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
4. An authenticated operator client lists and completes or rejects the task.
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
except `/health`. With both tokens set, the application exposes:

- public API: `http://localhost:9292/v1/...`
- operator API: `http://localhost:9292/operator/v1/...`
- health check: `http://localhost:9292/health`

Production boot fails unless both tokens and `DATABASE_URL` are configured. Do
not reuse the same value for consumer and operator access.

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

`render.yaml` defines a free Frankfurt web service built from the repository's
Dockerfile. It configures `/health`, prompts for both API tokens and
`DATABASE_URL`, and deploys only after all GitHub CI checks pass.

1. Merge the deployment PR into `master`.
2. In Render, create a new Blueprint and select this repository.
3. Enter distinct values for `PUBLIC_API_TOKEN` and `MANUAL_PROVIDER_TOKEN`.
4. Enter the Supabase Session Pooler URI as `DATABASE_URL`, replacing
   `[YOUR-PASSWORD]` and appending `?sslmode=require`.
5. Apply the Blueprint and wait for the health check to pass.

Render rebuilds and deploys subsequent `master` commits after CI succeeds.
The `market` schema is private to the backend connection; no domain tables are
created in Supabase's API-exposed `public` schema.

## Architecture

```text
Consumer clients                 Operator clients
iOS / CLI / bot / HTTP           iOS / CLI / WhatsApp bot
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

- manual task claiming and operator leases;
- consumer identities and per-resource ownership;
- capability-specific quote policies;
- durable observability and audit events;
- external providers added independently of the core.

## License

MIT
