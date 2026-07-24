#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if [[ ! -f .env ]]; then
  echo "deploy/vps/.env is missing" >&2
  exit 1
fi

deploy_mode="${DEPLOY_MODE:-activate}"
deploy_environment="$(sed -n 's/^DEPLOY_ENV=//p' .env | tail -n 1)"
edge_network="${MARKET_EDGE_NETWORK:-zero-x-da-market-edge}"

case "$deploy_mode" in
  stage|activate) ;;
  *)
    echo "Unsupported DEPLOY_MODE: $deploy_mode" >&2
    exit 1
    ;;
esac

case "$deploy_environment" in
  development|production) ;;
  *)
    echo "DEPLOY_ENV must be development or production" >&2
    exit 1
    ;;
esac

case "$(uname -m)" in
  x86_64|amd64)
    mcp_arch=amd64
    ;;
  aarch64|arm64)
    mcp_arch=arm64
    ;;
  *)
    echo "Unsupported mcp-control architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

mcp_binary="mcp-control/bin/mcp-control-${mcp_arch}"
if [[ ! -x "$mcp_binary" ]]; then
  echo "Pinned mcp-control binary is missing or not executable: $mcp_binary" >&2
  exit 1
fi
ln -sfn "mcp-control-${mcp_arch}" mcp-control/bin/mcp-control

if ! docker network inspect "$edge_network" >/dev/null 2>&1; then
  docker network create "$edge_network" >/dev/null
fi

docker compose config --quiet
docker compose pull mcp-control caddy
docker compose build --pull api

if [[ "$deploy_mode" == "stage" ]]; then
  echo "0xda-market $deploy_environment release staged"
  exit 0
fi

if ! docker compose up --detach --remove-orphans; then
  echo "Docker Compose failed while starting the VPS stack" >&2
  docker compose ps >&2 || true
  docker compose logs --tail 200 api mcp-control >&2 || true
  exit 1
fi

wait_for_healthy() {
  local service="$1"
  local container health

  container="$(docker compose ps --quiet "$service")"
  if [[ -z "$container" ]]; then
    echo "$service container was not created" >&2
    docker compose ps >&2
    return 1
  fi

  for _ in $(seq 1 36); do
    health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || true)"
    case "$health" in
      healthy)
        return 0
        ;;
      unhealthy)
        echo "$service container became unhealthy" >&2
        docker compose logs --tail 200 "$service" >&2
        return 1
        ;;
    esac
    sleep 5
  done

  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || true)"
  echo "$service container did not become healthy: $health" >&2
  docker compose logs --tail 200 "$service" >&2
  return 1
}

wait_for_healthy api
wait_for_healthy mcp-control

docker compose exec -T mcp-control \
  /opt/mcp-control/mcp-control servers validate \
  --config /etc/mcp-control/agent.json

for server_id in 0xda-market 0xda-market-bot; do
  snapshot="$(
    docker compose exec -T mcp-control \
      /opt/mcp-control/mcp-control servers inspect "$server_id" \
      --config /etc/mcp-control/agent.json
  )"
  printf '%s\n' "$snapshot"

  if ! grep -q '"state": "healthy"' <<<"$snapshot"; then
    echo "mcp-control did not observe $server_id as healthy" >&2
    docker compose logs --tail 200 mcp-control >&2 || true
    exit 1
  fi
done

verify_public_https="$(sed -n 's/^VERIFY_PUBLIC_HTTPS=//p' .env | tail -n 1)"
if [[ "$verify_public_https" == "1" ]]; then
  domain="$(sed -n 's/^DOMAIN=//p' .env | tail -n 1)"
  if [[ -z "$domain" ]]; then
    echo "DOMAIN is required when VERIFY_PUBLIC_HTTPS=1" >&2
    exit 1
  fi

  curl \
    --fail \
    --silent \
    --show-error \
    --retry 12 \
    --retry-all-errors \
    --retry-delay 5 \
    "https://${domain}/health" >/dev/null

  curl \
    --fail \
    --silent \
    --show-error \
    --retry 12 \
    --retry-all-errors \
    --retry-delay 5 \
    "https://${domain}/bot/health" >/dev/null
fi

docker image prune --force --filter 'until=168h' >/dev/null

echo "0xda-market, 0xda-market-bot, and mcp-control are healthy on $deploy_environment"
