# VPS deployment

This directory deploys the provider-agnostic `0xda-market` application workloads to the shared Ubuntu VPS.

The public edge is not part of this product deployment. Caddy, TLS state, public ports `80/443`, host/path routing, and the external `nilx-edge` network contract are owned by [`0x0sky/infra`](https://github.com/0x0sky/infra).

## Runtime identities

Development and production are independent Compose projects and may stay online at the same time:

| Environment | API edge alias | Public API |
| --- | --- | --- |
| `production` | `market-api-production:10000` | `https://0xda-market.nilx.one/*` |
| `development` | `market-api-development:10000` | private to `nilx-edge` |

The matching Telegram runtimes are owned by `0xda-market/telegram-bot` and expose `market-bot-production:10000` and `market-bot-development:10000`.

`0x0sky/infra` maps `/bot/*` to production and `/bot-test/*` to development. The development API remains private; the test bot talks to it directly over `nilx-edge`.

## Ownership boundary

`0xda-market/core` owns:

- API, refresh workers and their release lifecycle;
- environment-specific database/secrets;
- `market-api-<environment>:10000` identities;
- core health and migrations;
- its own `mcp-control` observer.

It does not own:

- Caddy, TLS or public ports;
- Telegram bot runtime/health;
- shared-edge deployment;
- another environment's activation state.

A core deployment must never mutate Caddy or fail because the bot workload is unavailable.

## GitHub delivery

Deployment is manual-only through `.github/workflows/deploy-vps.yml`.

- `development` deploys the exact commit selected by GitHub's workflow ref selector.
- `production` must be dispatched from `master` and requires an explicit immutable Git tag.
- merge does not deploy either environment.
- production and development use independent concurrency groups, release directories and Compose projects.
- a failed activation attempts to restore only the previous release of the same environment.

Required GitHub Environment configuration for `development` and `production`:

- secret `SSH_HOST`;
- secret `SSH_USER`;
- secret `SSH_PRIVATE_KEY`;
- variable `SSH_DEPLOYMENT_PATH=/opt/0xda-market`;
- variable `SSH_PORT=22022`.

## VPS layout

```text
/opt/0xda-market/environments/
  development/
    current -> releases/<sha>
    releases/
    shared/.env
  production/
    current -> releases/<sha>
    releases/
    shared/.env
```

There is no global `active-environment` switch in the canonical deployment model.

## Runtime files

Start development from `.env.example`. Important infrastructure fields are:

```env
DEPLOY_ENV=development
DOMAIN=0xda-market.nilx.one
MARKET_EDGE_NETWORK=nilx-edge
EDGE_OWNER=infra
VERIFY_PUBLIC_HTTPS=0
```

Production uses:

```env
DEPLOY_ENV=production
DOMAIN=0xda-market.nilx.one
MARKET_EDGE_NETWORK=nilx-edge
EDGE_OWNER=infra
VERIFY_PUBLIC_HTTPS=1
```

Development core is intentionally not public. Its Telegram test client should use:

```text
http://market-api-development:10000
```

Production bot should use:

```text
http://market-api-production:10000
```

Protect runtime files with mode `0600`.

## Deployment behavior

`deploy.sh` validates the environment and edge ownership before activation, builds the API runtime, starts the environment-specific Compose project, waits for API and `mcp-control` health, verifies the expected `market-api-<environment>` alias, and validates only the core server through `mcp-control`.

The observer runs on `nilx-edge`; it no longer depends on host loopback ports. The core deployment deliberately does not inspect or gate on Telegram bot health.

Production can additionally verify its public `/health` and complete WebApp bootstrap through the independently deployed shared edge. Development health remains internal because the development API is not a public surface.

## Cross-environment verification

`verify.sh` verifies one environment per invocation:

```bash
DEPLOY_ENV=production bash deploy/vps/verify.sh
DEPLOY_ENV=development bash deploy/vps/verify.sh
```

It checks the matching core and Telegram containers, `nilx-edge` membership, environment-specific aliases, local bot health, and — when enabled — the public route owned by `0x0sky/infra`:

```text
production:  /health + /bot/health
development: /bot-test/health
```

## Rollout order

For the side-by-side migration:

1. merge the core and Telegram runtime identity changes with green CI;
2. deploy both core environments manually;
3. deploy both Telegram environments manually;
4. validate the `0x0sky/infra` edge candidate against live Caddy;
5. explicitly deploy the shared edge;
6. verify production API, production Telegram, and test Telegram independently.

Merging any repository is not a production deployment.
