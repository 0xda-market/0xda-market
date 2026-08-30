#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if [[ ! -f .env ]]; then
  echo "deploy/vps/.env is missing" >&2
  exit 1
fi

deploy_environment="$(sed -n 's/^DEPLOY_ENV=//p' .env | tail -n 1)"
edge_network="${MARKET_EDGE_NETWORK:-nilx-edge}"
edge_owner="$(sed -n 's/^EDGE_OWNER=//p' .env | tail -n 1)"
api_alias="market-api-${deploy_environment}"

if [[ "$edge_network" != "nilx-edge" ]]; then
  echo "MARKET_EDGE_NETWORK must be nilx-edge" >&2
  exit 1
fi

case "$deploy_environment" in
  development|production) ;;
  *)
    echo "DEPLOY_ENV must be development or production" >&2
    exit 1
    ;;
esac

if [[ "$edge_owner" != "infra" ]]; then
  echo "EDGE_OWNER must be infra before activating the edge-decoupled product stack" >&2
  exit 1
fi

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

core_server_config="mcp-control/config/servers.d/0xda-market.json"
if grep -q '__MARKET_API_ALIAS__' "$core_server_config"; then
  sed -i "s/__MARKET_API_ALIAS__/${api_alias}/g" "$core_server_config"
fi
if ! grep -q "http://${api_alias}:10000/health" "$core_server_config"; then
  echo "mcp-control core health endpoint does not match $api_alias" >&2
  exit 1
fi

if ! docker network inspect "$edge_network" >/dev/null 2>&1; then
  docker network create "$edge_network" >/dev/null
fi

docker compose config --quiet
docker compose pull mcp-control
docker compose build --pull api fx-refresh

if ! docker compose up --detach --remove-orphans; then
  echo "Docker Compose failed while starting the VPS stack" >&2
  docker compose ps >&2 || true
  docker compose logs --tail 200 api fx-refresh price-refresh mcp-control >&2 || true
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

api_container="$(docker compose ps -q api)"
if ! docker inspect "$api_container" \
  --format '{{range $network, $config := .NetworkSettings.Networks}}{{range $config.Aliases}}{{println .}}{{end}}{{end}}' \
  | grep -qx "$api_alias"; then
  echo "Expected edge alias is missing: $api_alias" >&2
  exit 1
fi

docker compose exec -T mcp-control \
  /opt/mcp-control/mcp-control servers validate \
  --config /etc/mcp-control/agent.json

snapshot="$(
  docker compose exec -T mcp-control \
    /opt/mcp-control/mcp-control servers inspect 0xda-market \
    --config /etc/mcp-control/agent.json
)"
printf '%s\n' "$snapshot"

if ! grep -q '"state": "healthy"' <<<"$snapshot"; then
  echo "mcp-control did not observe 0xda-market as healthy" >&2
  docker compose logs --tail 200 mcp-control >&2 || true
  exit 1
fi

verify_public_https="$(sed -n 's/^VERIFY_PUBLIC_HTTPS=//p' .env | tail -n 1)"
if [[ "$verify_public_https" == "1" && "$deploy_environment" == "production" ]]; then
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

  bootstrap_file="$(mktemp)"
  if ! curl \
    --fail \
    --silent \
    --show-error \
    --max-time 15 \
    --retry 2 \
    --retry-all-errors \
    --retry-delay 2 \
    "https://${domain}/v1/webapp/bootstrap?locale=en_US&currency=USDT" \
    --output "$bootstrap_file"; then
    echo "WebApp bootstrap did not complete within the deployment gate" >&2
    docker compose logs --tail 200 api >&2 || true
    rm -f "$bootstrap_file"
    exit 1
  fi

  if ! jq -e '
    .meta.complete == true and
    .meta.pagination == "client" and
    (.meta.count | type == "number") and
    .meta.count == (.data | length)
  ' "$bootstrap_file" >/dev/null; then
    echo "WebApp bootstrap returned an invalid complete-snapshot contract" >&2
    cat "$bootstrap_file" >&2
    docker compose logs --tail 200 api >&2 || true
    rm -f "$bootstrap_file"
    exit 1
  fi
  rm -f "$bootstrap_file"
elif [[ "$verify_public_https" == "1" ]]; then
  echo "development core is intentionally private to nilx-edge; skipping public API verification"
fi

docker image prune --force --filter 'until=168h' >/dev/null

echo "0xda-market core $deploy_environment is healthy"
echo "Edge alias verified: $api_alias"
