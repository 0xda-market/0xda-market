# VPS deployment

This directory runs the provider-agnostic `0xda-market` API on one Ubuntu VPS
with Docker Compose and Caddy.

The VPS is intentionally **active/passive**: both environments can be staged,
but only one complete core + bot stack may be running at a time.

## Environment contract

| GitHub environment | Source branch | Telegram bot | Supabase database |
| --- | --- | --- | --- |
| `development` | `master` | `@zeroxda_market_test_bot` | test |
| `production` | `release*` | `@zeroxda_market_bot` | production |

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

The state file contains either `development` or `production`. It is written only
after both the core and bot health checks pass.

## Bootstrap

Run as `root` on Ubuntu 24.04 LTS:

```sh
curl -fsSL \
  https://raw.githubusercontent.com/0xda-market/0xda-market/master/deploy/vps/bootstrap-ubuntu.sh \
  | bash
```

The script installs Docker Engine and Compose, enables SSH, Fail2ban and UFW,
creates the `deploy` user, keeps SSH port `22022` open, and prepares both
repositories for both environments.

## GitHub environments

Create `development` and `production` in both repositories.

`0xda-market/0xda-market` secrets:

- `VPS_HOST`
- `VPS_USER=deploy`
- `VPS_SSH_PRIVATE_KEY`

Core variable:

- `VPS_DEPLOY_PATH=/opt/0xda-market`

`0xda-market/0xda-market-bot` uses the same three secrets and:

- `VPS_BOT_DEPLOY_PATH=/opt/0xda-market-bot`

The SSH port is fixed to `22022` in the workflows. Do not create `VPS_PORT`.
Use required reviewers on the GitHub `production` environment before enabling a
production cutover.

## Runtime files

Create one core runtime file per environment:

```text
/opt/0xda-market/environments/development/shared/.env
/opt/0xda-market/environments/production/shared/.env
```

Start from `deploy/vps/.env.example`. The values must be independent:

```env
DEPLOY_ENV=development
DOMAIN=0xda-market.nilx.one
DATABASE_URL=<development Supabase URL>
PUBLIC_API_TOKEN=<development token>
MANUAL_PROVIDER_TOKEN=<development token>
VERIFY_PUBLIC_HTTPS=0
```

The production file uses `DEPLOY_ENV=production`, the production Supabase URL,
and distinct API tokens. Dedicated Telegram bot tokens do not belong in the
core runtime file.

Protect all runtime files:

```sh
chown deploy:deploy /opt/0xda-market/environments/*/shared/.env
chmod 0600 /opt/0xda-market/environments/*/shared/.env
```

## Deployment behavior

After green `CI`:

- a push to `master` stages or refreshes `development`;
- a push to a `release*` branch stages or refreshes `production`;
- an inactive environment is built and its `current` symlink is updated, but it
  is not started;
- an already active environment is updated immediately and health-gated;
- a failed active refresh attempts to restart the previous release.

A successful deploy does **not** switch the active environment.

## Environment switch

Use the manual GitHub Actions workflow `Switch VPS Environment` from the core
repository. It is the only supported switch control.

The controller:

1. validates that both target releases and both target `.env` files exist;
2. stops the inactive core and bot stacks;
3. starts the target core and waits for health;
4. starts the target bot and waits for health;
5. writes `active-environment` atomically;
6. restarts the previous environment when the target fails.

Switching to production additionally requires the workflow confirmation checkbox
and `CONFIRM_PRODUCTION=1` inside the controller.

The same operation can be inspected manually on the VPS:

```sh
bash /opt/0xda-market/environments/development/current/deploy/vps/switch-environment.sh status
```

Manual development activation:

```sh
sudo -u deploy \
  bash /opt/0xda-market/environments/development/current/deploy/vps/switch-environment.sh \
  development
```

Manual production activation is intentionally explicit:

```sh
sudo -u deploy env CONFIRM_PRODUCTION=1 \
  bash /opt/0xda-market/environments/production/current/deploy/vps/switch-environment.sh \
  production
```

Prefer the reviewed GitHub workflow over manual activation.

## Smoke checks

For the active environment:

```sh
cat /opt/0xda-market-runtime/active-environment
curl -i https://0xda-market.nilx.one/health
```

Inspect the selected core stack:

```sh
cd /opt/0xda-market/environments/development/current/deploy/vps
docker compose ps
docker compose logs --tail 200 api
docker compose logs --tail 200 caddy
```

The bot remains a separate service and is verified from its repository layout.

## Safety gates

- Keep `REGISTER_TELEGRAM_WEBHOOK=0` in the bot environment until core and bot
  health checks are green.
- Do not activate production until the production Supabase URL, production bot
  token, webhook secret and API token pairing have been reviewed.
- Do not run both environments simultaneously; they intentionally share ports
  `80`, `443` and `127.0.0.1:10001`.
- Do not retire the previous hosting path until HTTPS, API traffic and bot
  traffic have passed a subsequent deployment.
