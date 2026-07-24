# VPS deployment

This directory runs the provider-agnostic `0xda-market` API and the public Caddy
edge on one Ubuntu VPS. The client bot is deployed from
`0xda-market/0xda-market-bot` on the same host and private Docker network.

The VPS is the canonical application runtime. Render configuration is no longer
part of the supported deployment path.

## Current deployment contract

Automated deployment is currently development-only:

| GitHub environment | Source branch | Runtime directory | Database |
| --- | --- | --- | --- |
| `development` | `master` | `environments/development` | test Supabase |

Production directories and the reviewed environment-switch controller remain in
place, but production is not staged automatically. Enabling production requires
a separate reviewed change to both core and bot deployment workflows.

`DEPLOY_ENV` is the only runtime environment marker. It must match the GitHub
Environment and the VPS directory containing the runtime file.

## VPS layout

```text
/opt/0xda-market/
  environments/
    development/
      current -> releases/<sha>
      releases/
      shared/.env
    production/
      current -> releases/<sha>
      releases/
      shared/.env

/opt/0xda-market-bot/
  environments/
    development/
      current -> releases/<sha>
      releases/
      shared/.env
    production/
      current -> releases/<sha>
      releases/
      shared/.env

/opt/0xda-market-runtime/
  active-environment
```

The state file is written only after the selected core and bot releases pass
health checks.

Core Caddy, the core API and the active bot share the private external Docker
network `zero-x-da-market-edge`. Both deploy scripts create it when missing. The
bot remains bound to `127.0.0.1:10001`; Caddy reaches it through the internal
alias `market-bot`.

## Bootstrap

Run as `root` on Ubuntu 24.04 LTS:

```sh
curl -fsSL \
  https://raw.githubusercontent.com/0xda-market/0xda-market/master/deploy/vps/bootstrap-ubuntu.sh \
  | bash
```

The script installs Docker Engine and Compose, enables Docker at boot, configures
SSH, Fail2ban and UFW, creates the `deploy` user, keeps SSH port `22022` open, and
prepares both repository layouts.

## GitHub development environment

Configure `development` in both repositories.

Required secrets:

- `VPS_HOST`
- `VPS_USER=deploy`
- `VPS_SSH_PRIVATE_KEY`

Repository variables:

- core: `VPS_DEPLOY_PATH=/opt/0xda-market`
- bot: `VPS_BOT_DEPLOY_PATH=/opt/0xda-market-bot`

The SSH port is fixed to `22022` in both workflows. Do not create `VPS_PORT`.

## Runtime files

Core development runtime:

```text
/opt/0xda-market/environments/development/shared/.env
```

Start from `deploy/vps/.env.example`:

```env
DEPLOY_ENV=development
DOMAIN=0xda-market.nilx.one
DATABASE_URL=<development Supabase URL>
PUBLIC_API_TOKEN=<development token>
MANUAL_PROVIDER_TOKEN=<development token>
VERIFY_PUBLIC_HTTPS=1
```

Bot development runtime:

```text
/opt/0xda-market-bot/environments/development/shared/.env
```

Use the matching core URL and token. Telegram tokens and webhook secrets belong
only in the bot runtime file.

Protect runtime files:

```sh
chown deploy:deploy /opt/0xda-market/environments/*/shared/.env
chown deploy:deploy /opt/0xda-market-bot/environments/*/shared/.env
chmod 0600 /opt/0xda-market/environments/*/shared/.env
chmod 0600 /opt/0xda-market-bot/environments/*/shared/.env
```

## Administrator bootstrap

Administrator roles are persisted in Supabase. There is no
`ADMIN_TELEGRAM_IDS` runtime variable and the bot is not a source of role data.

After a user authenticates and receives an internal `market.users.id`, promote
that existing user once:

```sh
cd /opt/0xda-market/environments/development/current/deploy/vps
docker compose exec -T api \
  bundle exec ruby bin/bootstrap_admin USER_ID
```

The command is idempotent and accepts only an existing internal user UUID.

## Deployment behavior

After green `CI`, a push to `master` stages or refreshes `development`.

- a missing or inactive environment is staged without changing the active marker;
- a manual workflow run from `master` may force development activation;
- an active environment is refreshed immediately and health-gated;
- a failed refresh attempts to restart the previous release;
- a successful deploy does not register a Telegram webhook.

Caddy owns public HTTPS. Requests under `/bot/*` are forwarded to
`market-bot:10000` with the `/bot` prefix stripped. Other requests go to the core
API at `api:10000`.

## Environment switch

Use `Switch VPS Environment` from the core repository. The controller validates
both release pairs, starts core before bot, updates the active marker atomically,
and attempts to restore the previous pair on failure.

Current status:

```sh
bash /opt/0xda-market/environments/development/current/deploy/vps/switch-environment.sh status
```

Refresh development manually:

```sh
sudo -u deploy \
  bash /opt/0xda-market/environments/development/current/deploy/vps/switch-environment.sh \
  development
```

Production activation remains guarded by `CONFIRM_PRODUCTION=1` and is unsupported
until compatible production releases have been staged through a reviewed release
workflow.

## Verification

Run the complete read-only verifier after deployment and after every VPS reboot:

```sh
sudo -u deploy \
  bash /opt/0xda-market/environments/development/current/deploy/vps/verify.sh
```

Basic public smoke checks:

```sh
curl -i https://0xda-market.nilx.one/health
curl -i https://0xda-market.nilx.one/bot/health
```

The public webhook path `/bot/telegram/webhook` maps to the bot route
`/telegram/webhook`.

## Operations

See [`OPERATIONS.md`](OPERATIONS.md) for:

- reboot and autostart verification;
- HTTPS and health diagnostics;
- bounded log retention;
- PostgreSQL/Supabase and runtime-secret backup responsibilities;
- automatic and manual rollback;
- the safety gate for retiring the previous host.

## Safety gates

- Keep `REGISTER_TELEGRAM_WEBHOOK=0` until local and public health checks pass.
- Keep the bot host port on `127.0.0.1`; public access must pass through Caddy.
- Do not run both environments simultaneously; they share ports `80`, `443` and
  `127.0.0.1:10001`.
- Do not activate production until the production database, tokens, bot pairing,
  CI and recovery plan have been reviewed.
- Do not disable or delete the previous host as part of an application deploy.
