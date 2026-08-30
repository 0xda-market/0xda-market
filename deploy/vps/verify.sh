#!/usr/bin/env bash
set -Eeuo pipefail

core_root="${CORE_DEPLOY_PATH:-/opt/0xda-market}"
bot_root="${BOT_DEPLOY_PATH:-/opt/0xda-market-bot}"
verify_environment="${DEPLOY_ENV:-production}"
verify_systemd="${VERIFY_SYSTEMD:-1}"
verify_public_https="${VERIFY_PUBLIC_HTTPS:-1}"
expected_edge_network="nilx-edge"

fail() {
  echo "verification failed: $*" >&2
  exit 1
}

read_env_value() {
  local file="$1"
  local key="$2"
  sed -n "s/^${key}=//p" "$file" | tail -n 1
}

current_release() {
  local root="$1"
  local environment="$2"
  readlink -f "$root/environments/$environment/current" 2>/dev/null || true
}

compose() {
  local release="$1"
  local env_file="$2"
  shift 2
  docker compose \
    --file "$release/deploy/vps/compose.yaml" \
    --env-file "$env_file" \
    --project-directory "$release/deploy/vps" \
    "$@"
}

container_for() {
  local release="$1"
  local env_file="$2"
  local service="$3"
  compose "$release" "$env_file" ps --quiet "$service"
}

check_container() {
  local label="$1"
  local container_id="$2"
  local require_health="$3"
  local running restart_policy log_driver max_size max_file health

  [[ -n "$container_id" ]] || fail "$label container is missing"

  running="$(docker inspect --format '{{.State.Running}}' "$container_id")"
  [[ "$running" == "true" ]] || fail "$label container is not running"

  restart_policy="$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$container_id")"
  [[ "$restart_policy" == "unless-stopped" ]] || fail "$label restart policy is $restart_policy"

  log_driver="$(docker inspect --format '{{.HostConfig.LogConfig.Type}}' "$container_id")"
  [[ "$log_driver" == "json-file" ]] || fail "$label log driver is $log_driver"

  max_size="$(docker inspect --format '{{index .HostConfig.LogConfig.Config "max-size"}}' "$container_id")"
  max_file="$(docker inspect --format '{{index .HostConfig.LogConfig.Config "max-file"}}' "$container_id")"
  [[ "$max_size" == "10m" && "$max_file" == "3" ]] || \
    fail "$label log rotation is max-size=$max_size max-file=$max_file"

  if [[ "$require_health" == "1" ]]; then
    health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id")"
    [[ "$health" == "healthy" ]] || fail "$label health is $health"
  fi

  echo "ok: $label"
}

check_network_contract() {
  local label="$1"
  local container_id="$2"
  local expected_alias="$3"
  local networks aliases

  networks="$(docker inspect --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' "$container_id")"
  grep -qx "$expected_edge_network" <<<"$networks" || \
    fail "$label is not attached to $expected_edge_network"

  aliases="$(docker inspect --format '{{range $network, $config := .NetworkSettings.Networks}}{{range $config.Aliases}}{{println .}}{{end}}{{end}}' "$container_id")"
  grep -qx "$expected_alias" <<<"$aliases" || fail "$label is missing edge alias $expected_alias"

  echo "ok: $label network=$expected_edge_network alias=$expected_alias"
}

case "$verify_environment" in
  development|production) ;;
  *) fail "unsupported DEPLOY_ENV: $verify_environment" ;;
esac

core_release="$(current_release "$core_root" "$verify_environment")"
bot_release="$(current_release "$bot_root" "$verify_environment")"
[[ -n "$core_release" && -d "$core_release/deploy/vps" ]] || fail "core release is not deployed"
[[ -n "$bot_release" && -d "$bot_release/deploy/vps" ]] || fail "bot release is not deployed"

core_env="$core_root/environments/$verify_environment/shared/.env"
bot_env="$bot_root/environments/$verify_environment/shared/.env"
[[ -f "$core_env" ]] || fail "core runtime file is missing: $core_env"
[[ -f "$bot_env" ]] || fail "bot runtime file is missing: $bot_env"
[[ "$(read_env_value "$core_env" DEPLOY_ENV)" == "$verify_environment" ]] || fail "core DEPLOY_ENV mismatch"
[[ "$(read_env_value "$bot_env" DEPLOY_ENV)" == "$verify_environment" ]] || fail "bot DEPLOY_ENV mismatch"
[[ "$(read_env_value "$core_env" EDGE_OWNER)" == "infra" ]] || fail "core EDGE_OWNER must be infra"

if [[ "$verify_systemd" == "1" ]]; then
  systemctl is-enabled --quiet docker || fail "Docker is not enabled at boot"
  systemctl is-active --quiet docker || fail "Docker is not active"
  echo "ok: Docker boot service"
fi

docker network inspect "$expected_edge_network" >/dev/null 2>&1 || \
  fail "Docker network is missing: $expected_edge_network"

compose "$core_release" "$core_env" config --quiet
compose "$bot_release" "$bot_env" config --quiet

api_container="$(container_for "$core_release" "$core_env" api)"
bot_container="$(container_for "$bot_release" "$bot_env" bot)"

check_container "core API" "$api_container" 1
check_container "client bot" "$bot_container" 1
check_network_contract "core API" "$api_container" "market-api-$verify_environment"
check_network_contract "client bot" "$bot_container" "market-bot-$verify_environment"

compose "$bot_release" "$bot_env" exec -T bot ruby -rnet/http -e \
  "uri = URI('http://127.0.0.1:10000/health'); exit(Net::HTTP.get_response(uri).is_a?(Net::HTTPSuccess) ? 0 : 1)"
echo "ok: local bot health"

if [[ "$verify_public_https" == "1" ]]; then
  domain="$(read_env_value "$core_env" DOMAIN)"
  [[ -n "$domain" ]] || fail "DOMAIN is missing from the core runtime file"

  if [[ "$verify_environment" == production ]]; then
    curl --fail --silent --show-error --retry 3 --retry-all-errors \
      "https://${domain}/health" >/dev/null
    curl --fail --silent --show-error --retry 3 --retry-all-errors \
      "https://${domain}/bot/health" >/dev/null
  else
    curl --fail --silent --show-error --retry 3 --retry-all-errors \
      "https://${domain}/bot-test/health" >/dev/null
  fi
  echo "ok: public HTTPS health through 0x0sky/infra edge"
fi

printf 'VPS verification passed: environment=%s core=%s bot=%s network=%s edge-owner=infra\n' \
  "$verify_environment" "$(basename "$core_release")" "$(basename "$bot_release")" "$expected_edge_network"
