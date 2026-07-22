# Spaceship VPS deployment

This directory runs the provider-agnostic API on an Ubuntu-based Spaceship
Starlight VM using Docker Compose and Caddy.

The application remains unchanged. The deployment layer provides:

- an internal-only Puma container on port `10000`;
- Caddy as the only public entry point on ports `80` and `443`;
- automatic HTTPS after DNS points to the VM;
- health-gated deployments;
- automatic deployment only after green `CI` on the `release` branch;
- three retained source releases for manual rollback.

Render should remain active until the VPS has passed the public health checks.

## Preparation status

Current state of the VPS migration:

- [x] deployment files and rollback procedure are merged into `master`;
- [x] repository references use `0xda-market/0xda-market`;
- [x] the SSH deployment port is fixed at `22022` in documentation and CI;
- [ ] bootstrap the VPS and verify Docker, Compose, SSH, Fail2ban, UFW and swap;
- [ ] create `/opt/0xda-market/shared/.env` with production values;
- [ ] configure the GitHub `production` environment secrets;
- [ ] run the first health-gated deployment from `release`;
- [ ] switch DNS only after the API container is healthy;
- [ ] verify public HTTPS and client bot traffic before retiring Render.

No production deployment or DNS cutover has been performed.

## 1. VM baseline

Use Ubuntu 24.04 LTS. A Spaceship Standard 1 VM is enough for the API and
Caddy while PostgreSQL remains external in Supabase. The bootstrap adds 2 GiB
of swap so Docker builds do not depend entirely on the VM's RAM.

Open the Spaceship Starlight Manager command line as `root`, then run the
bootstrap after this change is merged:

```sh
curl -fsSL \
  https://raw.githubusercontent.com/0xda-market/0xda-market/master/deploy/vps/bootstrap-ubuntu.sh \
  | bash
```

The script installs Docker Engine and Compose from Docker's official Ubuntu
repository, enables SSH, Fail2ban and UFW, creates the `deploy` user and a
dedicated GitHub Actions SSH key, and creates `/opt/0xda-market`.

Do not disable root password access until a separate personal SSH key has been
tested successfully.

## 2. Runtime secrets

Create the production environment file on the VM:

```sh
cp /opt/0xda-market/current/deploy/vps/.env.example \
  /opt/0xda-market/shared/.env
nano /opt/0xda-market/shared/.env
chown deploy:deploy /opt/0xda-market/shared/.env
chmod 0600 /opt/0xda-market/shared/.env
```

For the first deployment, `current` does not exist yet. Copy the contents of
`deploy/vps/.env.example` manually into `/opt/0xda-market/shared/.env` instead.

Required values:

- `DOMAIN=nilx.one`;
- `DATABASE_URL` for the production Supabase database;
- distinct `PUBLIC_API_TOKEN` and `MANUAL_PROVIDER_TOKEN` values;
- `ADMIN_TELEGRAM_IDS` when administrator bootstrap is needed;
- `VERIFY_PUBLIC_HTTPS=0` before DNS cutover.

Dedicated bot tokens do not belong in this core service. The legacy Telegram
variables should remain empty unless the in-process demo transport is
explicitly used.

## 3. GitHub production environment

Create or update the `production` environment in `0xda-market/0xda-market`.

Environment secrets:

- `VPS_HOST`: public IPv4 address of the VM;
- `VPS_USER`: `deploy`;
- `VPS_SSH_PRIVATE_KEY`: complete contents of
  `/root/0xda-market-github-actions` from the VM.

Environment variables:

- `VPS_DEPLOY_PATH`: `/opt/0xda-market`.

The workflow uses SSH port `22022` directly; no `VPS_PORT` repository or
environment variable is consumed.

A push to `release` first runs the normal CI suite and Docker build. Only a
successful CI workflow starts `Deploy API to VPS`. The VPS deployment builds
the same Dockerfile again, applies migrations during container startup and
waits for the Docker health check before marking the release active.

## 4. First deployment before DNS cutover

Promote the intended commit to `release`. After both workflows are green,
inspect the VM:

```sh
cd /opt/0xda-market/current/deploy/vps
docker compose ps
docker compose logs --tail 200 api
docker compose logs --tail 200 caddy
```

The API container must be `healthy`. Caddy may not have a public certificate
yet because `nilx.one` still points elsewhere. That is expected while
`VERIFY_PUBLIC_HTTPS=0`.

## 5. DNS cutover

In Spaceship Advanced DNS:

1. Lower the existing root record TTL to `300` before the cutover when
   possible.
2. Change only the root `A` record (`@`) to the VM's public IPv4 address.
3. Remove a stale root `AAAA` record unless the VM has configured public IPv6.
4. Keep all iCloud Mail `MX`, SPF, DKIM and verification `TXT` records intact.
5. Keep or add `www CNAME nilx.one` only when `www` should reach the API too.

Caddy obtains and renews the HTTPS certificate automatically after the domain
resolves to the VM and ports `80` and `443` are reachable.

Verify externally:

```sh
curl -i https://nilx.one/health
```

Then set this on the VM:

```sh
sed -i 's/^VERIFY_PUBLIC_HTTPS=.*/VERIFY_PUBLIC_HTTPS=1/' \
  /opt/0xda-market/shared/.env
```

Run the current deploy script once so the public HTTPS verification is also
checked:

```sh
bash /opt/0xda-market/current/deploy/vps/deploy.sh
```

## 6. Client bot cutover

The production client bot currently uses `MARKET_API_URL`. After the VPS health
check is green, change its production value from the Render API URL to:

```text
https://nilx.one
```

The test bot can continue using the Render test API until a separate test VPS
or test hostname is introduced.

## 7. Rollback

Keep Render running during the migration window. The fastest infrastructure
rollback is to restore the old root `A` record or the previous Render DNS
target.

For an application rollback on the VPS, list retained releases and redeploy a
previous source tree:

```sh
ls -1dt /opt/0xda-market/releases/*
bash /opt/0xda-market/releases/PREVIOUS_SHA/deploy/vps/deploy.sh
ln -sfn /opt/0xda-market/releases/PREVIOUS_SHA /opt/0xda-market/current
```

Do not delete the Render service until DNS, HTTPS, API health, bot requests and
at least one subsequent release deployment have all succeeded.

## 8. Later move to `api.nilx.one`

The deployment is not coupled to the temporary root hostname. To move later:

1. add `api A <VPS_IP>` in Spaceship DNS;
2. change `DOMAIN=api.nilx.one` and `TELEGRAM_WEBHOOK_BASE_URL` when applicable;
3. redeploy;
4. update the bot's `MARKET_API_URL` to `https://api.nilx.one`.
