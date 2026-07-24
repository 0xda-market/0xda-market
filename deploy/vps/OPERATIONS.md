# VPS operations

This runbook is the operational baseline for the active `0xda-market` core and
client bot on `0xda-market.nilx.one`. It is intentionally read-only except where
a section explicitly describes deployment or rollback.

## Canonical runtime

The VPS is the canonical application runtime. Render configuration is not part of
the supported deployment path.

The current automated path is development-only:

- `master` deploys the core and bot into `development` after green CI;
- the active environment marker is `/opt/0xda-market-runtime/active-environment`;
- production directories remain reserved for a later reviewed release workflow;
- no deployment or environment switch may register a Telegram webhook implicitly.

## After every deployment

Run the verifier from the active core release:

```sh
sudo -u deploy \
  bash /opt/0xda-market/environments/development/current/deploy/vps/verify.sh
```

The verifier checks, without changing runtime state:

- Docker is enabled and active;
- the active-environment marker and both release symlinks are valid;
- core and bot runtime files match the active environment;
- Compose configuration renders for both repositories;
- the core API, Caddy and bot containers are running;
- API and bot container health is green;
- every container uses `restart: unless-stopped`;
- every container uses bounded `json-file` logs (`10m` × `3`);
- the active Caddy configuration validates;
- local bot health and public core/bot HTTPS health pass.

For an isolated check that intentionally skips host or public network checks:

```sh
VERIFY_SYSTEMD=0 VERIFY_PUBLIC_HTTPS=0 \
  bash deploy/vps/verify.sh
```

## Reboot verification

Docker is enabled during VPS bootstrap and every application container uses
`restart: unless-stopped`. After a host reboot, verify the host and the full
application boundary:

```sh
systemctl is-enabled docker
systemctl is-active docker
cat /opt/0xda-market-runtime/active-environment
sudo -u deploy \
  bash /opt/0xda-market/environments/development/current/deploy/vps/verify.sh
```

A reboot is not considered successful until both public checks return `200`:

```sh
curl -fsS https://0xda-market.nilx.one/health
curl -fsS https://0xda-market.nilx.one/bot/health
```

## HTTPS and domain

Caddy owns ports `80`, `443/tcp` and `443/udp`, certificate issuance and renewal.
The public contract is:

- `https://0xda-market.nilx.one/*` → core API;
- `https://0xda-market.nilx.one/bot/*` → client bot with `/bot` stripped;
- `https://0xda-market.nilx.one/webapp/*` → reserved WebApp boundary.

Validate the active Caddy file and inspect certificate-related logs:

```sh
cd /opt/0xda-market/environments/development/current/deploy/vps
docker compose exec -T caddy caddy validate --config /etc/caddy/Caddyfile
docker compose logs --tail 200 caddy
```

DNS or Caddy changes are separate reviewed production operations. Do not alter
DNS, webhook routing or public ports as part of an ordinary application deploy.

## Health and diagnostics

```sh
# Runtime overview
bash /opt/0xda-market/environments/development/current/deploy/vps/switch-environment.sh status

# Core stack
cd /opt/0xda-market/environments/development/current/deploy/vps
docker compose ps
docker compose logs --tail 200 api
docker compose logs --tail 200 caddy

# Bot stack
cd /opt/0xda-market-bot/environments/development/current/deploy/vps
docker compose ps
docker compose logs --tail 200 bot

# Bound host ports
ss -lntup | grep -E ':(80|443|10001)\b'
```

Do not print `.env` files or tokens into tickets, CI logs or chat.

## Log retention

All application containers use Docker's `json-file` driver with `max-size=10m`
and `max-file=3`. This bounds local logs per container while keeping recent
startup and request failures available through `docker compose logs`.

Check the effective policy:

```sh
container_id="$(docker compose ps --quiet api)"
docker inspect --format '{{json .HostConfig.LogConfig}}' "$container_id"
```

Long-term audit or analytics logs require a separate remote log sink. The VPS
must not accumulate unbounded application log files.

## Backups

### PostgreSQL / Supabase

The application database is external to the VPS. Container and release backups
do not protect database state.

Before a production schema change:

1. verify that the production PostgreSQL/Supabase backup policy is active;
2. record the latest successful backup or point-in-time recovery boundary;
3. keep the migration and the compatible application pair in Git;
4. perform destructive restore testing only in a non-production project;
5. do not assume an application rollback reverses a database migration.

### VPS runtime state

The only irreplaceable VPS files are the protected runtime `.env` files and the
active-environment marker. Release directories are rebuildable from Git commits,
and Caddy certificates can be reissued.

Back up runtime files only to encrypted, access-controlled, off-host storage.
Never create a long-lived plaintext archive containing tokens or database URLs.
A backup set should include:

```text
/opt/0xda-market/environments/*/shared/.env
/opt/0xda-market-bot/environments/*/shared/.env
/opt/0xda-market-runtime/active-environment
```

After restoring, enforce ownership and permissions before starting containers:

```sh
chown deploy:deploy /opt/0xda-market/environments/*/shared/.env
chown deploy:deploy /opt/0xda-market-bot/environments/*/shared/.env
chmod 0600 /opt/0xda-market/environments/*/shared/.env
chmod 0600 /opt/0xda-market-bot/environments/*/shared/.env
```

## Rollback

### Automatic rollback

An active deployment is health-gated. When activation of a new release fails,
the workflow attempts to restart the previous `current` release. Environment
switching also attempts to restore the previously active core + bot pair.

### Manual release rollback

Use a manual rollback only when the automatic path cannot recover. Keep core and
bot versions paired.

1. Record the current links and list retained releases:

   ```sh
   readlink -f /opt/0xda-market/environments/development/current
   readlink -f /opt/0xda-market-bot/environments/development/current
   find /opt/0xda-market/environments/development/releases -mindepth 1 -maxdepth 1 -type d
   find /opt/0xda-market-bot/environments/development/releases -mindepth 1 -maxdepth 1 -type d
   ```

2. Select a previously green, compatible core + bot pair.
3. Move both `current` symlinks to those retained release directories.
4. Refresh the active environment through the reviewed switch controller:

   ```sh
   sudo -u deploy \
     bash /opt/0xda-market/environments/development/current/deploy/vps/switch-environment.sh \
     development
   ```

5. Run `verify.sh` and confirm Telegram commands before considering recovery
   complete.

If a migration is not backward-compatible, stop and use the database recovery
plan. Do not improvise a production database downgrade.

## Retirement of the previous host

The old hosting path may be disabled only after all of the following remain green
through a subsequent deployment and a reboot check:

- public core health;
- public bot health;
- Telegram webhook delivery;
- authenticated catalog access;
- admin-only operations;
- the scheduled price digest, when production scheduling is enabled;
- verified database and runtime-secret recovery paths.

Disabling or deleting the previous host is a separate irreversible operation and
requires explicit owner approval.
