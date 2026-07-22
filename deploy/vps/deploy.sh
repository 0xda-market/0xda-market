#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if [[ ! -f .env ]]; then
  echo "deploy/vps/.env is missing" >&2
  exit 1
fi

deploy_mode="${DEPLOY_MODE:-activate}"
deploy_environment="$(sed -n 's/^DEPLOY_ENV=//p' .env | tail -n 1)"

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

docker compose config --quiet
docker compose build --pull api

if [[ "$deploy_mode" == "stage" ]]; then
  echo "0xda-market $deploy_environment release staged"
  exit 0
fi

docker compose up --detach --remove-orphans

api_container="$(docker compose ps --quiet api)"
if [[ -z "$api_container" ]]; then
  echo "API container was not created" >&2
  docker compose ps
  exit 1
fi

for _ in $(seq 1 36); do
  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$api_container" 2>/dev/null || true)"
  case "$health" in
    healthy)
      break
      ;;
    unhealthy)
      echo "API container became unhealthy" >&2
      docker compose logs --tail 200 api >&2
      exit 1
      ;;
  esac
  sleep 5
done

health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$api_container" 2>/dev/null || true)"
if [[ "$health" != "healthy" ]]; then
  echo "API container did not become healthy: $health" >&2
  docker compose logs --tail 200 api >&2
  exit 1
fi

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
fi

docker image prune --force --filter 'until=168h' >/dev/null

echo "0xda-market $deploy_environment VPS deployment is healthy"
